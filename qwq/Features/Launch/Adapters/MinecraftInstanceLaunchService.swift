//
//  MinecraftInstanceLaunchService.swift
//  启动用例层适配器：`LaunchService` → 现有桥接启动流程（`slLaunch`）的包装
//
//  本文件是**包装层**，不是合并层：它把 `LaunchRequest` 与六段回调互相翻译，
//  内部调用的仍是 `SLLaunchBridge.slLaunch`（唯一的启动实现）。
//  原 `MinecraftInstance.launch(_:)`（流程 A）已于本次改动中删除，本文件不再引用它。
//
//  MARK: - 为什么包 `slLaunch`
//
//  `LaunchService.launch` 契约要求返回退出码、会话标识与日志位置；
//  `slLaunch` 的 `completion` 携带
//  `(MinecraftLauncher?, Result<Int32, Error>)`，是能提供退出码与 launcher 引用的入口。
//  启动流程的差异背景见 `Adapters/LAUNCH_FLOW.md`。
//
//  MARK: - 回调 → LaunchState 映射
//
//  | slLaunch 回调 / 相位 | 触发时机（桥接层）                        | 本服务投递的状态 |
//  |----------------------|------------------------------------------|-----------------|
//  | （进入 launch）        | 调用 slLaunch 之前                       | `.preparing` |
//  | `phaseHandler("downloading")` | 调用 LaunchFix 之前               | `.downloading(0)` |
//  | `progressHandler(p)`  | LaunchFix 的 onProgress（每文件回调）      | `.downloading(p)`（1% 阈值合并） |
//  | `phaseHandler("launching")` | LaunchFix 完成后、Java 选择之前      | `.resolvingJava` |
//  | `onLauncherReady`     | Java 选择 / 参数适配完成、进程将拉起时     | `.launching` |
//  | `launchSuccess`       | CGWindowList 检测到游戏窗口（或退出码 0）  | `.running` |
//  | `completion`          | 进程退出 / 启动失败                        | `.finished(result)` / `.failed(error)` |
//  | （terminate 被调用）   | 服务侧主动终止                            | `.stopping` |
//
//  源映射不可达 / 不精确之处（合并阶段需修正，详见 LAUNCH_FLOW.md 风险点）：
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
//  | version / gameRoot        | 已使用 | 直接对应 `slLaunch(version:gameDir:)`，gameDir 语义即 `MinecraftDirectory.rootURL` |
//  | offlineUsername           | 已使用 | 直接对应 `slLaunch(username:)`；校验与空值兜底已上移到本服务（`validatedUsername`），桥接层不再重复校验 |
//  | instanceID / runningDirectory | 未使用 | 桥接层自行用 `MinecraftDirectory` + `MinecraftInstance.create` 建实例 |
//  | javaExecutable            | 未使用 | 桥接层自行走 JavaResolverBridge → DataManager → JavaManager 三级选择 |
//  | memoryMB / qualityOfServiceRawValue | 未使用 | 内存与 QoS 取自 `instance.config.maxMemory` / `.qualityOfService`，不经过请求 |
//  | extraJVMArgs / windowSize | 未使用 | 桥接层只做 `--sun-misc-unsafe-memory-access` 过滤，无自定义参数与窗口尺寸入口 |
//  | isDemo / skipResourceCheck | 未使用 | 见 LAUNCH_FLOW.md 风险点 R4（skipResourceCheck 语义歧义） |
//
//  MARK: - 终止路径（重要）
//
//  `GameSessionStore.terminate(sessionID:)` 内部只做 `ManagedProcess.terminate()`，
//  等价于 `Process.terminate()`，**不会**设置 `MinecraftLauncher.isUserTerminated`。
//  而桥接层与 UI 都依赖该标志区分「用户主动关闭」与「异常退出」：
//  缺少该标志时，用户关闭游戏会被判定为异常退出并弹出「Minecraft 异常退出」提示。
//  因此本服务的 `terminate(sessionID:)` 不经会话存储，直接调用 `MinecraftLauncher.terminate()`。
//
//  MARK: - `LaunchEvent` 兼容通道（迁移期，稳定后删除）
//
//  UI 侧（`LaunchCoordinator`）改由本服务发起启动后，仍需「同一时序、同一文案」地收到
//  旧路径 `slLaunch` 的六段回调，否则会引入用户可感知的行为变化。当前不能直接改用
//  `LaunchState` 状态流，原因：
//    - T1：`phaseHandler("launching")` 发生在 Java 选择**之前**，若由 `.resolvingJava`
//      驱动 UI，UI 的「launching」相位会推迟到 `onLauncherReady` 之后，进度条观感变化；
//    - T2：UI 需要在 `onLauncherReady` 时刻拿到 `MinecraftLauncher` 引用（会话绑定与
//      `terminate()` 都依赖它），而 `LaunchState` 不携带该引用；
//    - T8/T9：状态由松散 `Task` 投递且无重放，UI 可能收到乱序或漏掉早期状态。
//  故本服务额外提供一条**与 `slLaunch` 回调调用点逐条对应、同步投递**的事件通道：
//  `LaunchEvent` 只是迁移期的兼容缝，用例层的规范结果仍是 `launch(_:)` 的返回值与抛出值。
//  待 T1/T2/T8/T9 落实（进程创建早于 `onLauncherReady`、状态带引用、store 支持重放）后，
//  本通道与 `logSink` 一并删除，UI 改为订阅 `GameSessionStore.observe(sessionID:)`。
//

import Foundation
import os

/// 启动过程事件：与桥接层 `slLaunch` 的六段回调**逐条对应**，在各自原调用点同步投递。
/// 仅作 UI 迁移期的兼容通道，不是用例层契约（见文件头「LaunchEvent 兼容通道」）。
public enum LaunchEvent {
    /// 文件补全进度（0~1）→ `slLaunch.progressHandler`（不节流，UI 侧自行做「只前进」钳制）
    case progress(Double)
    /// 桥接相位名（`downloading` / `launching`）→ `slLaunch.phaseHandler`
    case phase(String)
    /// 游戏日志行 → `slLaunch.logHandler`
    case log(String)
    /// 启动器引用就绪（此时进程尚未拉起）→ `slLaunch.onLauncherReady`
    case launcherReady(MinecraftLauncher)
    /// 游戏窗口已出现，或进程以退出码 0 结束 → `slLaunch.launchSuccess`
    case running
    /// 进程退出（含退出码）→ `slLaunch.completion` 的 `.success` 分支
    case finished(LaunchResult)
    /// 启动失败（携带桥接层原始错误）→ `slLaunch.completion` 的 `.failure` 分支。
    /// 携带原始 `Error` 而非 `LaunchError`：桥接层文案尚未类型化（见 LAUNCH_FLOW.md 风险点 R5），
    /// 转成 `LaunchError` 会改变 UI 展示文案，迁移期必须保持原文案。
    case failed(Error)
}

/// 启动事件处理闭包。刻意**不加** `@Sendable`：UI 侧实现需要读写其中的会话管理器与
/// launcher 引用（均为非 Sendable 的引用类型），加 `@Sendable` 只会产生大量
/// SendableClosureCaptures 告警而不带来任何隔离收益（投递线程与旧回调一致）。
public typealias LaunchEventHandler = (LaunchEvent) -> Void

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
    /// 迁移期兼容通道（见文件头说明），稳定后与 `logSink` 一并删除
    private let events: LaunchEventHandler?

    /// 会话 ID → launcher 引用，供 terminate 使用
    private let runningState = OSAllocatedUnfairLock<LaunchRunningState>(initialState: .init())

    public init(
        sessionStore: GameSessionStore? = nil,
        logSink: LogSink? = nil,
        events: LaunchEventHandler? = nil
    ) {
        self.sessionStore = sessionStore
        self.logSink = logSink
        self.events = events
    }

    // MARK: - LaunchService

    @discardableResult
    public func launch(_ request: LaunchRequest) async throws -> LaunchResult {
        try await launch(request, cancellation: nil)
    }

    /// 带「准备阶段取消令牌」的启动入口。
    ///
    /// 为什么是重载而不是往 `LaunchRequest` 里加字段：`LaunchRequest` 是 `Equatable` 的值类型
    /// （测试与日志都依赖这一点），而令牌是有状态的引用类型，塞进去会破坏该等价语义。
    /// 也不是改协议：`launch(_:)` 仍是 `LaunchService` 的唯一契约入口，本重载只是适配器
    /// 额外提供的可选能力（令牌为 nil 时行为与旧路径逐条一致）。
    ///
    /// 令牌语义与判定点见 `SLLaunchBridge.swift` 的 `LaunchCancellationToken`。
    @discardableResult
    public func launch(_ request: LaunchRequest, cancellation: LaunchCancellationToken?) async throws -> LaunchResult {
        // 启动前参数预处理：离线用户名校验（原桥接层 slLaunchInternal 首段上移至用例层，判定逐条等价）
        let safeUsername = try Self.validatedUsername(request.offlineUsername)
        let sessionID = UUID()
        let startedAt = Date()
        // 桥接层理论上只回调一次 completion（MinecraftLauncher 内部有一次性门控），
        // 这里再加一道门控，防止 continuation 被重复恢复（重复恢复会直接触发运行时崩溃）
        let gate = LaunchResumeGate()
        let progressRelay = LaunchProgressRelay(store: sessionStore, sessionID: sessionID)
        // 事件通道在逃逸闭包内使用，先取局部快照，避免闭包强引用 self
        let events = self.events

        await sessionStore?.update(.preparing, for: sessionID)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LaunchResult, Error>) in
            slLaunch(
                version: request.version,
                username: safeUsername,
                gameDir: request.gameRoot.path,
                progressHandler: { progress in
                    progressRelay.emit(progress)
                    events?(.progress(progress))
                },
                phaseHandler: { [weak self] phase in
                    self?.handle(phase: phase, sessionID: sessionID)
                    events?(.phase(phase))
                },
                logHandler: { [weak self] line in
                    self?.logSink?(sessionID, line)
                    events?(.log(line))
                },
                launchSuccess: { [weak self] in
                    events?(.running)
                    guard let self else { return }
                    Task { await self.sessionStore?.update(.running, for: sessionID) }
                },
                onLauncherReady: { [weak self] launcher in
                    events?(.launcherReady(launcher))
                    guard let self else { return }
                    self.remember(sessionID: sessionID, launcher: launcher)
                    self.registerSessionWhenProcessStarts(
                        sessionID: sessionID,
                        launcher: launcher,
                        startedAt: startedAt
                    )
                    Task { await self.sessionStore?.update(.launching, for: sessionID) }
                },
                cancellation: cancellation,
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
                            events?(.finished(launchResult))
                            await self?.sessionStore?.update(.finished(launchResult), for: sessionID)
                            self?.forget(sessionID: sessionID)
                            continuation.resume(returning: launchResult)
                        case .failure(let error):
                            // 先投递原始错误（UI 文案以它为准），再把契约要求的类型化错误抛给调用方
                            events?(.failed(error))
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
        // 必须跑在主 actor 上，而不是 `Task.detached`：
        // `launcher.currentProcess` 是主 actor 隔离的可变属性（本工程默认隔离为 MainActor），
        // 写入方在启动线程、而这里原本每 50ms 读一次 —— 属于**跨线程读可变状态**的真数据竞争，
        // 编译器已就此告警（本文件 259:43，Swift 6 语言模式下是错误）。
        // 本任务全程只有 `await Task.sleep` 与一次 await 登记，不占用主线程做重活，
        // 故直接在主 actor 上跑是最小且正确的改法（原先标 detached 并未真正脱离主 actor：
        // 它读的每一个值都是主 actor 隔离的）。
        Task { @MainActor [weak self] in
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
                try? await Task.sleep(for: .milliseconds(50))
            }
            log("[LaunchService] 5s 内未取得进程引用，会话 \(sessionID) 未登记（启动与终止不受影响）")
        }
    }

    // MARK: - 启动前参数预处理

    /// 离线用户名预处理（PCL2 风格）：trim → 空则取 `"Player"` → 校验（非空 / 无英文引号 / ≤16 UTF-16 code unit）。
    ///
    /// 判定与兜底逐条移植自原桥接层 `slLaunchInternal` 首段（该段已在本次改动中删除），
    /// 校验规则仍由唯一的 `validateOfflineUsername` 提供，未新增任何规则。
    /// 已论证的等价性：
    ///  - 判定与兜底：trim / 空值取 `"Player"` / 同一校验函数，且仍在「实例解析之前」执行，失败时机不变；
    ///  - 传给桥接层的玩家名：仍是兜底后的值（桥接层用它构造 `OfflineAccount` 与 `options.playerName`）；
    ///  - UI 可见行为：旧路径下该校验失败经 `completion(nil, .failure)` 回传，launcher 为 nil，
    ///    UI 不产生任何提示；新路径抛出错误、`LaunchCoordinator` 同样不提示（行为一致）。
    /// 唯一差异是错误载体由 `MyLocalizedError` 变为契约要求的 `LaunchError`（LAUNCH_FLOW.md 风险点 R5 的整改方向）。
    static func validatedUsername(_ raw: String) throws -> String {
        var safe = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty { safe = "Player" }
        let reason = validateOfflineUsername(safe)
        guard reason.isEmpty else {
            throw LaunchError.unknown("离线登录参数无效：\(reason)")
        }
        return safe
    }

    // MARK: - 错误映射

    /// 桥接层以 `MyLocalizedError(reason:)` 携带中文文案返回失败，没有类型化错误码，
    /// 故此处按文案前缀做一次映射。**这是临时桥接**：
    /// 文案本地化或改写都会静默退化为 `.unknown`（见 LAUNCH_FLOW.md 风险点 R5）。
    static func mapFailure(_ error: Error, version: String) -> LaunchError {
        // 取消是**预期内的收尾**，不是失败：直接原样透传，避免落进下面的文案前缀匹配，
        // 退化成 `.unknown("启动已取消")`（UI 侧据此判定「不弹错误框」，语义必须保住）。
        if let launchError = error as? LaunchError, launchError == .cancelled {
            return .cancelled
        }

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
