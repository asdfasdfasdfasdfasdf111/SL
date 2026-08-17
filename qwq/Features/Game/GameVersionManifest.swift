//
//  GameVersionManifest.swift
//  模块化拆分：Mojang 游戏版本清单（从 GameViews.swift 拆出）
//  官方（主源失败回退 BMCLAPI 镜像）+ 未列出版本并发拉取合并
//  三级缓存：内存 5 分钟 → 磁盘 7 天 TTL（弱网/离线兜底）→ 联网刷新
//

import Foundation

enum GameVersionManifest {

    // MARK: - 数据源

    // 官方清单主源
    private static let officialManifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest.json")!
    // 官方清单镜像源（BMCLAPI）：主源拉取失败时自动回退，不依赖设置里「官方/镜像」二选一，
    // 始终按「主源 → 镜像」顺序自动尝试，避免单个源被阻断时版本列表空白
    private static let bmclapiManifestURL = URL(string: "https://bmclapi2.bangbang93.com/mc/game/version_manifest.json")!
    private static let unlistedManifestURL = URL(string: "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto/version_manifest.json")!
    private static let unlistedManifestRoot = "https://zkitefly.github.io/unlisted-versions-of-minecraft"
    private static let unlistedManifestMirrorRoot = "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto"

    // MARK: - 缓存存储

    /// 磁盘缓存 key（CacheManager 文本缓存，内容为 {"savedAt":…,"versions":[…]})
    private static let diskCacheKey = "game_version_manifest_merged"

    private static var mergedManifestCache: [[String: Any]]?
    private static var mergedManifestFetchDate: Date?

    /// 读取可立即展示的合并清单：优先内存，未命中时同步读取磁盘缓存。
    /// 下载列表先用它首帧渲染，联网刷新由调用方在后台执行。
    static func cachedMerged() -> [[String: Any]]? {
        if let mergedManifestCache, !mergedManifestCache.isEmpty { return mergedManifestCache }
        return readDiskCache()
    }

    /// 安装链路同步查询某版本的客户端 JSON URL。
    /// 下载页使用的是本类型合并后的「官方 + 未列出」清单，而旧安装器只查
    /// DataManager.versionManifest；两套清单不同步时旧代码会对缺失条目 unwrap 并崩溃。
    static func cachedClientManifestURL(for versionID: String) -> URL? {
        guard let entry = mergedManifestCache?.first(where: { ($0["id"] as? String) == versionID }),
              let urlString = entry["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    /// 并发拉取官方（主源失败回退镜像）+ 未列出版本清单并合并（按 releaseTime 降序；未列出版本 URL 重写到 alist 镜像）
    ///
    /// 三级策略（与加载器支持检测同款，根因：官方 + 未列出两个源全部失败且无缓存时返回空数组 → 下载页游戏列表空白）：
    /// 1. 内存缓存：5 分钟内直接返回，秒级
    /// 2. 磁盘缓存（CacheManager，联网全部失败时兜底，即使已过期也比列表空白强）
    /// 3. 联网：官方主源 + BMCLAPI 镜像并发（任意一个成功即用）、未列出源并发；成功即写内存 + 磁盘
    static func fetchMerged(forceRefresh: Bool = false) async -> [[String: Any]] {
        if !forceRefresh, let cached = mergedManifestCache,
           let date = mergedManifestFetchDate,
           Date().timeIntervalSince(date) < 300 {
            return cached
        }
        // 主源与镜像并发拉取：两个都失败才视为官方清单不可用（耗时取两者之短，而非串行累加）
        async let primary = fetchList(url: officialManifestURL)
        async let mirror = fetchList(url: bmclapiManifestURL)
        async let unlisted = fetchList(url: unlistedManifestURL)
        var (official, fallback, unlistedVersions) = await (primary, mirror, unlisted)
        if official.isEmpty { official = fallback }
        var merged = official
        for i in unlistedVersions.indices {
            if let url = unlistedVersions[i]["url"] as? String {
                unlistedVersions[i]["url"] = url.replacingOccurrences(of: unlistedManifestRoot, with: unlistedManifestMirrorRoot)
            }
            merged.append(unlistedVersions[i])
        }
        // 按 id 去重（保留官方条目），再按 releaseTime 降序
        var seen = Set<String>()
        merged.removeAll { entry in
            let id = entry["id"] as? String ?? ""
            if id.isEmpty || seen.contains(id) { return true }
            seen.insert(id)
            return false
        }
        merged.sort { ($0["releaseTime"] as? String ?? "") > ($1["releaseTime"] as? String ?? "") }
        // 拉取成功（非空）：更新内存缓存 + 写磁盘缓存
        guard !merged.isEmpty else {
            // 联网全部失败：优先回退磁盘旧缓存（即使已过期），其次内存旧缓存
            if let disk = readDiskCache() { return disk }
            return mergedManifestCache ?? merged
        }
        updateMemoryCache(merged)
        writeDiskCache(merged)
        return merged
    }

    /// 清理合并清单缓存（内存警告时调用）
    static func clearCache() {
        mergedManifestCache = nil
        mergedManifestFetchDate = nil
    }

    // MARK: - 磁盘缓存（{"savedAt":…,"versions":[…]}，复用 CacheManager 文本缓存）

    private static func readDiskCache() -> [[String: Any]]? {
        guard let text = AppContext.shared.cacheManager.textGet(diskCacheKey),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = json["versions"] as? [[String: Any]],
              !versions.isEmpty else { return nil }
        // 磁盘兜底命中后同步灌入内存索引，确保用户点下载时安装器能拿到同一条 URL
        updateMemoryCache(versions)
        return versions
    }

    private static func updateMemoryCache(_ versions: [[String: Any]]) {
        mergedManifestCache = versions
        mergedManifestFetchDate = Date()
    }

    private static func writeDiskCache(_ versions: [[String: Any]]) {
        let payload: [String: Any] = ["savedAt": Date().timeIntervalSince1970, "versions": versions]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        AppContext.shared.cacheManager.setText(text, forKey: diskCacheKey)
    }

    private static func fetchList(url: URL) async -> [[String: Any]] {
        guard let (data, _) = try? await AppContext.shared.apiSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = json["versions"] as? [[String: Any]] else { return [] }
        return versions
    }
}
