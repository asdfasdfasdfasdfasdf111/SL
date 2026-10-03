//
//  LaunchCancellationToken.swift
//  一次启动「准备阶段」的取消令牌。
//  2026-10-03 自 SLLaunchBridge.swift 拆出（纯物理搬移，逻辑零变更）。
//

import Foundation

/// 一次启动「准备阶段」的取消令牌。
///
/// **为什么需要它**：`GameSession.launcher.terminate()` 只能终止**已经起来**的进程。而从点「启动」
/// 到进程真正 `run()` 之间，还要走「启动前补全」（内部 600s 超时，可能下载数百 MB）与 Java 选择，
/// 这段时间里**根本还没有 launcher 对象可供终止**。于是用户在这段时间点取消，原先只是复位界面，
/// 后台准备链完全感知不到，会一路跑完并把游戏拉起来 —— **点了取消，几十秒后游戏自己弹出来**。
///
/// **与 `isUserTerminated` 的分工**：后者语义是「进程已经起了、用户要终止它」；本令牌语义是
/// 「进程还没起、别再起了」。两者不能互相替代，因为准备阶段取不到 launcher。
///
/// **消费方**：`slLaunchInternal` 在五个判定点读它（函数入口 / 补全前 / 补全等待期间 200ms 分片轮询 /
/// Java 选择前 / 拉起进程前），任何一个命中都以 `LaunchError.cancelled` 收口，
/// 且**不会再把游戏拉起来**。令牌由 `LaunchCoordinator.start` 每次启动新建一个，
/// 挂在 `LaunchSessionManager` 上供电源按钮取消。
///
/// 显式 `nonisolated`：创建在主线程，读取在准备链的后台线程，必须脱离默认的 MainActor 推断
/// （与 `LaunchFailureNoticeGate` 的治理方式一致）。锁内只做内存操作，不跨 `await` 持有。
public nonisolated final class LaunchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    /// 置位取消。可重复调用（重复取消无副作用）。
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// 是否已被取消。准备链在每个**不可逆动作**之前读一次。
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}