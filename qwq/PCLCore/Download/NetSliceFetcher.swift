//
//  NetSliceFetcher.swift
//  PCL.Mac
//
//  NetManager 的分片执行与状态回调（对标 PCL2 NetThread）：
//  - startSliceTask：把分片交给 detached 任务执行，成功/失败回调 actor；
//  - runSlice：Range 请求、identity 编码、自适应超时、断流与慢速检测、5 分钟总超时、
//    256KB 缓冲落盘、按 undone 截断写入；
//  - sliceSucceeded / sliceFailed：分片终态归位（断流未下满视为失败走续传、源失败记账、连接层错误直接淘汰该源）；
//  - 末尾「分片执行器内部接口」是 detached 任务读写 actor 状态的原子边界（文件大小确立、分片临时文件与进度记账）。
//  自 NetDownloader.swift 按职责物理拆出，原第 537-737、835-889 行。
//  请求头、超时公式、阈值与写入顺序均未改动。
//
//  本次修复（同一源可无限重试 / 进度停住）：sliceSucceeded 的断流分支原先只把 failCount 加一，
//  而 failCount 全工程无人读取（超时公式读的是 sourceFails），也不拉黑源，因此同一源可被无限
//  续传重试。现改为复用既有的源失败机制（sourceFails + maxFailPerSource + pickSource +
//  isAllSourcesFailed），与 sliceFailed 的记账口径一致。
//

import Foundation

extension NetManager {
    // MARK: - 分片执行（PCL2 NetThread）

    func startSliceTask(_ record: FileRecord, _ slice: Slice) {
        activeSlices += 1
        let fileID = record.id
        let sliceID = slice.id
        let sourceIndex = slice.sourceIndex
        let urls = record.file.urls
        let start = slice.start
        let isFirst = record.fileSize == -2 && start == 0

        let task = Task.detached(priority: .utility) {
            do {
                try await Self.runSlice(manager: self, fileID: fileID, sliceID: sliceID, sourceIndex: sourceIndex, urls: urls, start: start, isFirst: isFirst)
                await self.sliceSucceeded(fileID: fileID, sliceID: sliceID)
            } catch {
                await self.sliceFailed(fileID: fileID, sliceID: sliceID, error: error)
            }
        }
        record.sliceTasks[sliceID] = task
    }

    static func runSlice(manager: NetManager, fileID: UUID, sliceID: UUID, sourceIndex: Int, urls: [URL], start: Int64, isFirst: Bool) async throws {
        let url = urls[sourceIndex]
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("PCL.Mac/\(SharedConstants.shared.version)", forHTTPHeaderField: "User-Agent")
        // 显式禁用压缩：URLSession 默认自动发送 Accept-Encoding: gzip，
        // 服务器对压缩响应会忽略 Range 返回 200 全量（实测 piston-meta：gzip→200，identity→206），
        // 导致分片被误判为「源不支持断点续传」退化为单线程全量下载。PCL2 无此问题（.NET 默认 identity）。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if start > 0 {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        }

        // 自适应超时：max(ConnectAverage=6s, 6s) * (1 + FailCount)，上限 30s（PCL2 1031 行）
        let failCount = await manager.sourceFailCount(fileID: fileID, sourceIndex: sourceIndex)
        request.timeoutInterval = min(30, 6 * Double(1 + failCount))

        // 统一直连会话（绕过系统代理）：系统代理对 bmclapi2 / mojang 的 TLS 转发失败时，
        // URLSession 会报 SecureConnectionFailed（curl 直连正常），这里改用 URLSession.direct
        // 直连，官方源被墙时由 pickSource 自动切镜像源。（详见 Requests.swift URLSession.direct）
        let (stream, response) = try await URLSession.direct.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NetDownloadError.fileFailed("无效的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetDownloadError.fileFailed("远程服务器返回了 \(http.statusCode)")
        }

        // 非首线程却返回 200（服务器忽略 Range 返回全量）→ 该源不支持断点续传（PCL2 1080-1088 行）
        if start > 0 && http.statusCode == 200 {
            await manager.sourceRejectsRange(fileID: fileID, sourceIndex: sourceIndex)
            throw NetDownloadError.sourceNoResumeSupport
        }

        // 首线程：确定文件大小并校验（PCL2 1044-1077 行）
        if isFirst {
            let length = http.expectedContentLength
            if length > 0 {
                try await manager.establishFileSize(fileID: fileID, size: length)
            } else {
                await manager.markUnknownSize(fileID: fileID)
            }
        }

        // 创建分片临时文件（目录可能被系统/用户清理，下载前再次确保存在）
        try FileManager.default.createDirectory(
            at: SharedConstants.shared.temperatureURL,
            withIntermediateDirectories: true
        )
        let tempURL = SharedConstants.shared.temperatureURL.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw NetDownloadError.fileFailed("无法创建临时文件")
        }
        await manager.sliceSetTemp(fileID: fileID, sliceID: sliceID, tempURL: tempURL)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var buffer = Data(capacity: 256 * 1024)
        var counter = 0
        var bytesSinceCheck: Int64 = 0
        var lastCheckTime = Date()
        let sliceStartTime = Date()

        for try await byte in stream {
            try Task.checkCancellation()
            buffer.append(byte)
            bytesSinceCheck += 1
            counter += 1

            // 慢速检测：间隔 > 1s 且速度 < 1KB/s 断开（PCL2 1158 行）
            if counter >= 1024 {
                counter = 0
                let now = Date()
                // 总超时：分片下载超过 5 分钟视为网络异常（TCP 半开连接间歇传少量数据可绕过慢速检测）
                if now.timeIntervalSince(sliceStartTime) > 300 {
                    throw NetDownloadError.fileFailed("分片下载超时（5 分钟）")
                }
                let dt = now.timeIntervalSince(lastCheckTime)
                if dt > 1.0 {
                    let speed = Double(bytesSinceCheck) / dt
                    if speed < 1024 {
                        throw NetDownloadError.slowSpeed
                    }
                    bytesSinceCheck = 0
                }
                lastCheckTime = now
            }

            if buffer.count >= 256 * 1024 {
                let remaining = await manager.sliceUndone(fileID: fileID, sliceID: sliceID)
                let toWrite: Int
                if remaining < 0 {
                    toWrite = buffer.count
                } else if remaining == 0 {
                    break
                } else {
                    toWrite = min(buffer.count, Int(remaining))
                }
                handle.write(Data(buffer.prefix(toWrite)))
                await manager.sliceAppend(fileID: fileID, sliceID: sliceID, bytes: toWrite)
                await SpeedMeter.shared.addBytes(toWrite)
                await manager.addBytes(Int64(toWrite))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        // 剩余缓冲
        if !buffer.isEmpty {
            let remaining = await manager.sliceUndone(fileID: fileID, sliceID: sliceID)
            let toWrite: Int
            if remaining < 0 {
                toWrite = buffer.count
            } else if remaining == 0 {
                toWrite = 0
            } else {
                toWrite = min(buffer.count, Int(remaining))
            }
            if toWrite > 0 {
                handle.write(Data(buffer.prefix(toWrite)))
                await manager.sliceAppend(fileID: fileID, sliceID: sliceID, bytes: toWrite)
                await SpeedMeter.shared.addBytes(toWrite)
                await manager.addBytes(Int64(toWrite))
            }
        }
    }

    // MARK: 分片状态回调

    func sliceSucceeded(fileID: UUID, sliceID: UUID) async {
        // 递减必须在可早退的 guard **之前**：文件记录可能已被 download / downloadAll 的收尾流程移除
        // （NetDownloader.swift:87,90,135），此回调找不到记录会直接 return。若把递减放在 guard 之后，
        // activeSlices 就永久虚高，累计到 config.maxSlices 后 tryBeginSlice 的
        // `activeSlices < config.maxSlices`（NetSliceAllocation.swift:17）恒为 false，
        // 之后所有下载都不再启动任何分片。
        // 不会重复扣减：startSliceTask 为每个分片建立的 detached 任务只产生一次终态回调
        // （runSlice 正常返回 → sliceSucceeded，抛错 → sliceFailed），二者互斥且各调用一次。
        activeSlices = max(0, activeSlices - 1)
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        record.sliceTasks[sliceID] = nil
        // 服务器提前断流仍有剩余 → 视为失败，走断点续传（PCL2 1173 行）
        if record.fileSize != -1 && slice.undone(of: record) > 0 {
            slice.state = .failed
            record.failCount += 1
            // 断流与 sliceFailed 走同一套源失败记账：原实现只累加 failCount（该字段无人读取），
            // 既不拉黑源也不触发换源，同一源可以被无限续传重试，用户侧表现为「进度停住、
            // 既不失败也不换源」。计入 sourceFails 后：自适应超时随之增长（runSlice 的 6s×(1+失败数)），
            // 同一源失败 maxFailPerSource 次即被 pickSource 跳过，全部源耗尽则由下面的
            // isAllSourcesFailed 置为失败并清理临时分片。
            record.sourceFails[slice.sourceIndex, default: 0] += 1
            record.failReason = "连接中断，分片未下载完整"
            if record.isAllSourcesFailed(config.maxFailPerSource) {
                record.state = .failed
                cleanupTemps(record)
            }
            return
        }
        slice.state = .done
        tryMergeIfPossible(record)
    }

    func sliceFailed(fileID: UUID, sliceID: UUID, error: Error) async {
        // 同 sliceSucceeded：递减先于 guard，保证记录已被移除时也归还分片额度（理由同上）。
        activeSlices = max(0, activeSlices - 1)
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        record.sliceTasks[sliceID] = nil
        slice.state = .failed
        record.failCount += 1
        record.sourceFails[slice.sourceIndex, default: 0] += 1
        // 连接层错误（SSL 握手失败 / 无法连接 / DNS / 连接中断）说明该源当前不可达，
        // 同源重试只会浪费时间（实测 SecureConnectionFailed 每源重试 3 次共耗 45s），
        // 直接把失败计数拉满，让 pickSource 立即跳过该源换下一个。
        if Self.isConnectionLevelError(error) {
            record.sourceFails[slice.sourceIndex] = config.maxFailPerSource
            record.failReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if record.isAllSourcesFailed(config.maxFailPerSource) {
            record.state = .failed
            record.failReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            cleanupTemps(record)
        }
    }

    // MARK: 分片执行器内部接口

    func establishFileSize(fileID: UUID, size: Int64) throws {
        guard let record = find(fileID) else { return }
        record.fileSize = size
        if let checker = record.file.checker {
            if checker.minSize > 0 && size < checker.minSize {
                throw NetDownloadError.fileFailed("文件大小不足，获取结果为 \(size) B，要求至少为 \(checker.minSize) B")
            }
            if checker.actualSize > 0 && size != checker.actualSize {
                throw NetDownloadError.fileFailed("文件大小不一致，获取结果为 \(size) B，要求必须为 \(checker.actualSize) B")
            }
        }
        // >50MB 磁盘空间预检（PCL2 1066-1077 行）
        if size > 50 * 1024 * 1024 {
            if let values = try? record.file.destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let capacity = values.volumeAvailableCapacityForImportantUsage,
               capacity < size + 5 * 1024 * 1024 {
                throw NetDownloadError.fileFailed("磁盘空间不足，需要至少 \(size + 5 * 1024 * 1024) B，当前仅剩余 \(capacity) B")
            }
        }
    }

    func markUnknownSize(fileID: UUID) {
        find(fileID)?.fileSize = -1
    }

    func sliceSetTemp(fileID: UUID, sliceID: UUID, tempURL: URL) {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        slice.tempURL = tempURL
    }

    func sliceAppend(fileID: UUID, sliceID: UUID, bytes: Int) {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        slice.done += Int64(bytes)
    }

    func sliceUndone(fileID: UUID, sliceID: UUID) -> Int64 {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return -1 }
        if record.fileSize == -1 { return -1 }
        return slice.undone(of: record)
    }

    func addBytes(_ n: Int64) {
        totalBytes += n
    }
}
