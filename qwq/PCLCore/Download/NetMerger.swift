//
//  NetMerger.swift
//  PCL.Mac
//
//  NetManager 的分片合并与下载后校验（对标 PCL2 Merge）：
//  - tryMergeIfPossible：记录已判定失败时不再合并；无活动分片且不存在待续传分片时触发合并，
//    成功置 done 并回调完成，失败置 failed 并清理临时分片；
//  - merge：覆盖策略处理（.replace/.skip 覆盖、.throw 抛错）、单分片直接移动、
//    多分片按 start 升序流式拼接、拼接后清理临时文件、下载后四合一校验，
//    校验失败先删除目标文件再抛错（避免坏文件被后续 .skip 预检永久固化）。
//  自 NetDownloader.swift 按职责物理拆出，原第 739-799 行，判定顺序与拼接顺序未改动。
//
//  本次修复（残缺文件被标记成功的缺陷）——三处改动，均为「静默成功 → 显式失败」：
//  1. tryMergeIfPossible 增加 record.state != .failed 前置校验。此前源耗尽（pickSource / sliceFailed
//     已置 failed 并清理临时分片）后仍在途的分片回调会再次进入合并，把已被清理、读不到的分片
//     静默跳过，产出残缺文件并覆盖为 done；
//  2. merge 的分片临时文件打开/读取失败由 `try?` + `continue` 改为抛出 mergeFailed。
//     读取失败不再被折叠为「该分片没有数据」；
//  3. merge 在多分片拼接分支捕获异常，先删除截断的目标文件再抛出（与校验失败路径同一处理），
//     并在合并完成后按 record.fileSize 校验落地文件大小。
//  影响：过去「无 checker 的调用方拿到残缺/空文件且进度上报 1.0」的场景，现在统一以失败结束。
//

import Foundation

extension NetManager {
    // MARK: - 合并（PCL2 Merge，1295-1335 行）

    func tryMergeIfPossible(_ record: FileRecord) {
        guard record.activeSliceCount == 0 else { return }
        // 已判定失败的文件不得再合并：此时记录的分片临时文件可能已被 cleanupTemps 清理，
        // 继续合并会把读不到的分片当作「无数据」跳过，产出残缺或空的落地文件并覆盖为 done，
        // 掩盖真实失败原因（修复：失败必须保持失败）。
        guard record.state != .failed else { return }
        let needsResume = record.slices.contains { $0.state == .failed && $0.undone(of: record) > 0 }
        guard !needsResume else { return }
        do {
            try merge(record)
            record.state = .done
            record.completion?()
        } catch {
            record.state = .failed
            record.failReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            cleanupTemps(record)
        }
    }

    func merge(_ record: FileRecord) throws {
        let sorted = record.slices.sorted { $0.start < $1.start }
        let destination = record.file.destination
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            switch record.file.replaceMethod {
            case .replace, .skip:
                // 走到 merge 的 .skip 均为「需要重下」（哈希不匹配已删 / 禁用已有文件复用）→ 覆盖
                try FileManager.default.removeItem(at: destination)
            case .throw:
                throw NetDownloadError.fileExists(destination.lastPathComponent)
            }
        }

        let withData = sorted.filter { $0.tempURL != nil && $0.done > 0 }
        if withData.count == 1, let temp = withData[0].tempURL {
            // 单线程：直接移动
            try FileManager.default.moveItem(at: temp, to: destination)
        } else {
            // 多分片：按 start 顺序流式拼接
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw NetDownloadError.mergeFailed("无法创建目标文件")
            }
            do {
                let out = try FileHandle(forWritingTo: destination)
                defer { try? out.close() }
                for slice in withData {
                    // 分片临时文件读取失败必须显式失败：原实现用 try? + continue 吞掉打开失败、
                    // 用 `while let ... = try? read` 吞掉读取失败，两者都会把该分片当作「无数据」跳过，
                    // 最终落地一个偏短的成品文件（无 checker 时无从发现），并上报 100% 完成。
                    guard let temp = slice.tempURL else {
                        throw NetDownloadError.mergeFailed("分片临时文件缺失")
                    }
                    let input: FileHandle
                    do {
                        input = try FileHandle(forReadingFrom: temp)
                    } catch {
                        throw NetDownloadError.mergeFailed("分片临时文件无法读取：\(temp.lastPathComponent)（\(error.localizedDescription)）")
                    }
                    defer { try? input.close() }
                    while true {
                        let chunk: Data?
                        do {
                            chunk = try input.read(upToCount: 1 << 20)
                        } catch {
                            throw NetDownloadError.mergeFailed("分片临时文件读取失败：\(temp.lastPathComponent)（\(error.localizedDescription)）")
                        }
                        // 官方语义：到达文件末尾返回空 Data（不是 nil），两者都作为正常结束
                        guard let chunk, !chunk.isEmpty else { break }
                        out.write(chunk)
                    }
                }
            } catch {
                // 拼接在 WriteTo 过程中失败会留下截断的目标文件；与校验失败路径同一处理，
                // 先删除再抛出，避免残缺文件被后续 .skip 预检固化为「已存在可复用」。
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        // 清理分片临时文件
        cleanupTemps(record)

        // 下载后大小校验：fileSize 已知时，成品必须与首片响应头声明的长度一致。
        // 这一层覆盖没有 checker 的调用方（SingleFileDownloader 不传 expectedSHA1 时 checker 为 nil），
        // 否则残缺文件只会在启动游戏时才暴露。
        if record.fileSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let actualSize = (attrs[.size] as? NSNumber)?.int64Value,
           actualSize != record.fileSize {
            try? FileManager.default.removeItem(at: destination)
            throw NetDownloadError.mergeFailed("文件大小不符，期望 \(record.fileSize) B，实际为 \(actualSize) B")
        }

        // 下载后四合一校验（PCL2 FileChecker.Check）
        if let checker = record.file.checker {
            if let err = checker.check(destination) {
                try? FileManager.default.removeItem(at: destination)
                throw NetDownloadError.fileFailed(err)
            }
        }
    }
}
