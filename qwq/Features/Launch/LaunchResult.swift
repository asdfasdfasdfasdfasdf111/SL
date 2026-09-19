//
//  LaunchResult.swift
//  启动用例层：一次启动的最终结果
//
//  字段来源：
//  - exitCode   ← MinecraftLauncher.launch 回调的 Int32 退出码
//  - sessionID  ← 本次启动建立的会话标识（对应 GameSessionStore 注册的会话）
//  - logURL     ← MinecraftLauncher.logURL（退出码 0 时现有实现会删除该文件，故为可选）
//  - duration   ← 从 launch 到进程退出的挂钟时长
//

import Foundation

/// 一次启动的完成结果
public struct LaunchResult: Sendable, Equatable {
    /// 进程退出码。0 表示正常退出；非 0 需结合日志排查。
    public let exitCode: Int
    /// 本次启动的会话标识，用于日志订阅与进程终止。
    public let sessionID: UUID
    /// 日志文件位置（可能被现有实现在成功退出后清理）。
    public let logURL: URL?
    /// 从启动到进程退出的时长（秒）。
    public let duration: TimeInterval

    public init(exitCode: Int, sessionID: UUID, logURL: URL? = nil, duration: TimeInterval = 0) {
        self.exitCode = exitCode
        self.sessionID = sessionID
        self.logURL = logURL
        self.duration = duration
    }

    /// 是否为用户主动终止以外的异常退出
    public var isAbnormalExit: Bool { exitCode != 0 }
}
