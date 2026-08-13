import Foundation

// 数据模型族 → ModrinthModels.swift（ModrinthMod/ModrinthProject/ModrinthVersion）
// ModLoader → ModLoader.swift（加载器枚举 + displayName/assetName）

public class ModDownloader {
    private let baseURL = "https://api.modrinth.com/v2"
    private let userAgent = "Swim111Launcher/1.0 (Minecraft Launcher)"

    private var session: URLSession { AppContext.shared.apiSession }

    private var searchCache: [String: (timestamp: Date, results: [ModrinthMod])] = [:]
    private let cacheTTL: TimeInterval = 120
    private var cacheLock = os_unfair_lock()

    private var pendingRequests: [String: Task<[ModrinthMod], Error>] = [:]
    private var pendingLock = os_unfair_lock()

    public init() {}

    public func clearCache() {
        os_unfair_lock_lock(&cacheLock)
        searchCache.removeAll()
        os_unfair_lock_unlock(&cacheLock)
        os_unfair_lock_lock(&pendingLock)
        pendingRequests.removeAll()
        os_unfair_lock_unlock(&pendingLock)
    }

    private func cacheKey(query: String, limit: Int, loader: ModLoader?, gameVersion: String?) -> String {
        return "\(query.lowercased())|\(limit)|\(loader?.rawValue ?? "nil")|\(gameVersion ?? "nil")"
    }

    private func cachedSearchResult(forKey key: String) -> [ModrinthMod]? {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        guard let entry = searchCache[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > cacheTTL {
            searchCache.removeValue(forKey: key)
            return nil
        }
        return entry.results
    }

    private func setCacheResult(_ results: [ModrinthMod], forKey key: String) {
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        searchCache[key] = (timestamp: Date(), results: results)
        if searchCache.count > 50 {
            let oldestKey = searchCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key
            if let oldestKey = oldestKey { searchCache.removeValue(forKey: oldestKey) }
        }
    }

    private func request(_ path: String) -> URLRequest {
        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }
    
    public func searchMods(query: String, limit: Int = 20, loader: ModLoader? = nil, gameVersion: String? = nil) async throws -> [ModrinthMod] {
        let key = cacheKey(query: query, limit: limit, loader: loader, gameVersion: gameVersion)
        if let cached = cachedSearchResult(forKey: key) {
            return cached
        }

        os_unfair_lock_lock(&pendingLock)
        if let existingTask = pendingRequests[key] {
            os_unfair_lock_unlock(&pendingLock)
            return try await existingTask.value
        }
        os_unfair_lock_unlock(&pendingLock)

        let task = Task<[ModrinthMod], Error> {
            var components = URLComponents(string: baseURL + "/search")!
            var facetsParts: [String] = ["[\"project_type:mod\"]"]
            if let loader = loader {
                facetsParts.append("[\"categories:\(loader.rawValue)\"]")
            }
            if let gameVersion = gameVersion {
                facetsParts.append("[\"versions:\(gameVersion)\"]")
            }
            let facets = "[\(facetsParts.joined(separator: ","))]"
            components.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "facets", value: facets)
            ]
            var req = URLRequest(url: components.url!)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: req)
            let result = try JSONDecoder().decode(SearchResult.self, from: data)
            setCacheResult(result.hits, forKey: key)
            return result.hits
        }

        os_unfair_lock_lock(&pendingLock)
        pendingRequests[key] = task
        os_unfair_lock_unlock(&pendingLock)

        defer {
            os_unfair_lock_lock(&pendingLock)
            pendingRequests.removeValue(forKey: key)
            os_unfair_lock_unlock(&pendingLock)
        }

        return try await task.value
    }
    
    public func getProject(modId: String) async throws -> ModrinthProject {
        let req = request("/project/\(modId)")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(ModrinthProject.self, from: data)
    }

    public func getVersions(modId: String, loaders: [ModLoader]? = nil, gameVersions: [String]? = nil) async throws -> [ModrinthVersion] {
        var components = URLComponents(string: baseURL + "/project/\(modId)/version")!
        var queryItems: [URLQueryItem] = []
        if let loaders = loaders {
            // 多值数组必须逐个用引号包裹：["fabric","forge"]；旧实现拼成 ["fabric,forge"]
            // 会被 API 当成单个名为 "fabric,forge" 的 loader，永远查不到结果
            let loaderStr = loaders.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "loaders", value: "[\(loaderStr)]"))
        }
        if let gameVersions = gameVersions {
            let versionsStr = gameVersions.map { "\"\($0)\"" }.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "game_versions", value: "[\(versionsStr)]"))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        var req = URLRequest(url: components.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([ModrinthVersion].self, from: data)
    }
    
    @discardableResult
    public func downloadMod(version: ModrinthVersion, destination: URL, progressHandler: ((Double) -> Void)? = nil) async throws -> URL {
        guard let primaryFile = version.files.first(where: { $0.primary }) ?? version.files.first else {
            throw ModError.noDownloadableFile
        }
        let fileURL = URL(string: primaryFile.url)!
        let destURL = destination.appendingPathComponent(primaryFile.filename)
        
        let (tempURL, _) = try await session.download(from: fileURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }
    
    public func downloadLatestMod(modId: String, gameVersion: String, loader: ModLoader, destination: URL) async throws -> URL {
        let latest = try await resolveLatestVersion(modId: modId, gameVersion: gameVersion, loader: loader)
        return try await downloadMod(version: latest, destination: destination)
    }
    
    /// 不带加载器过滤的版本下载：资源包/光影等项目的版本 loaders 字段通常是 ["minecraft"] 或空，
    /// 用 mod 加载器（如 fabric）过滤会得到空结果导致永远下载失败。
    public func downloadLatestMod(modId: String, gameVersion: String, destination: URL) async throws -> URL {
        let latest = try await resolveLatestVersion(modId: modId, gameVersion: gameVersion, loader: nil)
        return try await downloadMod(version: latest, destination: destination)
    }

    /// 解析与目标游戏版本兼容的最新版本（多级降级匹配，对标 PCL2 的版本兼容策略）：
    /// - L1：API 精确过滤（game_versions + loaders，最快路径）
    /// - L2：去掉 game_versions 过滤 → 本地按「精确版本 + loader」筛选
    ///       （应对 API 索引版本号与用户所选版本号细微差异：如 API 只登记 1.20，用户选了 1.20.1）
    /// - L3：本地按「主版本前缀」匹配（1.20 ↔ 1.20.x，快照/预览版同前缀也算）
    /// - L4：放弃 loader 过滤按主版本前缀匹配（加载器交给用户自行判断）
    /// - L5：完全放弃过滤取最新版本（尽力而为，避免永远下载失败）
    /// 全部失败才抛 ModError.noCompatibleVersion。
    public func resolveLatestVersion(modId: String, gameVersion: String, loader: ModLoader? = nil) async throws -> ModrinthVersion {
        // L1：API 精确过滤（返回结果本身就是精确匹配的，bestMatch 只是取最新的一个）
        if let loader {
            let versions = try await getVersions(modId: modId, loaders: [loader], gameVersions: [gameVersion])
            if let match = Self.bestMatch(versions, gameVersion: gameVersion, loader: loader) { return match }
        } else {
            let versions = try await getVersions(modId: modId, gameVersions: [gameVersion])
            if let match = Self.bestMatch(versions, gameVersion: gameVersion, loader: nil) { return match }
        }

        // L2 起：拉全量版本列表，逐级放宽本地筛选（API 不传过滤参数返回按日期降序）
        let all = try await getVersions(modId: modId)
        // L2 精确版本（带 loader）
        if let match = Self.bestMatch(all, gameVersion: gameVersion, loader: loader) { return match }
        // L3 主版本前缀（带 loader）
        if let match = Self.bestMatch(all, gameVersion: gameVersion, loader: loader, prefixMatch: true) { return match }
        // L4 主版本前缀（不带 loader）
        if let match = Self.bestMatch(all, gameVersion: gameVersion, loader: nil, prefixMatch: true) { return match }
        // L5 最新
        if let first = all.first { return first }
        throw ModError.noCompatibleVersion
    }

    /// 从版本列表（已按日期降序）中选「兼容目标游戏版本」的最新一个。
    /// - Parameters:
    ///   - prefixMatch: 主版本前缀匹配：目标 "1.20" 兼容 "1.20.1"，目标 "1.20.1" 兼容 "1.20"
    private static func bestMatch(_ versions: [ModrinthVersion], gameVersion: String, loader: ModLoader?, prefixMatch: Bool = false) -> ModrinthVersion? {
        versions.first { v in
            if let loader, !v.loaders.contains(loader.rawValue) { return false }
            if prefixMatch {
                return v.game_versions.contains { gv in
                    gv == gameVersion
                        || gv.hasPrefix(gameVersion + ".")
                        || (gameVersion.contains(".") && gameVersion.hasPrefix(gv + "."))
                }
            }
            return v.game_versions.contains(gameVersion)
        }
    }

    /// 解析最新版本的主文件下载地址与文件名（供下载详情页任务使用，不在本方法内下载）。
    /// - Parameters:
    ///   - loader: 传 nil 表示不做加载器过滤（资源包/光影等 loaders 字段为 ["minecraft"] 或空的项目）
    public func resolveLatestFile(modId: String, gameVersion: String, loader: ModLoader? = nil) async throws -> (url: URL, filename: String) {
        let latest = try await resolveLatestVersion(modId: modId, gameVersion: gameVersion, loader: loader)
        guard let primary = latest.files.first(where: { $0.primary }) ?? latest.files.first,
              let url = URL(string: primary.url) else {
            throw ModError.noDownloadableFile
        }
        return (url, primary.filename)
    }
    
    private struct SearchResult: Codable {
        let hits: [ModrinthMod]
    }
    
    public func autoDownloadMod(modId: String) async throws -> URL {
        let settings = LauncherSettings.shared
        let gameVersion = settings.selectedMinecraftVersion
        let gameRoot = settings.selectedGameRoot

        guard !gameVersion.isEmpty else { throw ModError.noGameVersionSet }
        guard !gameRoot.isEmpty else { throw ModError.noGameRootSet }

        // 游戏启动时 game_directory 指向 <gameRoot>/versions/<version>，
        // mods 必须放在版本文件夹内才会被游戏加载
        let modsDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(gameVersion)/mods")

        // 逐个加载器尝试（resolveLatestVersion 内部已有多级降级匹配），任一成功即返回
        for loader in ModLoader.allCases {
            do {
                let latest = try await resolveLatestVersion(modId: modId, gameVersion: gameVersion, loader: loader)
                return try await downloadMod(version: latest, destination: modsDir)
            } catch { continue }
        }
        throw ModError.noCompatibleVersion
    }

    public enum ModError: Error, LocalizedError {
        case noDownloadableFile
        case noCompatibleVersion
        case noGameVersionSet
        case noGameRootSet

        public var errorDescription: String? {
            switch self {
            case .noDownloadableFile: return "模组版本没有可下载的文件"
            case .noCompatibleVersion: return "未找到兼容的模组版本"
            case .noGameVersionSet: return "未选择 Minecraft 版本"
            case .noGameRootSet: return "未设置游戏根目录"
            }
        }
    }
}
