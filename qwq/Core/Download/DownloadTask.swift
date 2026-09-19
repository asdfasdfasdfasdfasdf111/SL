//
//  DownloadTask.swift
//  PCL.Mac
//
//  下载任务的持久化视图（请求 + 当前状态）与状态存储协议。
//  旧实现把状态散落在 `NetManager.FileRecord` 私有类里，无法被外部观测；
//  这里把它显式化为可查询、可替换的存储接口。
//

import Foundation

/// 一个下载任务的当前视图。
public struct DownloadTask: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var request: DownloadRequest
    public var state: DownloadState
    public let createdAt: Date

    public init(id: UUID = UUID(), request: DownloadRequest, state: DownloadState = .idle, createdAt: Date = Date()) {
        self.id = id
        self.request = request
        self.state = state
        self.createdAt = createdAt
    }
}

/// 任务状态存储。
///
/// 只定义「发布状态所需的最小接口」：写入、读取、改状态、移除。
/// 实现侧可以是 actor 内存字典，也可以是落盘/跨进程存储，调用方无需感知。
public protocol DownloadTaskStore: Sendable {
    /// 插入或更新一条任务记录。
    func upsert(_ task: DownloadTask) async
    /// 读取指定任务；不存在返回 nil。
    func task(id: UUID) async -> DownloadTask?
    /// 仅更新状态字段。
    func setState(_ state: DownloadState, for id: UUID) async
    /// 移除任务记录。
    func remove(id: UUID) async
    /// 全部任务快照（调试与批量展示用）。
    func allTasks() async -> [DownloadTask]
}
