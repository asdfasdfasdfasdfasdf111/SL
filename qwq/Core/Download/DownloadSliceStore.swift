//
//  DownloadSliceStore.swift
//  PCL.Mac
//
//  分片（Range 片段）的记录与清理。旧实现中分片是 `NetManager.Slice` 私有类，
//  状态只存在于 actor 内存中，既不可观测也无法单测；这里把分片本身与
//  分片台账拆开：分片是纯数据，台账是协议。
//

import Foundation

/// 分片执行状态。
public enum DownloadSliceState: String, Sendable, Equatable {
    /// 已登记，尚未开始传输。
    case pending
    /// 传输中。
    case downloading
    /// 已完成，临时文件数据完整。
    case completed
    /// 失败，保留已下数据供续传。
    case failed
}

/// 一个分片：文件区间 [offset, offset + length) 与其临时文件。
public struct DownloadSlice: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// 在目标文件中的起始字节偏移。
    public var offset: Int64
    /// 分片长度；小于 0 表示「到文件末尾」（长度未知）。
    public var length: Int64
    /// 该分片数据的临时文件路径。
    public var tempFileURL: URL
    /// 执行状态。
    public var state: DownloadSliceState
    /// 已写入临时文件的字节数，用于断点续传。
    public var bytesWritten: Int64

    public init(
        id: UUID = UUID(),
        offset: Int64,
        length: Int64,
        tempFileURL: URL,
        state: DownloadSliceState = .pending,
        bytesWritten: Int64 = 0
    ) {
        self.id = id
        self.offset = offset
        self.length = length
        self.tempFileURL = tempFileURL
        self.state = state
        self.bytesWritten = bytesWritten
    }

    /// 该分片尚未下载的字节数；长度未知时返回 -1。
    public var undone: Int64 {
        guard length >= 0 else { return -1 }
        return max(0, length - bytesWritten)
    }
}

/// 分片台账：记录、查询、清理某个任务的全部分片。
public protocol DownloadSliceStore: Sendable {
    /// 为任务登记一个新分片。
    func register(_ slice: DownloadSlice, for taskID: UUID) async
    /// 更新已有分片（以 id 匹配）。
    func update(_ slice: DownloadSlice) async
    /// 任务的全部分片，按 offset 升序。
    func slices(for taskID: UUID) async -> [DownloadSlice]
    /// 任务中已完成的分片，按 offset 升序；供 `DownloadMerger` 消费。
    func completedSlices(for taskID: UUID) async -> [DownloadSlice]
    /// 删除任务的全部分片临时文件并清空记录（取消/失败后的清理）。
    func cleanup(taskID: UUID) async
}
