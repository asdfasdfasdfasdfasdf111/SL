import Foundation

public struct Modpack: Codable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    public let description: String?
    public let downloads: Int
    public let icon_url: String?
    public let versions: [String]
}

public struct ModpackVersion: Codable {
    public let id: String
    public let name: String
    public let version_number: String
    public let game_versions: [String]
    public let loaders: [String]
    public let files: [ModFile]
    
    public struct ModFile: Codable {
        public let url: String
        public let filename: String
        public let size: Int
    }
    
    // 兼容官方 Modrinth API 的不同字段名
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version_number
        case game_versions
        case loaders
        case files
    }
}

public class ModpackDownloader {
    // 国内镜像站（McIMirror），对国内网络下载更快更稳定
    private let base = "https://mod.mcimirror.top/modrinth/v2"
    private let userAgent = "Swim111Launcher/1.0 (Minecraft Launcher)"

    private var session: URLSession { AppContext.shared.apiSession }

    private var searchCache: [String: (timestamp: Date, results: [Modpack])] = [:]
    private let cacheTTL: TimeInterval = 120
    private var cacheLock = os_unfair_lock()

    private var pendingRequests: [String: Task<[Modpack], Error>] = [:]
    private var pendingLock = os_unfair_lock()

    public init() {}

    private func cacheKey(query: String, limit: Int) -> String {
        return "\(query.lowercased())|\(limit)"
    }

    private func cachedSearchResult(forKey key: String) -> [Modpack]? {
        withUnfairLock(&cacheLock) {
            guard let entry = searchCache[key] else { return nil }
            if Date().timeIntervalSince(entry.timestamp) > cacheTTL {
                searchCache.removeValue(forKey: key)
                return nil
            }
            return entry.results
        }
    }

    private func setCacheResult(_ results: [Modpack], forKey key: String) {
        withUnfairLock(&cacheLock) {
            searchCache[key] = (timestamp: Date(), results: results)
            if searchCache.count > 50 {
                let oldestKey = searchCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key
                if let oldestKey = oldestKey { searchCache.removeValue(forKey: oldestKey) }
            }
        }
    }

    public func search(query: String, limit: Int = 20) async throws -> [Modpack] {
        let key = cacheKey(query: query, limit: limit)
        if let cached = cachedSearchResult(forKey: key) {
            return cached
        }

        if let existingTask = withUnfairLock(&pendingLock, { pendingRequests[key] }) {
            return try await existingTask.value
        }

        let task = Task<[Modpack], Error> {
            var components = URLComponents(string: "\(base)/search")!
            components.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "facets", value: "[[\"project_type:modpack\"]]")
            ]
            var req = URLRequest(url: components.url!)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: req)
            let result = try JSONDecoder().decode(SearchResult.self, from: data)
            setCacheResult(result.hits, forKey: key)
            return result.hits
        }

        withUnfairLock(&pendingLock) { pendingRequests[key] = task }

        defer {
            withUnfairLock(&pendingLock) { pendingRequests.removeValue(forKey: key) }
        }

        return try await task.value
    }
    
    public func versions(packId: String) async throws -> [ModpackVersion] {
        let url = URL(string: "\(base)/project/\(packId)/version")!
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([ModpackVersion].self, from: data)
    }

    @discardableResult
    public func downloadLatest(packId: String, to destination: URL) async throws -> URL {
        let versions = try await versions(packId: packId)
        guard let latest = versions.first,
              let file = latest.files.first else {
            throw ModpackError.noFile
        }
        let fileUrl = URL(string: file.url)!
        let destFile = destination.appendingPathComponent(file.filename)

        let (tempUrl, _) = try await session.download(from: fileUrl)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destFile.path) {
            try FileManager.default.removeItem(at: destFile)
        }
        try FileManager.default.moveItem(at: tempUrl, to: destFile)
        return destFile
    }
    
    /// 解析指定整合包版本的主文件下载地址与文件名（供下载详情页任务使用，不在本方法内下载）。
    /// - Parameter versionId: 用户选中的版本 id（ModpackVersion.id）；找不到时回退到最新版本
    public func resolveFile(packId: String, versionId: String) async throws -> (url: URL, filename: String) {
        let versions = try await versions(packId: packId)
        guard let target = versions.first(where: { $0.id == versionId }) ?? versions.first,
              let file = target.files.first,
              let url = URL(string: file.url) else {
            throw ModpackError.noFile
        }
        return (url, file.filename)
    }

    public func downloadFirst(query: String, to destination: URL) async throws -> URL {
        let packs = try await search(query: query, limit: 1)
        guard let pack = packs.first else { throw ModpackError.notFound }
        return try await downloadLatest(packId: pack.id, to: destination)
    }
    
    private struct SearchResult: Codable {
        let hits: [Modpack]
    }
    
    public enum ModpackError: Error, LocalizedError {
        case noFile, notFound
        public var errorDescription: String? {
            switch self {
            case .noFile: return "整合包版本没有可下载的文件"
            case .notFound: return "未找到匹配的整合包"
            }
        }
    }
}
