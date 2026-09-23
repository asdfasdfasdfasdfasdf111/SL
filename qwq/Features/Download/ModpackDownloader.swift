//
//  ModpackDownloader.swift
//  整合包（Modrinth 形态）的搜索 / 版本列表 / 文件下载。
//  走国内镜像 mod.mcimirror.top（代理 Modrinth v2 接口），比直连官方更快更稳。
//  搜索带两级去重：先查缓存，再查「同一个 key 是否已有在飞的请求」。
//

import Foundation

/// 搜索结果里的整合包条目（对应 Modrinth `/search` 响应中 hits 的元素）。
/// 注意 `versions` 是**版本号字符串数组**（不是版本对象），只用于列表展示与过滤。
public struct Modpack: Codable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    public let description: String?
    public let downloads: Int
    public let icon_url: String?
    public let versions: [String]
}

/// 整合包的一个具体版本（对应 `/project/{id}/version` 的元素）。
/// `game_versions` 与 `loaders` 是筛选/分组的主要依据；`files` 通常把主文件排在首位
/// —— 本模块的下载逻辑全部取 `files.first`，不区分主文件与附带文件。
public struct ModpackVersion: Codable {
    public let id: String
    public let name: String
    /// 整合包自身的版本号（给人看的，如 `1.2.3`）。
    /// 与 `id` 的区别：id 是稳定标识，本字段只用于展示与外键引用。
    public let version_number: String
    public let game_versions: [String]
    public let loaders: [String]
    public let files: [ModFile]
    
    /// 该版本下的一个文件。
    /// `hashes` 形如 `["sha1": "...", "sha512": "..."]`；下载完成后用其中的 sha1 做完整性校验
    /// （见 `downloadLatest`）。该字段缺失时**跳过校验**，而不是报错。
    public struct ModFile: Codable {
        public let url: String
        public let filename: String
        public let size: Int
        public let hashes: [String: String]?
    }
    
    /// ⚠️ 下面这份 CodingKeys 里的键与属性名**完全一致**，它并没有做任何字段名映射 ——
    /// 上一行「兼容不同字段名」的说法与代码不符，属遗留注释（以代码为准）。
    /// 它实际的作用只是**显式列出参与编解码的键**，避免将来给类型加无关属性时被自动编码进去。
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version_number
        case game_versions
        case loaders
        case files
    }
}

/// 整合包下载器。基本无状态（只有镜像地址常量与一个搜索缓存），可以自由创建多个实例。
/// 网络请求统一走 `AppContext.shared.apiSession`（会话级超时与连接复用策略）。
public class ModpackDownloader {
    // 国内镜像站（McIMirror），对国内网络下载更快更稳定
    /// ⚠️ 注意路径里带 `/modrinth/v2`：镜像代理的是 Modrinth **v2** 接口，
    /// 端点路径（`/search`、`/project/...`）与官方一致，换镜像站时只改域名前缀即可。
    private let base = "https://mod.mcimirror.top/modrinth/v2"
    private let userAgent = "Swim111Launcher/1.0 (Minecraft Launcher)"

    private var session: URLSession { AppContext.shared.apiSession }

    /// 搜索结果缓存（含 TTL 与「在飞请求」登记）。它按**结果类型**实例化，
    /// 因此本类的整合包缓存与 ModBrowser 那边的模组缓存互不干扰。
    private let searchCache = ModrinthSearchCache<[Modpack]>()

    public init() {}

    /// 缓存键。query 统一转小写（大小写不同的同一关键词应命中同一条），
    /// limit 也参与键 —— 同一关键词取 20 条与取 1 条是两次不同请求，结果不能混用。
    private func cacheKey(query: String, limit: Int) -> String {
        return "\(query.lowercased())|\(limit)"
    }

    /// 搜索整合包。三级取数：
    /// 1. 命中缓存 → 直接返回；
    /// 2. 同一个 key 已有在飞的请求 → **复用那个 Task**（并发调用不会打出多份重复请求）；
    /// 3. 都没有 → 自己发起请求，成功才把结果写入缓存。
    /// 失败（网络异常 / JSON 结构不符）直接向上抛，且**不写缓存**。
    public func search(query: String, limit: Int = 20) async throws -> [Modpack] {
        let key = cacheKey(query: query, limit: limit)
        if let cached = searchCache.hit(key) {
            return cached
        }

        if let existingTask = searchCache.existingTask(key) {
            return try await existingTask.value
        }

        // 用 Task 包住请求体，是为了让并发的同 key 调用能 await 到**同一个** Task（见上一步）。
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
            searchCache.store(key, result.hits)
            return result.hits
        }

        // 先登记在飞请求、再 await：await 期间进来的并发调用才能找到这个 Task 并复用它。
        searchCache.track(key, task)

        // 无论成功还是抛错都要把在飞登记摘掉 ——
        // 否则一次失败之后，同一个 key 会永远复用到一个已经失败的 Task 上。
        defer {
            searchCache.untrack(key)
        }

        return try await task.value
    }
    
    /// 取某整合包的全部版本列表。**不做缓存**：每次调用都会真实发一次请求。
    /// `downloadLatest` 与 `resolveFile` 都依赖它，两者连续调用会产生两次相同请求。
    public func versions(packId: String) async throws -> [ModpackVersion] {
        guard let url = URL(string: "\(base)/project/\(packId)/version") else { throw ModpackError.invalidURL }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([ModpackVersion].self, from: data)
    }

    /// 下载该整合包**最新版本**的主文件到 `destination`，返回落盘后的文件 URL。
    ///
    /// ⚠️ 「最新」完全依赖服务端返回的顺序（取 `versions.first`），本地不做任何版本比较。
    ///
    /// ⚠️ 执行顺序值得注意：**先下到系统临时文件 → 建目标目录 → 删掉同名旧文件 →
    /// 移入新文件 → 最后才校验 sha1**。也就是说校验失败时，不但新文件被删，
    /// 原本在那个位置的文件（可能是完好的）**也不会回来** ——
    /// 代价是目标位置变空，而不是回滚到旧文件。
    @discardableResult
    public func downloadLatest(packId: String, to destination: URL) async throws -> URL {
        let versions = try await versions(packId: packId)
        guard let latest = versions.first,
              let file = latest.files.first else {
            throw ModpackError.noFile
        }
        let destFile = destination.appendingPathComponent(file.filename)
        guard let fileUrl = URL(string: file.url) else { throw ModpackError.invalidURL }

        // URLSession 的下载先落在系统临时目录，再由本方法手动搬到目标位置。
        let (tempUrl, _) = try await session.download(from: fileUrl)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destFile.path) {
            try FileManager.default.removeItem(at: destFile)
        }
        try FileManager.default.moveItem(at: tempUrl, to: destFile)

        // 有 sha1 才校验；`file.hashes` 缺失或没有 sha1 键时**直接跳过校验**（静默放行）。
        // ⚠️ `check` 是**同步重活**（整文件流式哈希，几百 MB 的整合包可达数秒）。
        // 本方法是 async，但若调用方来自主 actor，这一行会**阻塞主线程** ——
        // FileChecker 自己的文档也写着「禁止在主线程调用」。
        if let sha1 = file.hashes?["sha1"], !sha1.isEmpty,
           let failReason = FileChecker(hash: sha1).check(destFile) {
            try? FileManager.default.removeItem(at: destFile)
            throw ModpackError.hashMismatch(failReason)
        }
        return destFile
    }
    
    /// 解析指定整合包版本的主文件下载地址与文件名（供下载详情页任务使用，不在本方法内下载）。
    /// - Parameter versionId: 用户选中的版本 id（ModpackVersion.id）；找不到时回退到最新版本
    /// ⚠️ 指定的 `versionId` 不存在时，会**静默回退到版本列表的第一项**而不是报错 ——
    /// 调用方从返回值看不出「你要的版本没有，我给了你另一个」。
    public func resolveFile(packId: String, versionId: String) async throws -> (url: URL, filename: String) {
        let versions = try await versions(packId: packId)
        guard let target = versions.first(where: { $0.id == versionId }) ?? versions.first,
              let file = target.files.first,
              let url = URL(string: file.url) else {
            throw ModpackError.noFile
        }
        return (url, file.filename)
    }

    /// 便捷方法：按关键词搜整合包 → 取第一条 → 下载它的最新版本。
    /// 供「随便来一个」的场景使用，不做二次确认。
    public func downloadFirst(query: String, to destination: URL) async throws -> URL {
        let packs = try await search(query: query, limit: 1)
        guard let pack = packs.first else { throw ModpackError.notFound }
        return try await downloadLatest(packId: pack.id, to: destination)
    }
    
    /// `/search` 的响应体。只取 `hits`，其余字段（total_hits / offset / limit）用不到。
    private struct SearchResult: Codable {
        let hits: [Modpack]
    }
    
    /// 整合包链路的错误。`LocalizedError` 的文案会**直接展示给用户**，
    /// 所以每条都是完整句子，不出现错误码或英文标识。
    public enum ModpackError: Error, LocalizedError {
        case noFile, notFound, invalidURL, hashMismatch(String)
        public var errorDescription: String? {
            switch self {
            case .noFile: return "整合包版本没有可下载的文件"
            case .notFound: return "未找到匹配的整合包"
            case .invalidURL: return "整合包文件下载地址无效"
            case .hashMismatch(let reason): return "整合包文件完整性校验失败：\(reason)"
            }
        }
    }
}
