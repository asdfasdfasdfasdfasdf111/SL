//
//  LaunchBridgeSupport.swift
//  启动桥接层（SLLaunchBridge.slLaunchInternal）的跨线程辅助类型。
//  2026-10-03 自 SLLaunchBridge.swift 拆出（纯物理搬移，逻辑零变更）。
//

import Foundation

/// 跨线程传递启动前补全的错误结果（后台线程用信号量同步等待 Task 完成）
final class FixResultBox {
    var error: Error?
}

/// 「启动前补全」等待的三种收尾方式。原先只有二元判定（超时 / 未超时），
/// 加入取消后需要区分：取消要立刻返回且**不报错**（用户主动取消不是失败）。
enum FixWaitOutcome {
    /// 补全 Task 已 signal（成功或失败，错误由 `FixResultBox` 携带）
    case finished
    /// 等待期间用户点击取消 → 立刻中止（不等补全跑完）
    case cancelled
    /// 600s 上限耗尽
    case timedOut
}

/// 跨线程共享的一次性「已放弃」标志。
///
/// 用途：`slLaunchInternal` 在补全超时后置位，补全 Task 的进度回调据此**停止向 UI 投递**；
/// 回调可能在主线程（`MultiFileDownloader` 经 `MainActor.run` 回调）而置位发生在等待线程，
/// 故用锁保护（锁内只做内存读写，不回调外部、不跨 await 持有）。
/// 显式 `nonisolated`：需脱离 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 的默认推断
/// （仅靠 `@unchecked Sendable` 不足以阻止 MainActor 推断），锁内只做内存读写，不回调
/// 外部、不跨 await 持有。与同形态的原子门控做法一致（原参照物
/// `LaunchCoordinator.TerminationResumeGate` 已随 2026-10-02 死代码清理删除）。
nonisolated final class AbandonFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        abandoned = true
    }
}