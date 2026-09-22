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
/// 全库无引用，待清理（含 `qwqTests`）：全库没有任何 `InMemoryGameSessionStore()` 构造点——
/// 生产接线（`LaunchCoordinator` 构造 `MinecraftInstanceLaunchService` 时）只传了 `events`，
/// `sessionStore` 恒为 nil，于是 `register` / `update` / `observe` / `terminate(sessionID:)`
/// 全部是空转的可选链调用；会话终止实际走 `GameSession.launcher.terminate()`
/// （`LaunchCoordinator.closeSession` / `handlePowerTap`）。
/// 保留原因：接口形状（sessionID 维度、AsyncStream 订阅）是「UI 退化为订阅者」的目标形态。
@available(*, deprecated, message: "全库无引用，待清理")
public final class InMemoryGameSessionStore: GameSessionStore, @unchecked Sendable {

    /// 锁保护的可变状态整体（作用域锁定，避免 NSLock 在 async 上下文中的不可用告警）
    private struct State {
        var records: [UUID: GameSessionRecord] = [:]
        var continuations: [UUID: AsyncStream<LaunchState>.Continuation] = [:]
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    public func register(_ record: GameSessionRecord) async {
        lock.withLock { state in
            state.records[record.sessionID] = record
        }
    }

    public func update(_ launchState: LaunchState, for sessionID: UUID) async {
        let continuation = lock.withLock { locked -> AsyncStream<LaunchState>.Continuation? in
            // 终态推送后清理会话记录，避免无限增长
            if launchState.isTerminal { locked.records.removeValue(forKey: sessionID) }
            return locked.continuations[sessionID]
        }
        continuation?.yield(launchState)
    }

    public func terminate(sessionID: UUID) async {
        let record = lock.withLock { $0.records[sessionID] }
        record?.process.terminate()
    }

    public func observe(sessionID: UUID) -> AsyncStream<LaunchState> {
        AsyncStream { continuation in
            lock.withLock { $0.continuations[sessionID] = continuation }
            continuation.onTermination = { @Sendable _ in
                self.lock.withLock { _ = $0.continuations.removeValue(forKey: sessionID) }
            }
        }
    }
}
