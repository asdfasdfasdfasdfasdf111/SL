//
//  MinecraftVersionInfo.swift
//  Game 模块：游戏版本只读快照模型
//
//  字段全部取自工程内既有类型的真实属性，不做推测填充：
//
//  | 本模型字段   | 真实来源                                                                       |
//  | ------------ | ------------------------------------------------------------------------------ |
//  | `id`         | `MinecraftVersion.displayName`（PCLCore/Minecraft/MinecraftVersion.swift:11）   |
//  |              | 与 Mojang 清单条目的 `"id"`（GameVersionManifest 合并清单的取值键）同一语义     |
//  | `type`       | 清单条目 `"type"` 原文；与 `VersionType`（同名文件 :49）的 rawValue 取值一致     |
//  | `releaseTime`| 清单条目 `"releaseTime"` 原文（ISO8601 字符串，按字符串比较即得时间先后）        |
//  | `manifestURL`| 清单条目 `"url"`（该版本的客户端清单地址）                                       |
//  | `client`     | `ClientManifest`（PCLCore/Minecraft/ClientManifest.swift:11）公开属性快照        |
//
//  版本类型不另建枚举，直接复用既有 `MinecraftVersionKind`
//  （Core/Minecraft/Module/MinecraftInstanceInfo.swift:68，镜像 `VersionType`）。
//
//  为什么保存 `"type"` 原文而不是只存枚举：既有 `GameVersionHelper.isAprilFoolVersion(id:type:)`
//  按清单 type 原文判定，保存原文可保证与既有过滤规则逐字一致（见 `VersionFilterUseCase`）。
//

import Foundation

// MARK: - 客户端清单快照

/// `ClientManifest` 的只读快照。
///
/// 只收录 `ClientManifest` 的公开属性中与「下载入口」相关的部分；
/// 每个字段都存在对应属性，缺失时保持 nil，不用默认值顶替。
struct ClientManifestSnapshot: Sendable, Hashable {

    /// `ClientManifest.id`
    let id: String

    /// `ClientManifest.mainClass`
    let mainClass: String

    /// `ClientManifest.type`
    let type: String

    /// `ClientManifest.javaVersion`（JSON `javaVersion.majorVersion`，可缺省）
    let javaVersion: Int?

    /// `ClientManifest.assetIndex?.id`（无 assetIndex 节点时为 nil）
    let assetIndexID: String?

    /// `ClientManifest.clientDownload?.url`（无 downloads.client 节点时为 nil）
    let clientDownloadURL: String?

    init(_ manifest: ClientManifest) {
        self.id = manifest.id
        self.mainClass = manifest.mainClass
        self.type = manifest.type
        self.javaVersion = manifest.javaVersion
        self.assetIndexID = manifest.assetIndex?.id
        self.clientDownloadURL = manifest.clientDownload?.url
    }
}

// MARK: - 版本快照

/// 一个游戏版本的只读快照。
struct MinecraftVersionInfo: Identifiable, Sendable, Hashable {

    /// 版本号：`MinecraftVersion.displayName` / 清单条目 `"id"`
    let id: String

    /// 清单条目 `"type"` 原文（保留原文以对齐既有愚人节版本判定）
    let type: String

    /// 清单条目 `"releaseTime"` 原文；从 `MinecraftVersion` 构造且未取到时间时为空串
    let releaseTime: String

    /// 清单条目 `"url"`：该版本的客户端清单地址
    let manifestURL: URL?

    /// 客户端清单快照；未解析客户端清单时为 nil
    let client: ClientManifestSnapshot?

    /// 归一化版本类型；清单 type 未识别时为 nil。
    ///
    /// 这里用枚举的 `rawValue` 可失败构造而非 `MinecraftVersionKind(rawVersionType:)`：
    /// 后者的回落值是 `.release`，会把未识别 type 误判为正式版，
    /// 与既有 `GameVersionFilter`（未识别 type 不匹配任何分类）行为不符。
    var kind: MinecraftVersionKind? {
        MinecraftVersionKind(rawValue: type)
    }

    /// 是否愚人节版本。委托既有 `GameVersionHelper`，不重复实现命名规则。
    var isAprilFool: Bool {
        GameVersionHelper.isAprilFoolVersion(id: id, type: type)
    }

    /// 从合并清单条目构造。
    ///
    /// 与既有 `GameVersionFilter.filteredIDs` 的取字段方式一致：
    /// `id` 缺失或为空时该条目不成立（既有实现用 `compactMap` 丢弃），
    /// `type` 缺失时退化为 `"unknown"`（同样不落入任何分类），其余字段缺失时为空串 / nil。
    init?(manifestEntry entry: [String: Any]) {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.type = entry["type"] as? String ?? "unknown"
        self.releaseTime = entry["releaseTime"] as? String ?? ""
        self.manifestURL = (entry["url"] as? String).flatMap(URL.init(string:))
        self.client = nil
    }

    /// 从 `MinecraftVersion` 构造。
    ///
    /// 只取 `displayName` 与 `type`：`MinecraftVersion.releaseDate` 是懒加载属性，
    /// 首次读取会触发 `VersionManifest.getReleaseDate(_:)`（依赖 DataManager 清单装载时机），
    /// 本模型不主动触发该查询，故 `releaseTime` 留空、`manifestURL` 为 nil。
    init(version: MinecraftVersion) {
        self.id = version.displayName
        self.type = version.type.rawValue
        self.releaseTime = ""
        self.manifestURL = nil
        self.client = nil
    }

    /// 附加客户端清单快照，返回新快照（本模型不可变）。
    func attaching(client: ClientManifestSnapshot) -> MinecraftVersionInfo {
        MinecraftVersionInfo(id: id, type: type, releaseTime: releaseTime,
                             manifestURL: manifestURL, client: client)
    }

    private init(id: String, type: String, releaseTime: String,
                 manifestURL: URL?, client: ClientManifestSnapshot?) {
        self.id = id
        self.type = type
        self.releaseTime = releaseTime
        self.manifestURL = manifestURL
        self.client = client
    }
}
