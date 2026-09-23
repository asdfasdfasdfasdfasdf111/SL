import Foundation
import os

// 数据模型族 → ModrinthModels.swift（ModrinthMod/ModrinthProject/ModrinthVersion）
// ModLoader → ModLoader.swift（加载器枚举 + displayName/assetName）

// MARK: - Modrinth 搜索缓存（ModDownloader / ModpackDownloader 共用，替代两份逐字重复的 cache+TTL+lock）

/// TTL 结果缓存 + 同 key 并发请求合并
///
/// 锁的选型：原实现是 `private var lock = os_unfair_lock()` + 兼容层辅助函数 `withUnfairLock(&lock)`
///（该辅助函数已随 `SLCore/Utils/LockCompat.swift` 删除；此处保留这段经过，是因为它记录的
/// 是一个**静默失效的真缺陷**，不是纯历史）。
/// Apple《OSAllocatedUnfairLock》文档明确警告「it's unsafe to use `os_unfair_lock` from Swift
/// because it's a value type… Instead, use `OSAllocatedUnfairLock`, which avoids that pitfall」——
/// `&lock` 取到的是值的地址，一旦本类型改成非 `final` 或将来被搬进值类型，就会锁在临时副本上、
/// 互斥静默失效。现改用 `OSAllocatedUnfairLock`（macOS 13.0+，正好等于本项目部署目标）。
///
/// 同时把 `cached` / `inFlight` 从裸实例属性**并入锁所保护的状态**：此后没有任何路径能在
/// 不持锁的情况下碰到这两个字典，「忘记加锁」在结构上不可能发生（原实现靠人自觉）。
///
/// 为什么用 `withLockUnchecked` 而非 `withLock`：`withLock` 的签名是
/// `func withLock<R>(_ body: @Sendable (inout State) throws -> R) rethrows -> R where R: Sendable`，
/// 要求返回值 Sendable 且闭包 `@Sendable`。本类型是泛型 `ModrinthSearchCache<Value>`，
/// `Value` 无约束，`State` 里又有 `Task<Value, Error>`，用 `withLock` 直接编译不过。
/// `withLockUnchecked` 是官方为此提供的变体：加锁语义与 `withLock` **完全一致**
/// （同一份 `os_unfair_lock_lock/unlock` 实现），差别只是不做 Sendable 检查。
final class ModrinthSearchCache<Value> {
    private struct State {
        var cached: [String: (Date, Value)] = [:]
        var inFlight: [String: Task<Value, Error>] = [:]
    }

    private let ttl: TimeInterval
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    init(ttl: TimeInterval = 120) { self.ttl = ttl }

    func hit(_ key: String) -> Value? {
        lock.withLockUnchecked { state in
            guard let (ts, value) = state.cached[key] else { return nil }
            if Date().timeIntervalSince(ts) > ttl {
                state.cached.removeValue(forKey: key)
                return nil
            }
            return value
        }
    }

    func store(_ key: String, _ value: Value) {
        lock.withLockUnchecked { state in
            state.cached[key] = (Date(), value)
            if state.cached.count > 50, let oldest = state.cached.min(by: { $0.value.0 < $1.value.0 })?.key {
                state.cached.removeValue(forKey: oldest)
            }
        }
    }

    func existingTask(_ key: String) -> Task<Value, Error>? {
        lock.withLockUnchecked { $0.inFlight[key] }
    }

    func track(_ key: String, _ task: Task<Value, Error>) {
        lock.withLockUnchecked { $0.inFlight[key] = task }
    }

    func untrack(_ key: String) {
        // 闭包单表达式 `removeValue` 会返回被移除的 Task 作为 withLockUnchecked 的结果；
        // 已删除的兼容层辅助函数 `withUnfairLock` 带 @discardableResult（静默丢弃），系统原生 API 没有，
        // 故显式 `_ =` 表达同一语义，避免 #no-usage 告警
        _ = lock.withLockUnchecked { $0.inFlight.removeValue(forKey: key) }
    }

    func clear() {
        lock.withLockUnchecked { state in
            state.cached.removeAll()
            state.inFlight.removeAll()
        }
    }
}

public class ModDownloader {
    private let baseURL = "https://api.modrinth.com/v2"
    private let userAgent = "Swim111Launcher/1.0 (Minecraft Launcher)"

    private var session: URLSession { AppContext.shared.apiSession }

    private let searchCache = ModrinthSearchCache<[ModrinthMod]>()

    public init() {}

    public func clearCache() {
        searchCache.clear()
    }

    private func cacheKey(query: String, limit: Int, loader: ModLoader?, gameVersion: String?) -> String {
        return "\(query.lowercased())|\(limit)|\(loader?.rawValue ?? "nil")|\(gameVersion ?? "nil")"
    }

    private func request(_ path: String) -> URLRequest {
        let url = URL(string: baseURL + path)!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// 校验 HTTP 状态码，非 2xx 时抛出具**可读原因**的错误。
    ///
    /// 为什么必须有这一步（这是本文件里一个反复出现的真缺陷的收口）：
    /// 本类型此前的每一个取数点都写成 `let (data, _) = try await session.data(for: req)`，
    /// **`URLResponse` 被 `_` 丢弃**，于是：
    /// - 404（项目/版本不存在）→ 上游给的**空响应体**被喂给 `JSONDecoder`
    ///   → 抛出 `DecodingError`，用户看到「The data couldn't be read because it isn't in
    ///   the correct format.」；
    /// - 429（限流）、5xx（服务端故障）同理，全部被伪装成「数据格式不正确」。
    /// 结果是**失败原因完全不可诊断**：既不知道是网络、是被限流、还是 id 根本不存在。
    ///
    /// 实测记录（2026-09-23）：
    /// - `https://api.modrinth.com/v2/project/1.21.8` → **404 且 body 为空**
    /// - 镜像 `https://mod.mcimirror.top/modrinth/v2/project/1.21.8`
    ///   → 404 且 body 为 `{"error":"Not Found","code":404,"detail":"..."}`
    ///
    /// 本方法只改变**失败时的报错文案**，成功路径（2xx）行为逐字不变。
    private func validate(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        // 尽力解析错误体：解不出来（空体 / 网关 HTML）就只报状态码
        let apiError = try? JSONDecoder().decode(ModrinthAPIError.self, from: data)
        throw ModError.httpStatus(code: http.statusCode, detail: apiError?.detail)
    }
    
    public func searchMods(query: String, limit: Int = 20, loader: ModLoader? = nil, gameVersion: String? = nil) async throws -> [ModrinthMod] {
        let key = cacheKey(query: query, limit: limit, loader: loader, gameVersion: gameVersion)
        if let cached = searchCache.hit(key) {
            return cached
        }

        if let existingTask = searchCache.existingTask(key) {
            return try await existingTask.value
        }

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
            let (data, response) = try await session.data(for: req)
            // 先验状态码再解码：429/5xx 的错误体不是 SearchResult，直接解码会报「数据格式不正确」
            try validate(data, response)
            let result = try JSONDecoder().decode(SearchResult.self, from: data)
            searchCache.store(key, result.hits)
            return result.hits
        }

        searchCache.track(key, task)

        defer {
            searchCache.untrack(key)
        }

        return try await task.value
    }
    
    public func getProject(modId: String) async throws -> ModrinthProject {
        let req = request("/project/\(modId)")
        let (data, response) = try await session.data(for: req)
        // 先验状态码再解码：404 时官方返回空体，直接解码会报「数据格式不正确」
        try validate(data, response)
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
        let (data, response) = try await session.data(for: req)
        // 先验状态码再解码（同 getProject：429/5xx 的错误体不是版本数组）
        try validate(data, response)
        return try JSONDecoder().decode([ModrinthVersion].self, from: data)
    }
    
    /// 下载一个 Modrinth 版本的主文件到 `destination`。
    ///
    /// **移除了从未被调用的 `progressHandler` 参数**（第五轮深读）：
    /// 该参数自加入起就只在签名里存在——函数体走 `session.download(from:)`，
    /// 这条 API 不提供分片回调，全库（含 `qwqTests`）也没有任何调用点传过它。
    /// 结果是「调用方以为能拿到进度、实际一个回调都不会收到」的静默失效：
    /// 若某天有人传了闭包，UI 会永远停在 0% 且没有任何报错。
    /// 需要真实进度时须改用带 delegate 的下载（工程内已有先例：
    /// `qwq/Features/Java/JavaDownloader.swift:68/111` 用
    /// `URLSessionDownloadTask.progress.fractionCompleted` 汇报），届时再加回参数。
    @discardableResult
    public func downloadMod(version: ModrinthVersion, destination: URL) async throws -> URL {
        guard let primaryFile = version.files.first(where: { $0.primary }) ?? version.files.first else {
            throw ModError.noDownloadableFile
        }
        let fileURL = try URL(string: primaryFile.url).unwrap("模组文件下载地址无效")
        let destURL = destination.appendingPathComponent(primaryFile.filename)
        
        let (tempURL, _) = try await session.download(from: fileURL)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        if let sha1 = primaryFile.hashes?["sha1"], !sha1.isEmpty,
           let failReason = FileChecker(hash: sha1).check(destURL) {
            try? FileManager.default.removeItem(at: destURL)
            throw ModError.hashMismatch(failReason)
        }
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
    /// 全部失败才抛 ModError.noCompatibleVersion。
    /// 注意：不再继续放宽到「放弃 loader」「取最新」——那会把实际不兼容的文件
    /// （错误加载器 / 错误游戏版本）下载进游戏目录，破坏安装，宁可明确报错。
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
        // L3 主版本前缀（带 loader）：PCL2 语义——1.20 声明兼容 1.20.x 不算不兼容
        // （例：Fabric API 的 1.20 版本通常声明兼容整个 1.20.x 系列）
        if let match = Self.bestMatch(all, gameVersion: gameVersion, loader: loader, prefixMatch: true) { return match }
        // 不再放宽（历史 L4/L5）：放弃 loader / 取最新会下载实际不兼容的文件，
        // 错误加载器（如 Forge 装的 fabric 版）或错误游戏版本（如 1.18 用 1.20 的 mod）直接进目录
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
        /// 全库无引用，待清理（`downloadMod` 解析主文件地址失败时改抛 `noDownloadableFile`，
        /// 本 case 已无任何构造点；保留以维持错误枚举与既有文案表不变）。
        @available(*, deprecated, message: "全库无引用，待清理")
        case invalidURL
        case hashMismatch(String)

        /// 上游返回非 2xx。此前状态码被 `_` 丢弃、错误体被当成功响应解码，
        /// 于是 404/429/5xx 一律报成「数据格式不正确」——见 `validate(_:_:)` 的说明。
        ///
        /// - Parameters:
        ///   - code: HTTP 状态码
        ///   - detail: 上游给出的说明文字；官方 404 的响应体为空，故可能为 nil
        case httpStatus(code: Int, detail: String?)

        public var errorDescription: String? {
            switch self {
            case .noDownloadableFile: return "模组版本没有可下载的文件"
            case .noCompatibleVersion: return "未找到兼容的模组版本"
            case .noGameVersionSet: return "未选择 Minecraft 版本"
            case .noGameRootSet: return "未设置游戏根目录"
            case .invalidURL: return "模组文件下载地址无效"
            case .hashMismatch(let reason): return "模组文件完整性校验失败：\(reason)"
            case .httpStatus(let code, let detail):
                // 按状态码给「用户能据此判断下一步」的结论，而不是只丢一个数字。
                // 常见码的语义：404 = id 不存在（本工程最常见的来因是拿 Minecraft 版本号
                // 当项目 id 请求，见 DetailPageType.hasModrinthProject）；429 = 限流；
                // 5xx = 上游故障，稍后重试即可，用户无需改自己的操作。
                let base: String
                switch code {
                case 400: base = "请求参数不被上游接受（400）"
                case 403: base = "上游拒绝了本次请求（403）"
                case 404: base = "该项目或版本不存在（404）"
                case 429: base = "请求过于频繁，请稍后再试（429）"
                case 500...599: base = "Modrinth 服务端暂时不可用（\(code)）"
                default: base = "Modrinth 返回了意外的状态码（\(code)）"
                }
                // 上游给了原因就带上；没给（官方 404 是空体）就只说状态码
                guard let detail, !detail.isEmpty else { return base }
                return "\(base)：\(detail)"
            }
        }
    }
}
