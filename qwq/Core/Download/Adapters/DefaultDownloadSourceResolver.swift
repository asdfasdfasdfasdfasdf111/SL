//
//  DefaultDownloadSourceResolver.swift
//  SL启动器
//
//  适配器：把现有 `DownloadSourceManager` 的源选择结果接到 `DownloadSourceResolver` 协议上。
//  约束：不重写源选择算法——「当前主源是谁」「互补源是谁」「是否处于自动切换模式」全部委托
//  `DownloadSourceManager`，本类只负责把已解析的 URL 补齐为有序候选列表。
//

import Foundation

/// 委托现有 `DownloadSourceManager` 的候选源解析器。
///
/// 行为约定（与旧链路对齐）：
/// - 请求主源优先：`DownloadRequest.url` 是调用方按 `DownloadSourceManager` 解析后的结果，
///   因此它始终排在候选列表第一位；
/// - 仅 `AppSettings.fileDownloadSource == .both`（自动切换）时追加互补源；用户手动限定「仅官方」
///   或「仅镜像」时返回单元素列表，不做悄悄跨源兜底（与 `DownloadSourceManager.downloadURLs` 一致）；
/// - 追加哪个互补源由 `DownloadSourceManager.getDownloadSource()` / `alternateSource(of:)` 决定。
///
/// 已知能力缺口（见 MIGRATION.md）：
/// `DownloadRequest` 只携带已解析的 URL，不携带 `(DownloadSource) -> URL` 的 provider。
/// 因此只有「官方域名族 → BMCLAPI」方向可以合成备用 URL；反方向无法从裸 URL 反推官方地址
/// （官方清单/客户端 URL 由 version_manifest 动态给出）。镜像主源场景下候选列表退化为单源。
public struct DefaultDownloadSourceResolver: DownloadSourceResolver {

    /// 官方下载域名族，仅用于识别「这个 URL 来自官方源」，不参与主源判定。
    private static let officialHosts: Set<String> = [
        "piston-meta.mojang.com",
        "launcher.mojang.com",
        "launchermeta.mojang.com",
        "libraries.minecraft.net",
        "resources.download.minecraft.net"
    ]

    public init() {}

    public func candidateURLs(for request: DownloadRequest) async -> [URL] {
        var urls: [URL] = [request.url]

        guard AppSettings.shared.fileDownloadSource == .both else { return urls }
        guard let host = request.url.host, Self.officialHosts.contains(host) else { return urls }

        let manager = DownloadSourceManager.shared
        let backup = manager.alternateSource(of: manager.getDownloadSource())
        guard backup is BMCLAPIDownloadSource else { return urls }

        // 镜像域名取自源对象自身，避免在本文件里硬编码第三方域名。
        guard let mirrorHost = BMCLAPIDownloadSource.shared.getAssetURL(hash: "00")?.host,
              let mirrorURL = Self.replacingHost(of: request.url, with: mirrorHost),
              !urls.contains(mirrorURL) else { return urls }

        urls.append(mirrorURL)
        return urls
    }

    /// 仅替换 host，保留 scheme / path / query / fragment。
    private static func replacingHost(of url: URL, with host: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = host
        return components.url
    }
}
