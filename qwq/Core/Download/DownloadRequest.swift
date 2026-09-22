//
//  DownloadRequest.swift
//  SL启动器
//
//  下载领域模型：一次「单文件下载」的完整输入描述。
//  只包含数据，不含任何网络/磁盘行为，便于单元测试直接构造。
//

import Foundation

/// 下载优先级。调度器在分配全局分片额度时按此排序，数值越大越先获得额度。
public enum DownloadPriority: Int, Sendable, Comparable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2

    public static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 一次下载请求的不可变输入。
///
/// 与旧 `SLNetFile` 的区别：请求不再持有 `FileChecker` 与 `ReplaceMethod`
/// （覆盖策略属于调用方策略，校验属于 `DownloadVerifier` 职责），
/// 请求本身因此可跨 actor 自由传递。
public struct DownloadRequest: Sendable, Equatable {
    /// 主源地址。候选镜像由 `DownloadSourceResolver` 另行给出。
    public var url: URL
    /// 最终落盘路径（非临时分片路径）。
    public var destinationURL: URL
    /// 期望字节数；为 nil 表示不校验大小。
    public var expectedSize: Int64?
    /// 期望 SHA-1（小写十六进制）；为 nil 表示不校验。
    public var sha1: String?
    /// 期望 SHA-256（小写十六进制）；为 nil 表示不校验。
    public var sha256: String?
    /// 附加请求头（User-Agent、Accept-Encoding 等）。
    public var headers: [String: String]
    /// 该源是否支持断点续传（Range）。false 时调度器只准单线程直下。
    public var supportsRange: Bool
    /// 调度优先级。
    public var priority: DownloadPriority

    public init(
        url: URL,
        destinationURL: URL,
        expectedSize: Int64? = nil,
        sha1: String? = nil,
        sha256: String? = nil,
        headers: [String: String] = [:],
        supportsRange: Bool = true,
        priority: DownloadPriority = .normal
    ) {
        self.url = url
        self.destinationURL = destinationURL
        self.expectedSize = expectedSize
        self.sha1 = sha1
        self.sha256 = sha256
        self.headers = headers
        self.supportsRange = supportsRange
        self.priority = priority
    }

    /// 是否携带任一哈希校验要求。
    public var hasChecksum: Bool {
        (sha1?.isEmpty == false) || (sha256?.isEmpty == false)
    }
}
