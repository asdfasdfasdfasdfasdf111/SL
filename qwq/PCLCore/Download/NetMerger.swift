//
//  NetMerger.swift
//  PCL.Mac
//
//  NetManager 的分片合并与下载后校验（对标 PCL2 Merge）：
//  - tryMergeIfPossible：无活动分片且不存在待续传分片时触发合并，成功置 done 并回调完成，
//    失败置 failed 并清理临时分片；
//  - merge：覆盖策略处理（.replace/.skip 覆盖、.throw 抛错）、单分片直接移动、
//    多分片按 start 升序流式拼接、拼接后清理临时文件、下载后四合一校验，
//    校验失败先删除目标文件再抛错（避免坏文件被后续 .skip 预检永久固化）。
//  自 NetDownloader.swift 按职责物理拆出，原第 739-799 行，判定顺序、拼接顺序与文案均未改动。
//

import Foundation

extension NetManager {
    // MARK: - 合并（PCL2 Merge，1295-1335 行）

    func tryMergeIfPossible(_ record: FileRecord) {
        guard record.activeSliceCount == 0 else { return }
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
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            for slice in withData {
                guard let temp = slice.tempURL, let input = try? FileHandle(forReadingFrom: temp) else { continue }
                defer { try? input.close() }
                while let data = try? input.read(upToCount: 1 << 20), !data.isEmpty {
                    out.write(data)
                }
            }
        }
        // 清理分片临时文件
        cleanupTemps(record)

        // 下载后四合一校验（PCL2 FileChecker.Check）
        if let checker = record.file.checker {
            if let err = checker.check(destination) {
                try? FileManager.default.removeItem(at: destination)
                throw NetDownloadError.fileFailed(err)
            }
        }
    }
}
