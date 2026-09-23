//
//  DownloadSource.swift
//  SL启动器
//
//  下载源抽象：把「某个资源该从哪个域名取」收拢成一组 URL 工厂方法。
//
//  两种实现：
//  - `OfficialDownloadSource` —— 全部走官方域名（piston-meta / resources.download.minecraft.net）；
//  - `BMCLAPIDownloadSource` —— 走 BMCLAPI 国内镜像，解决官方域名在国内不可达/极慢的问题。
//  当前生效的是哪一个由 `DownloadSourceManager` 统一持有（见 DownloadSourceManager.swift）。
//
//  这些方法一律**只算 URL、不发请求**，因此可以随意调用、便于测试；
//  返回值多为可选：清单里缺字段时应返回 nil，让上层报「清单不完整」而不是拼出一个坏 URL。
//
//  Created by YiZhiMCQiu on 2025/8/20.
//

import Foundation

/// 下载源协议。实现方只需回答「某个资源对应的 URL 是什么」，
/// 不负责重试、镜像回退等策略 —— 那些由 NetManager / NetFilePreflight 负责。
public protocol DownloadSource {
    // Minecraft
    /// 版本清单（version_manifest.json）的地址。
    /// 这是唯一不返回可选值的方法：清单地址不存在「缺失」这种状态。
    /// ⚠️ 注意两个实现返回的是**同一个地址**，见下方各自的类注释。
    func getVersionManifestURL() -> URL
    func getClientManifestURL(_ version: MinecraftVersion) -> URL?
    func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL?
    func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL?
    func getLibraryURL(_ library: ClientManifest.Library) -> URL?
    /// 散列资源文件（assets objects）下载 URL。默认不提供；官方源与镜像源各自实现。
    /// 官方：https://resources.download.minecraft.net/<hash前2位>/<hash>
    /// 镜像：https://bmclapi2.bangbang93.com/assets/<hash前2位>/<hash>（与上游 PCL2 一致的规则）
    func getAssetURL(hash: String) -> URL?
}

/// 默认实现：不提供散列资源（assets objects）地址。
/// 只有真具备该能力的源才覆写它 —— 「不支持」于是表现为返回 nil，
/// 而不必让每个实现都写一遍空实现。
extension DownloadSource {
    public func getAssetURL(hash: String) -> URL? { nil }
}

/// 官方源：全部指向 Mojang / Microsoft 域名。国内直连通常很慢甚至不通。
///
/// ⚠️ 即便走官方源，客户端清单也可能**不是**由 `getClientManifestURL` 得到的：
/// 该方法会优先复用 `DataManager` 里已加载清单中的 url（含「未列出」版本），
/// 只有查不到时才回落到下载页的合并清单。
public class OfficialDownloadSource: DownloadSource {
    public static let shared: OfficialDownloadSource = .init()
    
    public func getVersionManifestURL() -> URL {
        "https://piston-meta.mojang.com/mc/game/version_manifest.json".url!
    }
    
    /// 客户端清单 URL：先查已加载清单，未命中再回落到「官方 + 未列出」合并清单。
    public func getClientManifestURL(_ version: MinecraftVersion) -> URL? {
        // 先查旧安装链路持有的清单；未命中时查下载页「官方 + 未列出」合并清单。
        // 不能 force unwrap：未列出版本只存在于合并清单，两套状态不同步时旧代码会 assertionFailure 崩溃。
        if let urlString = DataManager.shared.versionManifest?.versions.first(where: { $0.id == version.displayName })?.url,
           let url = URL(string: urlString) {
            return url
        }
        return GameVersionManifest.cachedClientManifestURL(for: version.displayName)
    }
    
    /// 资源索引 URL：直接取清单里写好的地址（清单已给出绝对 URL）。
    /// ⚠️ 与镜像源不同，这里**不对字段做显式判空**：`assetIndex` 缺失时是用空串去构造
    /// URL，而 `URL(string:)` 对空串的行为随 Foundation 版本而变 —— 调用方仍需自己判一次 nil。
    public func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        return URL(string: manifest.assetIndex?.url ?? "")
    }
    
    /// 客户端 jar URL：同样直接取清单里写好的地址。
    /// `unwrap()` 在字段为 nil 时抛错，被 `try?` 兜成 nil ——
    /// 即「清单没写客户端下载地址」时返回 nil，而不是崩溃。
    public func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        return try? URL(string: manifest.clientDownload.unwrap().url)
    }
    
    /// 依赖库 URL：取清单里记录的地址。注意这意味着**清单里写什么就用什么** ——
    /// 第三方仓库（非 libraries.minecraft.net）的地址会被原样使用，官方源不做事后改写。
    public func getLibraryURL(_ library: ClientManifest.Library) -> URL? {
        return URL(string: library.artifact?.url ?? "")
    }
    
    /// 散列资源 URL：官方规则是 `<hash前两位>/<hash>` 两级目录。
    /// hash 短于 2 位时无从分桶，返回 nil（正常 hash 都是 40/64 位，此处纯属防御）。
    public func getAssetURL(hash: String) -> URL? {
        guard hash.count >= 2 else { return nil }
        let prefix = String(hash.prefix(2))
        return URL(string: "https://resources.download.minecraft.net/\(prefix)/\(hash)")
    }
}

/// BMCLAPI 国内镜像源（bmclapi2.bangbang93.com）。
///
/// 与官方源的实质差别在于**库与资源走镜像域名**：
/// - 清单 / 客户端 jar / 依赖库 / 散列资源都改写成镜像地址；
/// - 依赖库**不看清单里记录的 url，而是按 maven 坐标重新拼路径**，
///   因此内置仓库地址的第三方库也会被一并镜像。
///
/// ⚠️ 但 `getVersionManifestURL()` 返回的**仍然是官方 piston-meta 地址**：
/// 即切到镜像源后，版本清单这一步依旧直连官方域名。清单本身很小，
/// 但若官方域名在国内不可达，镜像模式下依然拿不到版本列表。
public class BMCLAPIDownloadSource: DownloadSource {
    public static let shared: BMCLAPIDownloadSource = .init()
    
    public func getVersionManifestURL() -> URL {
        "https://piston-meta.mojang.com/mc/game/version_manifest.json".url!
    }
    
    public func getClientManifestURL(_ version: MinecraftVersion) -> URL? {
        return URL(string: "https://bmclapi2.bangbang93.com/version/\(version.displayName)/json")
    }
    
    public func getAssetIndexURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        guard let urlString = manifest.assetIndex?.url,
              let url = URL(string: urlString) else {
            return nil
        }
        return URL(string: "https://bmclapi2.bangbang93.com")!.appendingPathComponent(url.path)
    }
    
    public func getClientJARURL(_ version: MinecraftVersion, _ manifest: ClientManifest) -> URL? {
        return URL(string: "https://bmclapi2.bangbang93.com/version/\(version.displayName)/client")
    }
    
    public func getLibraryURL(_ library: ClientManifest.Library) -> URL? {
        return URL(string: "https://bmclapi2.bangbang93.com/maven")!.appendingPathComponent(Util.toPath(mavenCoordinate: library.name))
    }
    
    public func getAssetURL(hash: String) -> URL? {
        guard hash.count >= 2 else { return nil }
        // 与上游 PCL2 一致的规则：resources.download.minecraft.net → bmclapi2.bangbang93.com/assets
        let prefix = String(hash.prefix(2))
        return URL(string: "https://bmclapi2.bangbang93.com/assets/\(prefix)/\(hash)")
    }
}
