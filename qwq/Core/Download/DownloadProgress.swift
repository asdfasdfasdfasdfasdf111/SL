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
    /// 已写入的字节数（含历史分片）。总大小未知时为 **0（不伪造字节数）**——
    /// 此时真实进度以单独的比例轨道携带，见 `fraction`。
    public var bytesWritten: Int64
    /// 文件总字节数；未知为 -1（对应旧实现 fileSize == -1 的语义）。
    public var totalBytes: Int64
    /// 实测速度，单位 B/s。
    public var speedBytesPerSecond: Double
    /// 总大小未知时由旧引擎直传的 0…1 比例。已知大小时为 nil，比例由字节推导。
    /// 2026-10-02 引入：替代此前「未知大小用固定假分母 1000 承载比例」的做法——
    /// 旧实现伪造了一对字节数（bytesWritten=clamp×1000, totalBytes=1000），
    /// 让 fraction 能算出来；代价是字节字段对外失真。现在比例走独立轨道，
    /// 字节字段保持诚实（未知即 0/-1），fraction 依旧不退化。
    public var fractionOverride: Double?

    public init(bytesWritten: Int64, totalBytes: Int64, speedBytesPerSecond: Double = 0, fractionOverride: Double? = nil) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.fractionOverride = fractionOverride
    }

    /// 起始快照。
    public static let zero = DownloadProgress(bytesWritten: 0, totalBytes: -1, speedBytesPerSecond: 0)

    /// 完成比例，落在 [0, 1]。已知总大小时由字节推导（真实数据优先）；
    /// 总大小未知时回落到 `fractionOverride`（旧引擎直传的比例）；两者皆无时为 0。
    public var fraction: Double {
        guard totalBytes > 0 else {
            if let fractionOverride {
                return min(1, max(0, fractionOverride))
            }
            return 0
        }
        return min(1, max(0, Double(bytesWritten) / Double(totalBytes)))
    }

    /// 预计剩余时间。总大小未知或速度不可用时为 nil。
    public var estimatedRemaining: TimeInterval? {
        guard totalBytes > 0, speedBytesPerSecond > 0 else { return nil }
        let remaining = max(0, Double(totalBytes - bytesWritten)) / speedBytesPerSecond
        return remaining
    }
}
