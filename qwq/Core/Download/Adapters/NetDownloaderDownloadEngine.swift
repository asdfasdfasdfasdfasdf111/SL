//
//  NetDownloaderDownloadEngine.swift
//  SL启动器
//
//  适配器：以现有 `NetManager`（SLCore/Download/NetDownloader.swift）为后端实现 `DownloadEngine`。
//
//  本文件只做两层转换，不改变任何下载行为：
//  1. `DownloadRequest` → `SLNetFile`（候选源由 `DownloadSourceResolver` 给出，校验参数由
//     `DefaultDownloadVerifier.checker(for:)` 翻译）；
//  2. 旧引擎的回调式进度 `(Double) -> Void` → `AsyncStream<DownloadState>`。
//
//  取消语义：旧引擎以「Swift Task 取消」表达取消（`waitForCompletion` 内 `Task.checkCancellation`），
//  因此 `cancel(taskID:)` 直接取消承载下载的 Task 即可，旧引擎会自行取消分片任务并清理临时文件。
//

import Foundation

public final class NetDownloaderDownloadEngine: DownloadEngine, @unchecked Sendable {

    // MARK: - 任务台账

    /// 单任务的适配状态。多订阅者以 continuations 数组承载（同一任务可被多处 observe）。
    private struct Entry {
        var task: Task<Void, Never>?
        var continuations: [AsyncStream<DownloadState>.Continuation]
        var lastState: DownloadState
        var cancelRequested: Bool
    }

    /// 旧引擎只上报比例值，不上报字节数。总大小未知时用该固定分母承载比例，
    /// 保证 `DownloadProgress.fraction` 与旧链路的 0…1 进度口径一致。
    private static let syntheticTotalBytes: Int64 = 1000

    /// 终态回放缓存上限。散列资源可达数万项，若保留全部已终结任务会导致台账无界增长。
    private static let terminalHistoryLimit = 256

    /// 源解析策略。
    private let resolver: DownloadSourceResolver
    /// 校验策略。旧引擎的下载后校验仍由 `NetManager.merge` 内的 `FileChecker` 承担，
    /// 这里保留依赖供迁移第 2 步接管，也供调用方在预检阶段复用同一套校验语义。
    public let verifier: DownloadVerifier
    /// 覆盖策略。`DownloadRequest` 不携带 `ReplaceMethod`，缺省取旧链路默认的 `.skip`；
    /// 需要 `.replace` / `.throw` 的调用方走 `submit(_:replaceMethod:)` 重载。
    private let defaultReplaceMethod: ReplaceMethod

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    /// 已终结任务的终态，供「下载结束后才调用 observe」的场景回放。
    /// `legacyFailureReason` 仅在失败终态非 nil，见 `legacyFailureReason(taskID:)`。
    private var terminalHistory: [(id: UUID, state: DownloadState, legacyFailureReason: String?)] = []

    public init(
        resolver: DownloadSourceResolver = DefaultDownloadSourceResolver(),
        verifier: DownloadVerifier = DefaultDownloadVerifier(),
        replaceMethod: ReplaceMethod = .skip
    ) {
        self.resolver = resolver
        self.verifier = verifier
        self.defaultReplaceMethod = replaceMethod
    }

    // MARK: - DownloadEngine

    @discardableResult
    public func submit(_ request: DownloadRequest) async throws -> DownloadHandle {
        try await submit(request, replaceMethod: defaultReplaceMethod)
    }

    /// 带覆盖策略的提交重载。旧链路里 `.replace`（覆盖已存在文件）与 `.skip`（复用已存在文件）
    /// 语义差别很大，迁移时必须由调用方显式指定。
    @discardableResult
    public func submit(_ request: DownloadRequest, replaceMethod: ReplaceMethod) async throws -> DownloadHandle {
        guard request.destinationURL.isFileURL else {
            throw DownloadError.unknown("目标路径必须是本地文件路径：\(request.destinationURL.absoluteString)")
        }

        let candidates = await resolver.candidateURLs(for: request)
        guard !candidates.isEmpty else { throw DownloadError.sourceUnavailable }

        let file = SLNetFile(
            urls: candidates,
            destination: request.destinationURL,
            checker: DefaultDownloadVerifier.checker(for: request),
            replaceMethod: replaceMethod
        )

        let taskID = UUID()
        insertEntry(taskID)

        // 强引用 self：下载期间引擎必须存活；任务终结时 Entry 会从台账移除，循环引用随之解除。
        let downloadTask = Task.detached(priority: .utility) {
            await self.run(taskID: taskID, file: file, expectedSize: request.expectedSize)
        }

        // 兜底：取消可能发生在 task 赋值前（此时 cancel 只能置位 cancelRequested）。
        if attach(downloadTask, to: taskID) { downloadTask.cancel() }

        return DownloadHandle(taskID: taskID, destination: request.destinationURL)
    }

    public func observe(taskID: UUID) -> AsyncStream<DownloadState> {
        lock.lock()
        if var entry = entries[taskID] {
            var continuation: AsyncStream<DownloadState>.Continuation!
            // 无界缓冲：进度事件由旧引擎节流到约 200ms 一次，不会积压；
            // 用有界策略反而可能丢弃终态事件。
            let stream = AsyncStream<DownloadState>(bufferingPolicy: .unbounded) { continuation = $0 }
            entry.continuations.append(continuation)
            let current = entry.lastState
            entries[taskID] = entry
            lock.unlock()
            continuation.yield(current)
            return stream
        }
        let terminal = terminalHistory.first { $0.id == taskID }?.state
        lock.unlock()

        return AsyncStream<DownloadState> { continuation in
            if let terminal { continuation.yield(terminal) }
            continuation.finish()
        }
    }

    public func cancel(taskID: UUID) async {
        // 取消承载下载的 Task：旧引擎在 waitForCompletion 内检测到取消后
        // 会取消全部分片任务、清理临时文件并抛出 CancellationError。
        markCancelRequested(taskID)?.cancel()
    }

    /// 旧链路的失败文案（`NetManager` 抛出错误的 `localizedDescription`），供迁移期调用方取用。
    ///
    /// 迁移期调用方（如 `ModFileDownloadTask`）把失败原因直接展示给用户，其文案必须与改造前逐字一致；
    /// 而结构化 `DownloadError` 会归一化文案（`httpStatus` → 「远程服务器返回了 404。」等），
    /// 部分原始细节（HTTP 状态码外的描述、磁盘剩余空间、超时类型）无法从结构化类型还原，
    /// 因此在终态发布时一并保留原始描述。任务终结后仍可查询（与终态回放同生命周期）。
    /// 非失败终态或未知 taskID 返回 nil。
    public func legacyFailureReason(taskID: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return terminalHistory.first { $0.id == taskID }?.legacyFailureReason
    }

    // MARK: - 台账读写（同步方法内持锁，避免在异步上下文中直接操作 NSLock）

    private func insertEntry(_ taskID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        entries[taskID] = Entry(task: nil, continuations: [], lastState: .idle, cancelRequested: false)
    }

    /// 绑定承载下载的 Task；返回 true 表示绑定前已被要求取消。
    private func attach(_ task: Task<Void, Never>, to taskID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[taskID] else { return false }
        entry.task = task
        let cancelRequested = entry.cancelRequested
        entries[taskID] = entry
        return cancelRequested
    }

    /// 置位取消标记，返回当前承载下载的 Task（任务尚未启动时为 nil）。
    private func markCancelRequested(_ taskID: UUID) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[taskID] else { return nil }
        entry.cancelRequested = true
        entries[taskID] = entry
        return entry.task
    }

    // MARK: - 执行与状态发布

    private func run(taskID: UUID, file: SLNetFile, expectedSize: Int64?) async {
        publish(.preparing, for: taskID)
        do {
            try await NetManager.shared.download(file) { [weak self] fraction in
                self?.publish(
                    .downloading(Self.progress(fraction: fraction, expectedSize: expectedSize)),
                    for: taskID
                )
            }
            // 旧引擎在「已存在且校验通过 → 跳过」分支同样回调 progress(1.0)，
            // 因此这里无法区分「跳过」与「实际下载」；只有被取消时才不能算完成。
            publish(isCancelRequested(taskID) ? .cancelled : .completed, for: taskID)
        } catch {
            if Self.isCancellation(error) || isCancelRequested(taskID) {
                publish(.cancelled, for: taskID)
            } else {
                publish(
                    .failed(Self.map(error)),
                    for: taskID,
                    legacyFailureReason: Self.legacyDescription(of: error)
                )
            }
        }
    }

    /// 发布状态。终态发布后任务从台账移除并进入终态回放缓存；此后再来的观察者只能拿到终态。
    private func publish(_ state: DownloadState, for taskID: UUID, legacyFailureReason: String? = nil) {
        lock.lock()
        guard var entry = entries[taskID] else { lock.unlock(); return }
        entry.lastState = state
        let targets = entry.continuations
        if state.isTerminal {
            entry.continuations = []
            entries.removeValue(forKey: taskID)
            terminalHistory.append((taskID, state, legacyFailureReason))
            if terminalHistory.count > Self.terminalHistoryLimit {
                terminalHistory.removeFirst(terminalHistory.count - Self.terminalHistoryLimit)
            }
        } else {
            entries[taskID] = entry
        }
        lock.unlock()

        for continuation in targets { continuation.yield(state) }
        if state.isTerminal {
            for continuation in targets { continuation.finish() }
        }
    }

    private func isCancelRequested(_ taskID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[taskID]?.cancelRequested ?? false
    }

    // MARK: - 进度与错误转换

    /// 旧引擎只回调 0…1 比例。已知总大小时换算为字节；未知时以固定分母承载比例，
    /// 保证 `DownloadProgress.fraction` 不退化。速度旧引擎按全局统计，不做每文件拆分，故置 0。
    private static func progress(fraction: Double, expectedSize: Int64?) -> DownloadProgress {
        let clamped = min(1, max(0, fraction))
        if let size = expectedSize, size > 0 {
            return DownloadProgress(bytesWritten: Int64(clamped * Double(size)), totalBytes: size)
        }
        return DownloadProgress(
            bytesWritten: Int64(clamped * Double(syntheticTotalBytes)),
            totalBytes: syntheticTotalBytes
        )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// 旧链路失败文案：`LocalizedError.errorDescription` 优先，否则 `localizedDescription`，
    /// 与旧实现「调用方取 `error.localizedDescription` 作为失败原因」的结果逐字一致。
    private static func legacyDescription(of error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// `NetDownloadError` 与字符串失败原因 → `DownloadError`。
    /// 旧实现把部分错误（HTTP 状态码、慢速、大小不符）编码进描述文本，这里按文本归类，
    /// 归类不出来的统一落入 `unknown`，保留原始描述不丢信息。
    private static func map(_ error: Error) -> DownloadError {
        if let downloadError = error as? DownloadError { return downloadError }

        if let netError = error as? NetDownloadError {
            switch netError {
            case .noAvailableSource(_):
                return .sourceUnavailable
            case .sourceNoResumeSupport:
                return .rangeNotSupported
            case .slowSpeed:
                return .timeout
            default:
                break
            }
        }

        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let code = httpStatusCode(in: description) { return .httpStatus(code) }
        if description.contains("哈希校验失败") { return .checksumMismatch }
        if description.contains("磁盘空间不足") { return .diskFull }
        if description.contains("超时") || description.contains("速度过慢") { return .timeout }
        return .unknown(description)
    }

    /// 从「远程服务器返回了 404」一类的描述中提取状态码。
    private static func httpStatusCode(in description: String) -> Int? {
        guard let range = description.range(of: "远程服务器返回了 ") else { return nil }
        let digits = description[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
