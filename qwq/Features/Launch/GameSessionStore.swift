//
//  GameSessionStore.swift
//  启动用例层：运行中游戏会话的登记、订阅与终止
//
//  与 UI 侧 `LaunchSessionManager`（ObservableObject，持有 `GameSession: ObservableObject`）分工：
//  本类型位于用例层，只认 `sessionID`，不持有 SwiftUI 状态；
//  迁移完成后 LaunchSessionManager 退化为「订阅本 store 的状态流 → 更新 @Published」的适配器。
//

import Foundation
import os

/// 一个已登记的游戏会话
public struct GameSessionRecord: Sendable {
    public let sessionID: UUID
    public let process: ManagedProcess
    public let startedAt: Date

    public init(sessionID: UUID, process: ManagedProcess, startedAt: Date = Date()) {
        self.sessionID = sessionID
        self.process = process
        self.startedAt = startedAt
    }
}

/// 运行中会话的存储与订阅
public protocol GameSessionStore: Sendable {
    /// 登记一个新会话（进程已拉起后调用）
    func register(_ record: GameSessionRecord) async
    /// 推送状态变更，订阅方可通过 `observe` 收到
    func update(_ state: LaunchState, for sessionID: UUID) async
    /// 终止指定会话的进程
    func terminate(sessionID: UUID) async
    /// 订阅指定会话的状态流；流结束时自动清理订阅
    func observe(sessionID: UUID) -> AsyncStream<LaunchState>
}

/// 内存实现：作用域锁保护会话表与订阅表，进程内单例即可满足当前「同时运行数个游戏」的规模。
///
/// **接线状态（2026-10-02）**：生产代码仍无构造点 ——
/// `LaunchCoordinator` 构造 `MinecraftInstanceLaunchService` 时只传了 `events`，
/// `sessionStore` 恒为 nil，于是 `register` / `update` / `observe` / `terminate(sessionID:)`
/// 全部是空转的可选链调用；会话终止实际走 `GameSession.launcher.terminate()`
/// （`LaunchCoordinator.closeSession` / `handlePowerTap`）。
///
/// **为何暂不接线**：`MinecraftInstanceLaunchService.swift:57-70` 记明了四个前置条件
/// T1/T2/T8/T9 —— 其中 T2（UI 需要在 `onLauncherReady` 时刻拿到 `MinecraftLauncher` 引用，
/// 而 `LaunchState` 不携带该引用）未解决前，接上 store 只会让它写进一个**没人订阅**的表，
/// 属纯开销。故本类型当前的状态是**待接线**，不是**待清理**（原 `@available(*, deprecated,
/// "全库无引用，待清理")` 标注已不成立：现有 `qwqTests/GameSessionStoreTests.swift` 覆盖）。
///
/// **本类型承载的三条语义**（接线那天会被 UI 依赖，故已用测试钉住）：
/// 1. 多订阅者：同一会话可被多处 `observe`（基准：`NetDownloaderDownloadEngine` 用数组承载多订阅者）；
/// 2. 终态收口：终态 `finish()` 并清理订阅（协议本文档第 34 行的「流结束时自动清理订阅」）；
/// 3. 回放：晚订阅者拿到最新状态，而不是从空开始（T8/T9 指出的缺口）。
public final class InMemoryGameSessionStore: GameSessionStore, @unchecked Sendable {

    /// 锁保护的可变状态整体（作用域锁定，避免 NSLock 在 async 上下文中的不可用告警）
    private struct State {
        var records: [UUID: GameSessionRecord] = [:]
        /// 外层键 = 会话 ID，内层键 = 订阅 ID。
        /// **必须是集合而不是单个 continuation**：同一会话可被多处 observe
        /// （UI 视图 / 日志窗口 / 自动化），内层用 ID 做键是为了在 `onTermination`
        /// 时能精确摘掉自己那一条。
        var continuations: [UUID: [UUID: AsyncStream<LaunchState>.Continuation]] = [:]
        /// 每个会话的最新状态，供晚订阅者回放（终态也保留，使终态后订阅仍能拿到结果并立即结束）
        var lastStates: [UUID: LaunchState] = [:]
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    public func register(_ record: GameSessionRecord) async {
        lock.withLock { state in
            state.records[record.sessionID] = record
        }
    }

    public func update(_ launchState: LaunchState, for sessionID: UUID) async {
        let (targets, isTerminal) = lock.withLock { locked -> ([AsyncStream<LaunchState>.Continuation], Bool) in
            // 先记最新状态：终态也要留，供终态后订阅回放
            locked.lastStates[sessionID] = launchState
            let targets = Array((locked.continuations[sessionID] ?? [:]).values)
            if launchState.isTerminal {
                // 终态推送后清理会话记录与订阅表，避免无限增长
                locked.records.removeValue(forKey: sessionID)
                locked.continuations[sessionID] = [:]
            }
            return (targets, launchState.isTerminal)
        }
        for continuation in targets { continuation.yield(launchState) }
        // 终态必须 finish：否则 `for await` 永不退出、订阅永不释放。
        // 这是协议自身文档的约定（见上方：流结束时自动清理订阅），不是可选优化。
        if isTerminal {
            for continuation in targets { continuation.finish() }
        }
    }

    public func terminate(sessionID: UUID) async {
        let record = lock.withLock { $0.records[sessionID] }
        record?.process.terminate()
    }

    public func observe(sessionID: UUID) -> AsyncStream<LaunchState> {
        let subscriptionID = UUID()
        let (stream, continuation, replay) = lock.withLock {
            locked -> (AsyncStream<LaunchState>, AsyncStream<LaunchState>.Continuation, LaunchState?) in
            // 无界缓冲：状态事件稀疏（每次状态迁移一条），有界策略反而可能丢掉终态
            var created: AsyncStream<LaunchState>.Continuation!
            let stream = AsyncStream<LaunchState>(bufferingPolicy: .unbounded) { created = $0 }
            created.onTermination = { @Sendable _ in
                // 必须显式丢弃返回值：`removeValue(forKey:)` 返回 `Continuation?`，
                // 而 `onTermination` 的签名是 `(Termination) -> Void`，
                // 隐式返回会让泛型参数 R 在 `Void` 与 `Continuation?` 之间冲突（编译错误）。
                self.lock.withLock { state in
                    _ = state.continuations[sessionID]?.removeValue(forKey: subscriptionID)
                }
            }
            locked.continuations[sessionID, default: [:]][subscriptionID] = created
            return (stream, created, locked.lastStates[sessionID])
        }

        // 在锁外回放：晚订阅者拿到的是**最新**状态，而不是从空开始
        if let replay {
            continuation.yield(replay)
            // 回放的是终态 → 立即收口，避免调用方对着一个永不再产生事件的流挂起
            if replay.isTerminal { continuation.finish() }
        }
        return stream
    }
}
