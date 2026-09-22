//
//  DownloadEngine.swift
//  SL启动器
//
//  下载领域的对外唯一入口。UI / 安装层只依赖本文件，
//  不直接接触调度器、分片台账等内部组件。
//

import Foundation

/// 提交下载后拿到的句柄。
public struct DownloadHandle: Sendable, Equatable {
    /// 任务 ID，用于 `observe` 与 `cancel`。
    public let taskID: UUID
    /// 最终落盘路径，便于调用方在完成后直接读文件。
    public let destination: URL

    public init(taskID: UUID, destination: URL) {
        self.taskID = taskID
        self.destination = destination
    }
}

/// 下载引擎：对外暴露的能力只有「提交、观测、取消」三件事。
public protocol DownloadEngine: Sendable {
    /// 提交一个下载请求。校验参数不合法时直接抛错；
    /// 下载过程中的失败通过 `observe` 的 `.failed` 状态给出。
    func submit(_ request: DownloadRequest) async throws -> DownloadHandle

    /// 订阅任务状态流，流在任务到达终态后结束。
    func observe(taskID: UUID) -> AsyncStream<DownloadState>

    /// 取消任务并清理临时文件。
    func cancel(taskID: UUID) async
}
