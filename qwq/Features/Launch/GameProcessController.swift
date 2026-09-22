//
//  GameProcessController.swift
//  启动用例层：游戏进程的拉起与终止
//
//  本文件只定义协议与最小进程封装，**不创建 Process**。
//  进程创建的既有约定（并发上限、超时、白名单）由 `Features/Launch/ProcessPool.swift` 承担：
//  ProcessPool 当前面向「短命令 + 收集输出」场景（同步 execute / executeForData），
//  游戏进程是长驻、输出走日志文件、需要 termination 观察，形态不同，
//  故此处仅声明 `GameProcessController` 协议，未来实现应在 ProcessPool 的并发与超时策略之上扩展，
//  而不是另起一套进程管理（见 README「未来复用 ProcessPool」）。
//

import Foundation

/// 已被拉起的游戏进程的最小封装（持有 Process + termination 观察入口）
public struct ManagedProcess: Sendable {

    public let process: Process

    public init(process: Process) {
        self.process = process
    }

    /// 进程 PID
    public var processIdentifier: Int32 { process.processIdentifier }

    /// 进程是否仍在运行
    public var isRunning: Bool { process.isRunning }

    /// 请求终止（SIGTERM），对应 `MinecraftLauncher.terminate()`
    public func terminate() {
        process.terminate()
    }

    /// 等待进程退出并返回退出码。
    ///
    /// **全库无引用，待清理**（含 `qwqTests`）：唯一实现路径是「会话登记 → 由会话层等待退出」，
    /// 而 `InMemoryGameSessionStore` 未接线（`LaunchCoordinator` 构造服务时不传 `sessionStore`），
    /// 故该方法及其对 `terminationHandler` 的覆写从未执行。
    /// 保留原因：其竞态治理（先挂 handler、再补检状态、一次性门控恰好 resume 一次）是
    /// 「会话层接管进程观察」的正确形态，接线时可直接复用；删除会丢失该结论。
    ///
    /// 竞态窗口（修复前）：实现**先**判断 `process.isRunning`、**后**在续体内挂
    /// `terminationHandler`。若进程恰好在这两步之间退出，Foundation 并不承诺「进程已结束后
    /// 再设置 handler 仍会收到回调」（`terminationHandler` 文档只说系统在任务完成时调用该 block），
    /// 于是 handler 永不触发、continuation 永不 resume——调用方永久挂起，并泄漏续体关联的资源。
    /// `CheckedContinuation` 的契约是**所有执行路径恰好 resume 一次**，不能用「窗口很窄」豁免。
    ///
    /// 消除方式：把顺序倒过来，**先挂 handler、再补检状态**。
    /// - handler 先就位：此后发生的任何一次退出都会被观察到；
    /// - 补检覆盖「handler 就位之前（或与之并发）就已退出」的窗口：此时 handler 不会回调，
    ///   必须在此手动 resume。两者互补，缺一不可；
    /// - 两条路径共用一次性门控 `TerminationResumeGate`：谁先 claim 成功谁负责 resume，
    ///   因此即使 handler 与补检并发发生，也**恰好 resume 一次**（不多不少）。
    @available(*, deprecated, message: "全库无引用，待清理")
    public func waitForTermination() async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let gate = TerminationResumeGate()

            // 第一步：先建立观察，杜绝「挂 handler 之前退出」的丢失窗口。
            process.terminationHandler = { proc in
                guard gate.claim() else { return }
                continuation.resume(returning: proc.terminationStatus)
            }

            // 第二步：补检。进程可能在挂 handler 之前（或与之并发）就已结束，
            // 这种情况下 handler 不会回调，必须在主流程手动恢复续体。
            if !process.isRunning, gate.claim() {
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}

// MARK: - 续体一次性门控

/// 保证 `waitForTermination()` 在任何路径下**恰好 resume 一次**的门控。
///
/// `NSLock` + 布尔标志，锁内只做内存操作，属同步临界区（不跨 `await` 持有）。
/// 显式标 `nonisolated`：该对象要在 `terminationHandler`（由 Foundation 在非主线程回调）
/// 与调用方线程之间共享，必须脱离 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 的默认推断
/// ——仅靠 `@unchecked Sendable` 不足以阻止 MainActor 推断，届时跨线程访问会成片告警
/// （Swift 6 语言模式下为错误）。互斥由锁自身保证。
private nonisolated final class TerminationResumeGate: @unchecked Sendable {
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

/// 游戏进程控制器：把「参数 + 环境」变成可被跟踪的进程
public protocol GameProcessController: Sendable {
    /// - Parameters:
    ///   - executable: Java 可执行文件（`LaunchOptions.javaPath`）
    ///   - arguments: 完整参数（见 `LaunchArgumentBuilder`）
    ///   - environment: 环境变量（`MinecraftLauncher` 当前使用 `ProcessInfo.processInfo.environment`）
    func launch(executable: URL, arguments: [String], environment: [String: String]) async throws -> ManagedProcess
}
