//
//  DownloadScheduler.swift
//  SL启动器
//
//  调度器职责：并发额度分配、分片切分、失败重试、源切换、进度发布。
//  旧实现中这些都写在 `NetManager` 这一个 actor 内（889 行），
//  此处只定义边界，实现留给后续迁移。
//

import Foundation

/// 下载调度器：决定「谁在什么时候用多少连接下载哪一段」。
///
/// 不负责：源列表解析（`DownloadSourceResolver`）、
/// 分片拼接（`DownloadMerger`）、结果校验（`DownloadVerifier`）。
public protocol DownloadScheduler: Sendable {
    /// 提交一个下载请求，返回任务 ID。
    /// 提交成功不代表下载成功，终态由 `observe` 的流给出。
    @discardableResult
    func submit(_ request: DownloadRequest) async throws -> UUID

    /// 取消任务并清理其临时文件。对已终态的任务是空操作。
    func cancel(taskID: UUID) async

    /// 订阅任务状态流。流在任务到达终态后结束。
    func observe(taskID: UUID) -> AsyncStream<DownloadState>
}
