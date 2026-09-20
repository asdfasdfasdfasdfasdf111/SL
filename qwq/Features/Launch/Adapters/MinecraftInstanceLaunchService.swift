//
//  MinecraftInstanceLaunchService.swift
//  启动用例层适配器：`LaunchService` → 现有桥接启动流程（`pclLaunch`）的包装
//
//  本文件是**包装层**，不是合并层：它把 `LaunchRequest` 与六段回调互相翻译，
//  内部调用的仍是 `PCLLaunchBridge.pclLaunch`（即现有的第二套启动实现），
//  `MinecraftInstance.launch(_:)` 那条流程原样保留、未被触碰。
//
//  MARK: - 为什么包 `pclLaunch` 而不是 `MinecraftInstance.launch(_:)`
//
//  `LaunchService.launch` 契约要求返回退出码、会话标识与日志位置；
//  `MinecraftInstance.launch(_:)` 是 `async` 且**无返回值**（退出码只在内部用于弹窗），
//  无法满足契约；`pclLaunch` 的 `completion` 携带
//  `(MinecraftLauncher?, Result<Int32, Error>)`，是当前唯一能提供退出码与 launcher 引用的入口。
//  两条流程的完整差异见 `Adapters/DUAL_FLOW.md`。
//
//  MARK: - 回调 → LaunchState 映射
//
//  | pclLaunch 回调 / 相位 | 触发时机（桥接层）                        | 本服务投递的状态 |
//  |----------------------|------------------------------------------|-----------------|
//  | （进入 launch）        | 调用 pclLaunch 之前                       | `.preparing` |
//  | `phaseHandler("downloading")` | 调用 LaunchFix 之前               | `.downloading(0)` |
//  | `progressHandler(p)`  | LaunchFix 的 onProgress（每文件回调）      | `.downloading(p)`（1% 阈值合并） |
//  | `phaseHandler("launching")` | LaunchFix 完成后、Java 选择之前      | `.resolvingJava` |
//  | `onLauncherReady`     | Java 选择 / 参数适配完成、进程将拉起时     | `.launching` |
//  | `launchSuccess`       | CGWindowList 检测到游戏窗口（或退出码 0）  | `.running` |
//  | `completion`          | 进程退出 / 启动失败                        | `.finished(result)` / `.failed(error)` |
//  | （terminate 被调用）   | 服务侧主动终止                            | `.stopping` |
//
//  源映射不可达 / 不精确之处（合并阶段需修正，详见 DUAL_FLOW.md 风险点）：
//    - `.verifyingFiles` 恒不可达：`LaunchFix.perform` 把「校验」与「下载」合成一条进度，
//      不暴露「校验完成」事件，无法与 `.downloading` 区分。
//    - `.buildingArguments` 恒不可达：桥接层未为「参数组装完成」提供回调。
//    - `phaseHandler("launching")` 语义是「进入 Java 选择与参数组装」，与 `LaunchState.launching`
//      （正在拉起进程）不等价，故映射到 `.resolvingJava`；`.launching` 由 `onLauncherReady` 产生。
//    - 桥接层不会发出 `phaseHandler("installing")`（该相位只存在于 UI 侧 `LaunchPhase`）。
//
//  MARK: - LaunchRequest 字段在本包装中的实际去处（未接入的字段必须在合并阶段补齐）
//
//  | LaunchRequest 字段        | 现状 | 说明 |
//  |--------------------------|------|------|
//  | version / gameRoot        | 已使用 | 直接对应 `pclLaunch(version:gameDir:)`，gameDir 语义即 `MinecraftDirectory.rootURL` |
//  | offlineUsername           | 已使用 | 直接对应 `pclLaunch(username:)`；用户名校验由桥接层内部执行（本服务不重复校验） |
//  | instanceID / runningDirectory | 未使用 | 桥接层自行用 `MinecraftDirectory` + `MinecraftInstance.create` 建实例 |
//  | javaExecutable            | 未使用 | 桥接层自行走 JavaResolverBridge → DataManager → JavaManager 三级选择 |
//  | memoryMB / qualityOfServiceRawValue | 未使用 | 内存与 QoS 取自 `instance.config.maxMemory` / `.qualityOfService`，不经过请求 |
//  | extraJVMArgs / windowSize | 未使用 | 桥接层只做 `--sun-misc-unsafe-memory-access` 过滤，无自定义参数与窗口尺寸入口 |
//  | isDemo / skipResourceCheck | 未使用 | 见 DUAL_FLOW.md 风险点 R4（skipResourceCheck 语义歧义） |
//
//  MARK: - 终止路径（重要）
//
//  `GameSessionStore.terminate(sessionID:)` 内部只做 `ManagedProcess.terminate()`，
//  等价于 `Process.terminate()`，**不会**设置 `MinecraftLauncher.isUserTerminated`。
//  而桥接层与 UI 都依赖该标志区分「用户主动关闭」与「异常退出」：
//  缺少该标志时，用户关闭游戏会被判定为异常退出并弹出「Minecraft 异常退出」提示。
//  因此本服务的 `terminate(sessionID:)` 不经会话存储，直接调用 `MinecraftLauncher.terminate()`。
//

import Foundation
import os

/// 服务侧可变状态整体（作用域锁保护，避免 NSLock 在 async 上下文中的不可用告警）；
/// `MinecraftLauncher` 为引用类型且非 Sendable，故此处显式声明不做检查。
private struct LaunchRunningState: @unchecked Sendable {
    var launchers: [UUID: MinecraftLauncher] = [:]
}

public final class MinecraftInstanceLaunchService: LaunchService, @unchecked Sendable {

    /// 日志行回调（会话 ID，日志行）。接线后由 UI 侧订阅替代 `launcher.pendingLogs` 暂存机制。
    public typealias LogSink = @Sendable (UUID, String) -> Void

    private let sessionStore: GameSessionStore?
    private let logSink: LogSink?

    /// 会话 ID → launcher 引用，供 terminate 使用
    private let runningState = OSAllocatedUnfairLock<LaunchRunningState>(initialState: .init())

    public init(sessionStore: GameSessionStore? = nil, logSink: LogSink? = nil) {
        self.sessionStore = sessionStore
        self.logSink = logSink
    }

    // MARK: - LaunchService

    @discardableResult
    public func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        let sessionID = UUID()
        let startedAt = Date()
        // 桥接层理论上只回调一次 completion（MinecraftLauncher 内部有一次性门控），
        // 这里再加一道门控，防止 continuation 被重复恢复（重复恢复会直接触发运行时崩溃）
        let gate = LaunchResumeGate()
        let progressRelay = LaunchProgressRelay(store: sessionStore, sessionID: sessionID)

        await sessionStore?.update(.preparing, for: sessionID)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LaunchResult, Error>) in
            pclLaunch(
                version: request.version,
                username: request.offlineUsername,
                gameDir: request.gameRoot.path,
                progressHandler: { progress in
                    progressRelay.emit(progress)
                },
                phaseHandler: { [weak self] phase in
                    self?.handle(phase: phase, sessionID: sessionID)
                },
                logHandler: { [weak self] line in
                    self?.logSink?(sessionID, line)
                },
                launchSuccess: { [weak self] in
                    guard let self else { return }
                    Task { await self.sessionStore?.update(.running, for: sessionID) }
                },
                onLauncherReady: { [weak self] launcher in
                    guard let self else { return }
                    self.remember(sessionID: sessionID, launcher: launcher)
                    self.registerSessionWhenProcessStarts(
                        sessionID: sessionID,
                        launcher: launcher,
                        startedAt: startedAt
                    )
                    Task { await self.sessionStore?.update(.launching, for: sessionID) }
                },
                completion: { [weak self] launcher, result in
                    guard gate.claim() else { return }
                    Task {
                        switch result {
                        case .success(let exitCode):
                            let launchResult = LaunchResult(
                                exitCode: Int(exitCode),
                                sessionID: sessionID,
                                logURL: launcher?.logURL,
                                duration: Date().timeIntervalSince(startedAt)
                            )
                            await self?.sessionStore?.update(.finished(launchResult), for: sessionID)
                            self?.forget(sessionID: sessionID)
                            continuation.resume(returning: launchResult)
                        case .failure(let error):
                            // 进程未成功拉起：按契约抛错，不返回 LaunchResult
                            let launchError = Self.mapFailure(error, version: request.version)
                            await self?.sessionStore?.update(.failed(launchError), for: sessionID)
                            self?.forget(sessionID: sessionID)
                            continuation.resume(throwing: launchError)
                        }
                    }
                }
            )
        }
    }

    public func terminate(sessionID: UUID) async {
        let launcher = runningState.withLock { $0.launchers[sessionID] }

        guard let launcher else {
            warn("[LaunchService] terminate 未命中会话 \(sessionID)（可能已退出或非本服务创建）")
            return
        }

        await sessionStore?.update(.stopping, for: sessionID)
        launcher.terminate()
    }

    // MARK: - 相位映射

    private func handle(phase: String, sessionID: UUID) {
        switch phase {
        case "downloading":
            // LaunchFix 的「校验 + 补齐」阶段（校验事件不可观测，统一按下载阶段投递）
            push(.downloading(0), sessionID: sessionID)
        case "launching":
            // 桥接层此相位的语义是「进入 Java 选择与参数组装」，故映射为 resolvingJava
            push(.resolvingJava, sessionID: sessionID)
        default:
            break
        }
    }

    private func push(_ state: LaunchState, sessionID: UUID) {
        Task { await sessionStore?.update(state, for: sessionID) }
    }

    // MARK: - 会话登记

    private func remember(sessionID: UUID, launcher: MinecraftLauncher) {
        runningState.withLock { $0.launchers[sessionID] = launcher }
    }

    private func forget(sessionID: UUID) {
        runningState.withLock { _ = $0.launchers.removeValue(forKey: sessionID) }
    }

    /// `onLauncherReady` 回调时 `launcher.currentProcess` 仍为 nil
    /// （进程在 `MinecraftLauncher.launch` 内部才被创建），而 `GameSessionRecord` 需要 `ManagedProcess`，
    /// 故短暂轮询等待进程出现后再登记会话；超时只告警，不影响启动与终止
    /// （终止路径持有 launcher 引用，不依赖会话登记）。
    private func registerSessionWhenProcessStarts(sessionID: UUID, launcher: MinecraftLauncher, startedAt: Date) {
        Task.detached(priority: .utility) { [weak self] in
            for _ in 0..<100 {
                if let process = launcher.currentProcess, process.isRunning {
                    await self?.sessionStore?.register(
                        GameSessionRecord(
                            sessionID: sessionID,
                            process: ManagedProcess(process: process),
                            startedAt: startedAt
                        )
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 50 * 1_000_000)
            }
            log("[LaunchService] 5s 内未取得进程引用，会话 \(sessionID) 未登记（启动与终止不受影响）")
        }
    }

    // MARK: - 错误映射

    /// 桥接层以 `MyLocalizedError(reason:)` 携带中文文案返回失败，没有类型化错误码，
    /// 故此处按文案前缀做一次映射。**这是临时桥接**：
    /// 文案本地化或改写都会静默退化为 `.unknown`（见 DUAL_FLOW.md 风险点 R5）。
    static func mapFailure(_ error: Error, version: String) -> LaunchError {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // 桥接层对「进程未拉起」统一加「启动失败：」前缀（与「游戏异常退出（退出码 N）」区分），
        // 此处剥掉前缀后交给 .processStartFailed，避免与 errorDescription 的前缀重复。
        if let range = message.range(of: "启动失败：") {
            let reason = String(message[range.upperBound...])
            return .processStartFailed(reason: reason.isEmpty ? message : reason)
        }
        if message.contains("无法创建实例") {
            return .instanceNotFound(version: version)
        }
        if message.contains("启动前补全") {
            return .fileVerificationFailed(reason: message)
        }
        if let major = requiredJavaMajor(in: message) {
            return .javaNotFound(requiredMajorVersion: major)
        }
        return .unknown(message)
    }

    /// 从「未找到满足版本要求 (Java 21+) 的 Java 安装」这类文案中提取最低 Java 主版本
    private static func requiredJavaMajor(in message: String) -> Int? {
        guard let range = message.range(of: #"Java (\d+)\+"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst(5).dropLast())
    }
}

// MARK: - 内部状态

/// completion → continuation 的一次性门控
private final class LaunchResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// 进度投递限流：`LaunchFix` 的 onProgress 按每个文件回调（资源可达数千项），
/// 逐条投递会创建数千个 Task；此处按 1% 阈值合并，语义上仍是单调前进的进度。
private final class LaunchProgressRelay: @unchecked Sendable {

    private let lock = NSLock()
    private var lastEmitted: Double = -1
    private let store: GameSessionStore?
    private let sessionID: UUID

    init(store: GameSessionStore?, sessionID: UUID) {
        self.store = store
        self.sessionID = sessionID
    }

    func emit(_ value: Double) {
        lock.lock()
        guard value - lastEmitted >= 0.01 else {
            lock.unlock()
            return
        }
        lastEmitted = value
        lock.unlock()

        let store = self.store
        let sessionID = self.sessionID
        Task { await store?.update(.downloading(value), for: sessionID) }
    }
}
