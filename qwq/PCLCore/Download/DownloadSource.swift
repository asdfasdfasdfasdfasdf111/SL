//
//  DownloadSource.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/8/20.
//

import Foundation

public protocol DownloadSource {
    // Minecraft
    func getVersionManifestURL() -> URL
    func getClientManifestURL(_ version: MinecraftVersion) -> URL?
    func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL?
    func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL?
    func getLibraryURL(_ library: ClientManifest.Library) -> URL?
    /// 散列资源文件（assets objects）下载 URL。默认不提供；官方源与镜像源各自实现。
    /// 官方：https://resources.download.minecraft.net/<hash前2位>/<hash>
    /// 镜像：https://bmclapi2.bangbang93.com/assets/<hash前2位>/<hash>（PCL2 同款规则）
    func getAssetURL(hash: String) -> URL?
}

extension DownloadSource {
    public func getAssetURL(hash: String) -> URL? { nil }
}

public class OfficialDownloadSource: DownloadSource {
    public static let shared: OfficialDownloadSource = .init()
    
    public func getVersionManifestURL() -> URL {
        "https://piston-meta.mojang.com/mc/game/version_manifest.json".url
    }
    
    public func getClientManifestURL(_ version: MinecraftVersion) -> URL? {
        // 先查旧安装链路持有的清单；未命中时查下载页「官方 + 未列出」合并清单。
        // 不能 force unwrap：未列出版本只存在于合并清单，两套状态不同步时旧代码会 assertionFailure 崩溃。
        if let urlString = DataManager.shared.versionManifest?.versions.first(where: { $0.id == version.displayName })?.url,
           let url = URL(string: urlString) {
            return url
        }
        return GameVersionManifest.cachedClientManifestURL(for: version.displayName)
    }
    
    public func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        return URL(string: manifest.assetIndex?.url ?? "")
    }
    
    public func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        return try? URL(string: manifest.clientDownload.unwrap().url)
    }
    
    public func getLibraryURL(_ library: ClientManifest.Library) -> URL? {
        return URL(string: library.artifact?.url ?? "")
    }
    
    public func getAssetURL(hash: String) -> URL? {
        guard hash.count >= 2 else { return nil }
        let prefix = String(hash.prefix(2))
        return URL(string: "https://resources.download.minecraft.net/\(prefix)/\(hash)")
    }
}

public class BMCLAPIDownloadSource: DownloadSource {
    public static let shared: BMCLAPIDownloadSource = .init()
    
    public func getVersionManifestURL() -> URL {
        "https://piston-meta.mojang.com/mc/game/version_manifest.json".url
    }
    
    public func getClientManifestURL(_ version: MinecraftVersion) -> URL? {
        return URL(string: "https://bmclapi2.bangbang93.com/version/\(version.displayName)/json")!
    }
    
    public func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        guard let urlString = manifest.assetIndex?.url,
              let url = URL(string: urlString) else {
            return nil
        }
        return URL(string: "https://bmclapi2.bangbang93.com")!.appendingPathComponent(url.path)
    }
    
    public func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        return URL(string: "https://bmclapi2.bangbang93.com/version/\(version.displayName)/client")!
    }
    
    public func getLibraryURL(_ library: ClientManifest.Library) -> URL? {
        return URL(string: "https://bmclapi2.bangbang93.com/maven")!.appendingPathComponent(Util.toPath(mavenCoordinate: library.name))
    }
    
    public func getAssetURL(hash: String) -> URL? {
        guard hash.count >= 2 else { return nil }
        // PCL2 同款规则：resources.download.minecraft.net → bmclapi2.bangbang93.com/assets
        let prefix = String(hash.prefix(2))
        return URL(string: "https://bmclapi2.bangbang93.com/assets/\(prefix)/\(hash)")
    }
}
