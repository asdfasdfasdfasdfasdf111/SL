//
//  DownloadState.swift
//  PCL.Mac
//
//  单个下载任务的状态机。经 `DownloadScheduler.observe` 以 AsyncStream 形式对外发布，
//  取代旧实现中「进度闭包 + 轮询等待完成」的组合。
//

import Foundation

/// 下载任务生命周期状态。
///
/// 合法迁移：
/// idle → preparing → downloading → verifying → merging → completed
/// 任意非终态 → cancelled / failed
public enum DownloadState: Sendable, Equatable {
    case idle
    /// 预检阶段：判断目标文件是否已可用、磁盘空间是否充足。
    case preparing
    case downloading(DownloadProgress)
    case verifying
    case merging
    case completed
    case cancelled
    case failed(DownloadError)

    /// 是否为终态（到达后不再迁移）。
    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            return true
        case .idle, .preparing, .downloading, .verifying, .merging:
            return false
        }
    }

    /// 当前进度快照；非 downloading 状态下为 nil。
    public var progress: DownloadProgress? {
        if case .downloading(let progress) = self { return progress }
        return nil
    }

    /// 失败原因；仅 failed 状态下非 nil。
    public var error: DownloadError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
