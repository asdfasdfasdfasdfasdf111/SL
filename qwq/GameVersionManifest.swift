//
//  GameVersionManifest.swift
//  模块化拆分：Mojang 游戏版本清单（从 GameViews.swift 拆出）
//  官方 + 未列出版本并发拉取合并（5 分钟内存缓存，失败保留旧缓存）
//

import Foundation

enum GameVersionManifest {

    private static let officialManifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest.json")!
    private static let unlistedManifestURL = URL(string: "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto/version_manifest.json")!
    private static let unlistedManifestRoot = "https://zkitefly.github.io/unlisted-versions-of-minecraft"
    private static let unlistedManifestMirrorRoot = "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto"

    private static var mergedManifestCache: [[String: Any]]?
    private static var mergedManifestFetchDate: Date?

    /// 并发拉取官方 + 未列出版本清单并合并（按 releaseTime 降序；未列出版本 URL 重写到 alist 镜像）
    static func fetchMerged() async -> [[String: Any]] {
        if let cached = mergedManifestCache,
           let date = mergedManifestFetchDate,
           Date().timeIntervalSince(date) < 300 {
            return cached
        }
        async let official = fetchList(url: officialManifestURL)
        async let unlisted = fetchList(url: unlistedManifestURL)
        var (merged, unlistedVersions) = await (official, unlisted)
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
        // 只在拉取成功（非空）时更新缓存；全部失败时保留旧缓存，避免空结果被缓存 5 分钟
        guard !merged.isEmpty else { return mergedManifestCache ?? merged }
        mergedManifestCache = merged
        mergedManifestFetchDate = Date()
        return merged
    }

    /// 清理合并清单缓存（内存警告时调用）
    static func clearCache() {
        mergedManifestCache = nil
        mergedManifestFetchDate = nil
    }

    private static func fetchList(url: URL) async -> [[String: Any]] {
        guard let (data, _) = try? await AppContext.shared.apiSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = json["versions"] as? [[String: Any]] else { return [] }
        return versions
    }
}
