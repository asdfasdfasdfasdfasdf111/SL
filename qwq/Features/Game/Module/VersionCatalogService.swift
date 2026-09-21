//
//  VersionCatalogService.swift
//  Game 模块：游戏版本清单服务协议与默认实现
//
//  设计约定（与 `ModBrowserService` / `JavaRepository` 一致）：
//  - 协议为 `Sendable`，实现必须是值类型或无状态引用类型，可跨并发域传递；
//  - 默认实现是既有代码的**适配器**，不二次实现拉取、缓存与回退逻辑——
//    主源/镜像并发、三级缓存、未列出版本合并全部仍由 `GameVersionManifest` 承担。
//
//  依据条目：TSPL《Concurrency》「Sendable Types」——标注 `Sendable` 的协议要求所有遵循类型
//  都是 sendable 类型（值类型或不可变引用类型等）；`struct` + 无实例存储属性满足该要求。
//  官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
//
//  依据条目：TSPL《Protocols》——协议要求默认是 non-isolated，同步要求不得由
//  `@MainActor` 隔离的方法实现；本协议的全部要求均为同步方法或 `async` 方法，
//  实现类型不标注任何全局 actor，故在两种编译口径下均满足约束。
//  官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/
//

import Foundation

// MARK: - 服务协议

/// 游戏版本清单的唯一取数入口。
///
/// 上层（分类页、详情页）不再直接调用 `GameVersionManifest`，统一经此协议取版本快照。
protocol VersionCatalogService: Sendable {

    /// 读取可立即展示的版本快照：内存缓存命中优先，其次磁盘缓存。
    ///
    /// 无任何可用缓存时返回 nil（**不是**空数组），调用方据此区分「未就绪」与「已就绪但为空」，
    /// 与既有 `GameVersionManifest.cachedMerged()` 的语义一致。
    func cachedVersions() -> [MinecraftVersionInfo]?

    /// 拉取合并后的版本清单（官方主源失败自动回退 BMCLAPI 镜像 + 未列出版本增量合并）。
    ///
    /// 不抛错：网络全部失败且无缓存时返回空数组，与既有 `fetchMerged` 语义一致，
    /// 调用方不得把空数组当作错误处理。
    func fetchVersions(forceRefresh: Bool) async -> [MinecraftVersionInfo]

    /// 取某版本的客户端清单地址（供安装链路同步查询）。
    ///
    /// 只查内存中的合并清单；未加载或该版本不在清单中时返回 nil。
    func cachedClientManifestURL(for versionID: String) -> URL?

    /// 清空清单缓存（内存警告时由调用方触发）。
    func clearCache()
}

// MARK: - 默认实现

/// 复用 `GameVersionManifest` 的适配器。
///
/// `GameVersionManifest` 是 `enum`（纯静态实现），因此本类型不持有任何实例状态，
/// 可直接以 `struct` 满足 `Sendable`。
struct DefaultVersionCatalogService: VersionCatalogService {

    /// `nonisolated`：本类型无状态，构造不应被任何全局 actor 限制
    /// （否则在默认隔离为 `MainActor` 的编译口径下，默认参数等非隔离上下文无法构造它）。
    nonisolated init() {}

    func cachedVersions() -> [MinecraftVersionInfo]? {
        guard let entries = GameVersionManifest.cachedMerged() else { return nil }
        return entries.compactMap(MinecraftVersionInfo.init(manifestEntry:))
    }

    func fetchVersions(forceRefresh: Bool) async -> [MinecraftVersionInfo] {
        let entries = await GameVersionManifest.fetchMerged(forceRefresh: forceRefresh)
        // 合并清单的每个条目都带 "id"（GameVersionManifest 内部按 id 去重），
        // 因此 compactMap 不会丢弃数据；保留 compactMap 形态以免越界或臆造占位值。
        return entries.compactMap(MinecraftVersionInfo.init(manifestEntry:))
    }

    func cachedClientManifestURL(for versionID: String) -> URL? {
        GameVersionManifest.cachedClientManifestURL(for: versionID)
    }

    func clearCache() {
        GameVersionManifest.clearCache()
    }
}
