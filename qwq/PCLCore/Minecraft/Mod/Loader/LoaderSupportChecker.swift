//
//  LoaderSupportChecker.swift
//  PCL.Mac
//
//  Created on 2026/8/9.
//

import Foundation

/// 加载器支持检测服务（后端核心，UI 层只消费结果，不直接联网 / 不直接读写缓存）。
///
/// 三级策略（对比版本清单仅 5 分钟内存 TTL 的既有实现）：
/// 1. 内存缓存：同会话内命中直接返回，秒级
/// 2. 磁盘缓存（`SL启动器/LoaderSupportCache.json`，7 天 TTL）：重启后同样秒开
/// 3. 联网并发检测（按 MC 版本剔除明确不可用的候选加载器，多端点 × 2 重试，8s 超时直连）：
///    失败区分「明确不支持（404/410/空数组）」与「结果未知（网络失败/5xx/超时）」
public enum LoaderSupportChecker {

    /// 显示名排序（Fabric → Forge → NeoForged → Quilt）
    public static let loaderOrder = ["Fabric", "Forge", "NeoForged", "Quilt"]

    /// 加载器支持检测结果三态：
    /// - `.supported([String])`：明确检测到这些加载器（可能为空列表，见 `.notSupported`）
    /// - `.notSupported`：API 明确返回「该版本无此加载器」（404/410/空数组）→ 可缓存空结果
    /// - `.unavailable`：结果未知（网络失败 / 5xx / 超时）→ 不得写入缓存，UI 显示「暂时无法获取」而非「不支持」
    public enum LoaderSupportResult: Equatable {
        case supported([String])
        case notSupported
        case unavailable

        /// 结果中的加载器列表（非 supported 恒为空）
        public var loaders: [String] {
            if case .supported(let l) = self { return l }
            return []
        }
        /// 是否「结果未知」
        public var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    // MARK: - 缓存存储（内存 + 磁盘，线程安全）

    private static let cacheLock = NSLock()
    private static var memoryCache: [String: [String]] = [:]
    private static var diskCache: [String: [String]]?

    private static let diskTTL: TimeInterval = 7 * 24 * 3600

    /// 磁盘缓存文件（与旧版 UI 层生成的缓存兼容）
    public static let cacheFile: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SL启动器")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LoaderSupportCache.json")
    }()

    /// 磁盘缓存保存时间戳（供 TTL 判断）
    public static var diskSavedAt: Double? {
        guard let data = try? Data(contentsOf: cacheFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["savedAt"] as? Double
    }

    // MARK: - 共享元数据直连会话（全局复用，避免每次检测新建 URLSession 浪费 TCP/TLS 握手）

    /// 加载器 meta API 专用会话：8s 请求 / 15s 资源超时（列表展示，无需下载级 30s 等待），
    /// 禁系统代理直连（与 Requests.swift URLSession.direct 同策略，避免代理出口 TLS 转发失败误判「不支持」）。
    private static let metaSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.httpShouldUsePipelining = true
        return URLSession(configuration: cfg)
    }()

    private static func readDiskCache() -> [String: [String]]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = diskCache { return cached }
        guard let data = try? Data(contentsOf: cacheFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["versions"] as? [String: [String]] else { return nil }
        diskCache = entries
        return entries
    }

    private static func writeDiskCache(_ entries: [String: [String]]) {
        let payload: [String: Any] = ["savedAt": Date().timeIntervalSince1970, "versions": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }

    // MARK: - 对外入口

    /// 同步查询缓存命中（内存 → 磁盘 TTL 内），未命中返回 nil。
    /// 供 UI 层先查一次：命中时直接展示、不闪烁 loading；未命中再走 `supportedLoaders(for:)` 异步联网。
    public static func cachedLoaders(for version: String) -> [String]? {
        guard !version.isEmpty else { return nil }
        cacheLock.lock()
        let memoryHit = memoryCache[version]
        cacheLock.unlock()
        if let memoryHit { return memoryHit }

        if let disk = readDiskCache(),
           let cached = disk[version],
           Date().timeIntervalSince1970 - (diskSavedAt ?? 0) < diskTTL {
            cacheLock.lock()
            memoryCache[version] = cached
            cacheLock.unlock()
            return cached
        }
        return nil
    }

    /// 获取某游戏版本支持的加载器检测结果（三态）。
    /// 命中任意缓存立即返回 supported；未命中则联网检测：
    /// - 明确支持 → 写缓存 + `.supported`
    /// - API 明确不支持（404/410/空数组）→ 写空缓存 + `.notSupported`
    /// - 网络失败结果未知 → 不写缓存，回退磁盘旧缓存（即使已过期）；无旧缓存则 `.unavailable`
    public static func supportedLoaders(for version: String) async -> LoaderSupportResult {
        if let cached = cachedLoaders(for: version) { return .supported(cached) }

        // 联网并发检测：区分「明确不支持」与「网络失败（结果未知）」
        let (detected, hasUnknown) = await detectLoaders(for: version)
        if !detected.isEmpty {
            // 检测到加载器：写入内存 + 磁盘缓存
            writeCache(version: version, loaders: detected)
            return .supported(detected)
        }
        if !hasUnknown {
            // 全部加载器均「明确不支持」（404 / 空数组）：空结果也值得缓存，
            // 否则 0 个加载器支持的版本每次进入详情页都重新联网白等数秒
            writeCache(version: version, loaders: [])
            return .notSupported
        }
        // 网络失败导致结果未知：不写缓存（避免覆盖旧缓存），回退磁盘旧缓存（即使已过期）
        if let disk = readDiskCache(), let cached = disk[version] {
            cacheLock.lock()
            memoryCache[version] = cached
            cacheLock.unlock()
            return .supported(cached)
        }
        return .unavailable
    }

    private static func writeCache(version: String, loaders: [String]) {
        cacheLock.lock()
        memoryCache[version] = loaders
        cacheLock.unlock()
        var disk = readDiskCache() ?? [:]
        disk[version] = loaders
        writeDiskCache(disk)
    }

    /// 仅清空内存缓存（内存警告时调用；磁盘缓存保留，下次仍秒开）
    public static func clearMemoryCache() {
        cacheLock.lock()
        memoryCache = [:]
        diskCache = nil
        cacheLock.unlock()
    }

    /// 清空全部缓存（手动刷新时调用）
    public static func clearCache() {
        clearMemoryCache()
        try? FileManager.default.removeItem(at: cacheFile)
    }

    // MARK: - 按 MC 版本剔除明确不可能的候选（减少无谓请求 + 避免误判）

    /// NeoForge 仅存在于 1.20.1+（首个版本 20.1.0-beta 对应 MC 1.20.1）；
    /// 快照/实验版本无正式 NeoForge，直接不请求，避免「404 → 明确不支持」误伤。
    private static func maySupportNeoForge(_ version: String) -> Bool {
        if version.range(of: #"^\d{2}w\d{2}"#, options: .regularExpression) != nil { return false } // 快照
        return versionAtLeast(version, min: "1.20.1")
    }

    /// 是否为快照版本（24w14a 等）——快照/未列出版本不做“明确不支持”缓存，结果未知时按 unavailable 处理
    private static func isSnapshotVersion(_ version: String) -> Bool {
        version.range(of: #"^\d{2}w\d{2}[a-z]?$"#, options: .regularExpression) != nil
    }

    /// 版本号数值比较（点分数字段逐段比较，忽略 pre/rc/快照后缀）
    private static func versionAtLeast(_ version: String, min: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").compactMap { Int($0) }
        }
        let a = parts(version), b = parts(min)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    // MARK: - 网络检测

    /// 单个加载器检测结论：supported（明确支持）/ notSupported（明确不支持）/ failed（结果未知，网络或 5xx 故障）
    private enum LoaderCheckResult {
        case supported
        case notSupported
        case failed
    }

    /// 并发检测候选加载器支持情况（已按 MC 版本剔除明确不可能的候选）。
    /// 返回 (支持的加载器显示名列表, 是否存在「结果未知」项)——区分明确不支持与网络失败，
    /// 供调用方决定能否把空结果写入缓存（网络失败时不得写缓存，须回退旧缓存）。
    private static func detectLoaders(for version: String) async -> ([String], Bool) {
        var candidates: [(key: String, display: String)] = [
            ("fabric", "Fabric"),
            ("forge", "Forge"),
            ("quilt", "Quilt")
        ]
        // NeoForge 按版本过滤：1.20.1 之前的版本明确不存在，不请求、不算「未知」
        if maySupportNeoForge(version) {
            candidates.append(("neoforge", "NeoForged"))
        }
        var supported: [String] = []
        var hasUnknown = false
        await withTaskGroup(of: (String, LoaderCheckResult).self) { group in
            for candidate in candidates {
                group.addTask {
                    let result = await checkLoaderSupport(key: candidate.key, version: version)
                    return (candidate.display, result)
                }
            }
            for await (display, result) in group {
                switch result {
                case .supported: supported.append(display)
                case .failed: hasUnknown = true
                case .notSupported: break
                }
            }
        }
        supported.sort {
            (loaderOrder.firstIndex(of: $0) ?? 99) < (loaderOrder.firstIndex(of: $1) ?? 99)
        }
        return (supported, hasUnknown)
    }

    /// 检查单个加载器对某版本是否可用：多端点逐个尝试，每端点最多重试 1 次。
    /// 结论语义：404/410/空数组 = 明确不支持（notSupported）；网络错误或 5xx 重试耗尽 = failed（结果未知）。
    /// 快照版本的结果一律视为未知（notSupported 结论不适用于未列出的实验版本）。
    private static func checkLoaderSupport(key: String, version: String) async -> LoaderCheckResult {
        let encoded = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version
        var urls: [URL] = []
        switch key {
        case "fabric":
            // 官方 Fabric Meta 优先，BMCLAPI 镜像兜底（检测与下载解析统一双源，避免「列表显示支持、下载解析失败」）
            urls = [
                URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(encoded)"),
                URL(string: "https://bmclapi2.bangbang93.com/fabric-meta/v2/versions/loader/\(encoded)")
            ].compactMap { $0 }
        case "forge":
            urls = [URL(string: "https://bmclapi2.bangbang93.com/forge/minecraft/\(encoded)")].compactMap { $0 }
        case "neoforge":
            urls = [URL(string: "https://bmclapi2.bangbang93.com/neoforge/list/\(encoded)")].compactMap { $0 }
        case "quilt":
            // bmclapi 的 quilt-meta 端点通常未实现（返回 404），优先官方 Quilt Meta API；
            // 官方失败时再尝试 bmclapi，避免单点故障导致误判「不支持」。
            urls = [
                URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(encoded)"),
                URL(string: "https://bmclapi2.bangbang93.com/quilt-meta/v3/versions/loader/\(encoded)")
            ].compactMap { $0 }
        default:
            urls = []
        }
        guard !urls.isEmpty else { return .notSupported }

        var anyFailed = false
        for url in urls {
            // 元数据 API 仅 2 次尝试（原 3 次 × 30s 对列表展示过重）：8s 超时直连，容忍瞬时抖动即可
            for attempt in 0..<2 {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
                do {
                    let (data, resp) = try await metaSession.data(for: req)
                    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        // 4xx = 明确结论（404/410 = 该版本无此加载器），直接判不支持，不再重试；
                        // 仅 5xx 视为瞬时故障，重试下一次。
                        if (400...499).contains(http.statusCode) {
                            return isSnapshotVersion(version) ? .failed : .notSupported
                        }
                        anyFailed = true
                        if attempt < 1 { try? await Task.sleep(nanoseconds: 400_000_000) }
                        continue
                    }
                    // Fabric/Quilt meta 返回「loader 数组」；Forge 返回版本数组；NeoForge list 返回数组
                    guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                        if attempt < 1 { try? await Task.sleep(nanoseconds: 400_000_000) }
                        continue
                    }
                    if array.isEmpty {
                        return isSnapshotVersion(version) ? .failed : .notSupported
                    }
                    return .supported
                } catch {
                    anyFailed = true
                    if attempt < 1 {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        continue
                    }
                }
            }
        }
        return anyFailed ? .failed : .notSupported
    }
}