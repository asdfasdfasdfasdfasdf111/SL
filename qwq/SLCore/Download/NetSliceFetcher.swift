//
//  NetSliceFetcher.swift
//  SL启动器
//
//  NetManager 的分片执行与状态回调（对标 PCL2 NetThread）：
//  - startSliceTask：把分片交给 detached 任务执行，成功/失败回调 actor；
//  - runSlice：Range 请求、identity 编码、自适应超时、断流与慢速检测、
//    随剩余量/速度缩放的总超时、256KB 缓冲落盘、按 undone 截断写入；
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

/// 分片「总超时」的下界（秒）。
/// 取原实现写死的 300s：小分片 / 快连接的口径与改动前**逐秒一致**，不引入任何放宽。
///
/// 显式 `nonisolated`：工程默认隔离是 MainActor，未标注的文件级 `let` 会被推断成主 actor 隔离，
/// 而 `runSlice` 是 `static func`（不受 actor 隔离）—— 从那里读它就会报
/// 「main actor-isolated let … cannot be accessed from outside of the actor」，
/// 而且是**静默的**：`-typecheck` 只在开了 `-default-isolation MainActor` 时才看得见。
private nonisolated let sliceBudgetFloor: TimeInterval = 300

/// 分片「总超时」的上界（秒）。慢连接也不该被无限拖住：20 分钟仍未下完，按网络异常处理。
private nonisolated let sliceBudgetCeiling: TimeInterval = 1200

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

    /// 由「本分片剩余字节数」与「实测速度」算出下一轮的总超时预算（秒）。
    ///
    /// 抽成 `nonisolated static` 纯函数是为了**可测**：调用点藏在 `runSlice` 的字节循环里，
    /// 需要真实网络栈才能跑到，而这里的公式才是本次修复的全部内容 —— 放在循环里就等于没法钉住它。
    /// 判定与边界（测试见 `qwqTests/DownloadSliceBudgetTests.swift`）：
    ///  - 剩余量或速度不可用（`remainingBytes <= 0`、速度非正或非有限）→ 取下界，即原口径 300s；
    ///  - 其余情况 `clamp(剩余 / 速度 × 2, 下界, 上界)`。
    ///    × 2 是给速度波动留一倍余量；下界保证「快连接 / 小分片」判定与改动前逐秒一致（不放松），
    ///    上界保证病态涓流仍会被截断。
    nonisolated static func sliceBudget(remainingBytes: Int64, bytesPerSecond: Double) -> TimeInterval {
        guard remainingBytes > 0, bytesPerSecond > 0, bytesPerSecond.isFinite else {
            return sliceBudgetFloor
        }
        let estimate = Double(remainingBytes) / bytesPerSecond
        guard estimate.isFinite else { return sliceBudgetCeiling }
        return min(sliceBudgetCeiling, max(sliceBudgetFloor, estimate * 2))
    }

    static func runSlice(manager: NetManager, fileID: UUID, sliceID: UUID, sourceIndex: Int, urls: [URL], start: Int64, isFirst: Bool) async throws {
        let url = urls[sourceIndex]
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("SL启动器/\(SharedConstants.shared.version)", forHTTPHeaderField: "User-Agent")
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

        // 在 actor 内原子地创建并登记分片临时文件：磁盘 createFile 与 slice.tempURL 的赋值
        // 同处一个 actor 方法，消除了原实现「detached 任务先在磁盘 createFile 成功、再 await sliceSetTemp
        // 注册前，记录已被 download / downloadAll 收尾的 removeAll 移除」的竞态——
        // 该竞态会让临时文件既不在任何 record 的 slices 中、也不被 cleanupTemps 清理，成为孤儿文件（无界增长）。
        let tempURL = try await manager.sliceCreateTemp(fileID: fileID, sliceID: sliceID)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var buffer = Data(capacity: 256 * 1024)
        var counter = 0
        var bytesSinceCheck: Int64 = 0
        var lastCheckTime = Date()
        let sliceStartTime = Date()
        /// 本分片当前的总超时预算（秒）。随实测速度与剩余量放大，见下方判定块。
        var sliceBudget: TimeInterval = sliceBudgetFloor
        /// 本分片**观测到的最慢**速度（字节/秒）。用最慢值估算剩余耗时是刻意保守的：
        /// 预算只会变大不会变小，避免「开头一个速度尖峰把预算算小、之后被误杀」。
        var slowestSpeed: Double = .infinity

        for try await byte in stream {
            try Task.checkCancellation()
            buffer.append(byte)
            bytesSinceCheck += 1
            counter += 1

            // 慢速检测：间隔 > 1s 且速度 < 1KB/s 断开（PCL2 1158 行）
            if counter >= 1024 {
                counter = 0
                let now = Date()

                // 总超时（分片）：**随剩余量与实测速度缩放**，不再是固定 5 分钟。
                //
                // 原实现写死 300s，与分片大小、网速都无关 —— 对「连接健康且持续推进、只是慢」
                // 的下载是一把无差别的一刀切，而后果不是「晚点到」而是**失败**：
                //   ① 每次超时给该源记一次 `sourceFails`（下方 sliceFailed），
                //      阈值 `maxFailPerSource = 3`，满 3 次该源被 pickSource 永久跳过；
                //   ② 全部源满 3 次 → `isAllSourcesFailed` 把文件置为 failed 并
                //      `cleanupTemps` **删掉已下好的分片临时文件** —— 进度归零。
                // 触发面并不窄：分片是「切尾部 40%」逐步裂开的，16 个分片池被占满时大文件仍是一个大分片；
                // 而 github / gitcode 这类被 ③ 分支判为「禁多线程」的源**从不分片**，
                // 整个文件就是一个分片，300s 直接罩住全文件（100MB @ 300KB/s ≈ 341s 就中招）。
                //
                // 新口径：预算 = clamp(预计剩余耗时 × 2, 300s, 1200s)。
                //   - 预计耗时的速度取**本分片最慢观测值**（保守，见 slowestSpeed 的说明）；
                //   - 下界仍是 300s → 快连接 / 小分片的判定与改动前完全一致，不放松；
                //   - 上界 1200s → 真正病态的「涓流」仍会被截断，只是从 5 分钟放宽到 20 分钟；
                //   - 大小未知（`sliceUndone` 返回 -1，服务端无 Content-Length）时无法估算，
                //     预算保持 300s —— 这是本次**有意保留**的旧口径，见 CHANGELOG 的说明。
                let used = now.timeIntervalSince(sliceStartTime)
                if used > sliceBudget {
                    throw NetDownloadError.fileFailed(
                        "分片下载超时（已用 \(Int(used))s，本次预算 \(Int(sliceBudget))s）"
                    )
                }

                let dt = now.timeIntervalSince(lastCheckTime)
                if dt > 1.0 {
                    let speed = Double(bytesSinceCheck) / dt
                    if speed < 1024 {
                        throw NetDownloadError.slowSpeed
                    }
                    bytesSinceCheck = 0

                    // 用本窗口的实测速度重算**下一轮**的预算（本轮已用旧预算判过，
                    // 因此「慢速优先于总超时抛出」的原有顺序没有改变）。
                    slowestSpeed = min(slowestSpeed, speed)
                    let remaining = await manager.sliceUndone(fileID: fileID, sliceID: sliceID)
                    sliceBudget = Self.sliceBudget(remainingBytes: remaining, bytesPerSecond: slowestSpeed)
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
                // 必须用 throwing 版本：旧的无返回值 `write(_:)` 在磁盘满/IO 错误时抛的是
                // ObjC 异常（NSFileHandleOperationException），Swift 的 do/catch 抓不到，会直接
                // 崩掉进程。改成抛 Swift 错误后，失败沿本函数的 throws 走到 sliceFailed，
                // 按「断流续传 / 源判死」既有路径处理，而不是崩。
                // 另注：磁盘空间预检只覆盖 >50MB 的文件（见下方 236 行），小文件本来无人兜底。
                try handle.write(contentsOf: Data(buffer.prefix(toWrite)))
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
                // 同上方分片主循环：throwing 版本，避免磁盘写失败时抛 ObjC 异常崩进程。
                try handle.write(contentsOf: Data(buffer.prefix(toWrite)))
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

    func sliceCreateTemp(fileID: UUID, sliceID: UUID) throws -> URL {
        guard let record = find(fileID), let slice = record.slice(sliceID) else {
            throw NetDownloadError.fileFailed("下载记录已不存在，无法创建分片临时文件")
        }
        try FileManager.default.createDirectory(
            at: SharedConstants.shared.temperatureURL,
            withIntermediateDirectories: true
        )
        let tempURL = SharedConstants.shared.temperatureURL.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw NetDownloadError.fileFailed("无法创建临时文件")
        }
        slice.tempURL = tempURL
        return tempURL
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
