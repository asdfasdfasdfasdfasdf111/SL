//
//  DownloadProgress.swift
//  SL启动器
//
//  下载进度快照。由调度器周期性产出，经 `DownloadState.downloading` 向订阅方发布。
//

import Foundation

/// 某一时刻的下载进度快照。
///
/// `fraction` 与 `estimatedRemaining` 由已写字节数派生，
/// 避免调用方各自算一套导致口径不一致。
public struct DownloadProgress: Sendable, Equatable {
    /// 已写入的字节数（含历史分片）。
    public var bytesWritten: Int64
    /// 文件总字节数；未知为 -1（对应旧实现 fileSize == -1 的语义）。
    public var totalBytes: Int64
    /// 实测速度，单位 B/s。
    public var speedBytesPerSecond: Double

    public init(bytesWritten: Int64, totalBytes: Int64, speedBytesPerSecond: Double = 0) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
    }

    /// 起始快照。
    public static let zero = DownloadProgress(bytesWritten: 0, totalBytes: -1, speedBytesPerSecond: 0)

    /// 完成比例，落在 [0, 1]。总大小未知时为 0。
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesWritten) / Double(totalBytes)))
    }

    /// 预计剩余时间。总大小未知或速度不可用时为 nil。
    public var estimatedRemaining: TimeInterval? {
        guard totalBytes > 0, speedBytesPerSecond > 0 else { return nil }
        let remaining = max(0, Double(totalBytes - bytesWritten)) / speedBytesPerSecond
        return remaining
    }
}
