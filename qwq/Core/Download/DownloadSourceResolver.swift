//
//  DownloadSourceResolver.swift
//  PCL.Mac
//
//  候选下载源的解析。旧实现在 `NetManager.pickSource` 里按下标遍历
//  `PCLNetFile.urls` 并维护源黑名单，源选择与调度耦合在一起；
//  这里把「给出有序候选列表」独立成协议，黑名单/测速留给具体实现。
//

import Foundation

/// 为一次请求解析出有序候选 URL 列表。
///
/// 返回顺序即尝试顺序（主源在前）。空数组表示无可用源，
/// 调用方应转换为 `DownloadError.sourceUnavailable`。
public protocol DownloadSourceResolver: Sendable {
    func candidateURLs(for request: DownloadRequest) async -> [URL]
}

extension DownloadSourceResolver {
    /// 默认实现：不做任何解析，仅返回请求自带的主源。
    public func candidateURLs(for request: DownloadRequest) async -> [URL] {
        [request.url]
    }
}

/// 顺序候选解析器：以请求主源开头，按给定顺序追加备用源并去重。
///
/// 不做测速、不维护黑名单，适用于源顺序固定的场景（如「官方 + 镜像」）。
public struct SequentialDownloadSourceResolver: DownloadSourceResolver {
    private let fallbacks: [URL]

    /// - Parameter fallbacks: 备用源，按尝试顺序排列。
    public init(fallbacks: [URL] = []) {
        self.fallbacks = fallbacks
    }

    public func candidateURLs(for request: DownloadRequest) async -> [URL] {
        var result: [URL] = [request.url]
        for url in fallbacks where !result.contains(url) {
            result.append(url)
        }
        return result
    }
}
