//
//  DownloadError.swift
//  PCL.Mac
//
//  下载领域的统一错误类型。旧实现中 `NetDownloadError`、`MyLocalizedError`、
//  字符串 failReason 三种错误载体在此收敛为一个枚举，便于调用方穷尽处理。
//

import Foundation

public enum DownloadError: LocalizedError, Sendable, Equatable {
    /// 所有候选源均不可用。
    case sourceUnavailable
    /// 服务器返回了非 2xx 状态码。
    case httpStatus(Int)
    /// 源忽略 Range 请求（返回 200 全量），无法分片/续传。
    case rangeNotSupported
    /// 大小或哈希校验不通过。
    case checksumMismatch
    /// 磁盘空间不足。
    case diskFull
    /// 被主动取消。
    case cancelled
    /// 连接或分片传输超时。
    case timeout
    /// 其它未归类错误，携带原始描述。
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "无可用下载源。"
        case .httpStatus(let code):
            return "远程服务器返回了 \(code)。"
        case .rangeNotSupported:
            return "下载源不支持断点续传。"
        case .checksumMismatch:
            return "文件校验失败，下载内容不完整。"
        case .diskFull:
            return "磁盘空间不足。"
        case .cancelled:
            return "下载已取消。"
        case .timeout:
            return "下载超时。"
        case .unknown(let reason):
            return reason
        }
    }
}
