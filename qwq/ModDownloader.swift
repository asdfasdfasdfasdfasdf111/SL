import Foundation

public struct ModrinthMod: Identifiable, Codable {
    public let id: String
    public let slug: String
    public let title: String
    public let description: String?
    public let icon_url: String?
    public let downloads: Int
    public let versions: [String]
    
    public var identifier: String { id }
}

public struct ModrinthProject: Codable {
    public let id: String
    public let title: String?
    public let game_versions: [String]?
    public let loaders: [String]?
}

public struct ModrinthVersion: Codable {
    public let id: String
    public let name: String
    public let version_number: String
    public let game_versions: [String]
    public let loaders: [String]
    public let files: [ModrinthFile]
    
    public struct ModrinthFile: Codable {
        public let url: String
        public let filename: String
        public let primary: Bool
        public let size: Int
    }
}

public enum ModLoader: String, CaseIterable {
    case fabric, forge, quilt, neoforge, rift, unknown
}

extension ModLoader {
    var displayName: String {
        switch self {
        case .fabric: return "Fabric"
        case .forge: return "Forge"
        case .quilt: return "Quilt"
        case .neoforge: return "NeoForge"
        case .rift: return "Rift"
        case .unknown: return "Unknown"
        }
    }

    var assetName: String {
        switch self {
        case .fabric: return "fabric"
        case .forge: return "Forge"
        case .quilt: return "Quilt"
        case .neoforge: return "NeoForged"
        case .rift: return "fabric"
        case .unknown: return "fabric"
        }
    }
}

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
            let loaderStr = loaders.map { $0.rawValue }.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "loaders", value: "[\"\(loaderStr)\"]"))
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
        let versions = try await getVersions(modId: modId, loaders: [loader], gameVersions: [gameVersion])
        guard let latest = versions.first else {
            throw ModError.noCompatibleVersion
        }
        return try await downloadMod(version: latest, destination: destination)
    }
    
    /// 不带加载器过滤的版本下载：资源包/光影等项目的版本 loaders 字段通常是 ["minecraft"] 或空，
    /// 用 mod 加载器（如 fabric）过滤会得到空结果导致永远下载失败。
    public func downloadLatestMod(modId: String, gameVersion: String, destination: URL) async throws -> URL {
        let versions = try await getVersions(modId: modId, gameVersions: [gameVersion])
        guard let latest = versions.first else {
            throw ModError.noCompatibleVersion
        }
        return try await downloadMod(version: latest, destination: destination)
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

        return try await withThrowingTaskGroup(of: URL?.self) { group in
            for loader in ModLoader.allCases {
                group.addTask {
                    do {
                        let versions = try await self.getVersions(modId: modId, loaders: [loader], gameVersions: [gameVersion])
                        guard let latest = versions.first else { return nil }
                        return try await self.downloadMod(version: latest, destination: modsDir)
                    } catch { return nil }
                }
            }
            for try await result in group {
                if let url = result { group.cancelAll(); return url }
            }
            throw ModError.noCompatibleVersion
        }
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
