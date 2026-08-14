//
//  LoaderSupportChecker.swift
//  PCL.Mac
//
//  Created on 2026/8/9.
//

import Foundation

/// 单个加载器的检测状态（供 UI 逐卡片渲染，完成一个显示一个）
public enum LoaderState: Equatable {
    case checking
    case supported
    case notSupported
    case unavailable
}

/// 加载器支持检测服务（后端核心，UI 层只消费结果，不直接联网 / 不直接读写缓存）。
///
/// 检测策略（Beta 0.1.10 重构，解决「未缓存版本的加载器列表加载过慢」）：
/// 1. 内存缓存：同会话内命中直接返回，秒级
/// 2. 磁盘缓存（`SL启动器/LoaderSupportCache.json`）：**按「版本 × 单个加载器」粒度**缓存，
///    supported 14 天 / notSupported 7 天（快照与最新大版本 24h），unavailable 不缓存——
///    部分加载器网络失败不再拖累整版结果无法缓存，下次只重查未定论项
/// 3. 联网并发检测（仅未定论项）：每加载器单请求（4s 请求 / 6s 资源超时直连），
///    双源加载器 700ms 延迟并发备用源，不再串行等待主源完整超时
/// 4. 同版本 in-flight 合并 + 预加载：同一版本并发请求复用同一个检测任务（不重复联网）；
///    检测响应数组存入内存缓存，供 LoaderVersionResolver 复用（下载解析免二次请求）
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

    private struct LoaderCacheEntry: Codable {
        let state: String      // "supported" / "notSupported"
        let t: TimeInterval    // checkedAt
    }

    private static let cacheLock = NSLock()
    private static var memoryCache: [String: [String: LoaderCacheEntry]] = [:]
    private static var diskCache: [String: [String: LoaderCacheEntry]]?
    /// 磁盘文件读写专用锁（避免与 cacheLock 嵌套：磁盘 IO 全部走 diskLock，内存走 cacheLock）
    private static let diskLock = NSLock()

    /// supported 定论缓存时长
    private static let supportedTTL: TimeInterval = 14 * 24 * 3600
    /// notSupported 定论缓存时长（老版本）
    private static let notSupportedTTL: TimeInterval = 7 * 24 * 3600
    /// notSupported 定论缓存时长（快照 / 最新大版本：刚发布时加载器可能晚几天才推出）
    private static let notSupportedShortTTL: TimeInterval = 24 * 3600

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

    /// 加载器 meta API 专用会话：4s 请求 / 6s 资源超时（列表展示，单请求、不重试，
    /// 双源延迟并发兜底；不再为前台列表等待两轮 8s 超时），禁系统代理直连。
    private static let metaSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.httpShouldUsePipelining = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - 磁盘读写（全部在 diskLock 内，避免与 cacheLock 嵌套死锁）

    private static func loadDiskCache() -> [String: [String: LoaderCacheEntry]]? {
        guard let data = try? Data(contentsOf: cacheFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = json["versions"] else { return nil }
        // v2 格式：{"1.20.1": {"Fabric": {"state": "...", "t": 123}}}
        if let v2 = versions as? [String: [String: [String: Any]]] {
            var out: [String: [String: LoaderCacheEntry]] = [:]
            for (v, entries) in v2 {
                var e: [String: LoaderCacheEntry] = [:]
                for (loader, dict) in entries {
                    if let state = dict["state"] as? String, let t = dict["t"] as? Double {
                        e[loader] = LoaderCacheEntry(state: state, t: t)
                    }
                }
                if !e.isEmpty { out[v] = e }
            }
            return out.isEmpty ? nil : out
        }
        // v1 格式兼容：{"1.20.1": ["Fabric", "Forge"]} → 全部视为刚定论的 supported
        if let v1 = versions as? [String: [String]] {
            var out: [String: [String: LoaderCacheEntry]] = [:]
            let now = Date().timeIntervalSince1970
            for (v, list) in v1 {
                var e: [String: LoaderCacheEntry] = [:]
                for loader in list { e[loader] = LoaderCacheEntry(state: "supported", t: now) }
                if !e.isEmpty { out[v] = e }
            }
            return out.isEmpty ? nil : out
        }
        return nil
    }

    private static func saveDiskCache(_ entries: [String: [String: LoaderCacheEntry]]) {
        var versions: [String: [String: [String: Any]]] = [:]
        for (v, e) in entries {
            var ve: [String: [String: Any]] = [:]
            for (loader, entry) in e {
                ve[loader] = ["state": entry.state, "t": entry.t]
            }
            versions[v] = ve
        }
        let payload: [String: Any] = ["savedAt": Date().timeIntervalSince1970, "versions": versions]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }

    private static func readDiskCache() -> [String: [String: LoaderCacheEntry]]? {
        cacheLock.lock()
        let cached = diskCache
        cacheLock.unlock()
        if let cached { return cached }
        diskLock.lock()
        defer { diskLock.unlock() }
        let loaded = loadDiskCache()
        cacheLock.lock()
        diskCache = loaded
        cacheLock.unlock()
        return loaded
    }

    /// 单加载器定论写入：内存（cacheLock 内）+ 磁盘（diskLock 内，串行化读-改-写，防并发丢更新）
    private static func writeEntry(version: String, loader: String, state: LoaderState) {
        let entry = LoaderCacheEntry(state: state == .supported ? "supported" : "notSupported", t: Date().timeIntervalSince1970)
        cacheLock.lock()
        if memoryCache[version] == nil { memoryCache[version] = [:] }
        memoryCache[version]?[loader] = entry
        cacheLock.unlock()

        diskLock.lock()
        defer { diskLock.unlock() }
        var disk = loadDiskCache() ?? [:]
        if disk[version] == nil { disk[version] = [:] }
        disk[version]?[loader] = entry
        saveDiskCache(disk)
    }

    /// 取某版本全部缓存条目（内存 → 磁盘，按 TTL 过滤过期项；过期项不再返回，等下次定论时覆盖）
    private static func cacheEntries(for version: String) -> [String: LoaderCacheEntry]? {
        cacheLock.lock()
        let memoryHit = memoryCache[version]
        cacheLock.unlock()
        if let memoryHit { return filteredEntries(memoryHit, version: version) }

        guard let disk = readDiskCache(), let entries = disk[version] else { return nil }
        let filtered = filteredEntries(entries, version: version)
        cacheLock.lock()
        memoryCache[version] = filtered
        cacheLock.unlock()
        return filtered
    }

    private static func filteredEntries(_ entries: [String: LoaderCacheEntry], version: String) -> [String: LoaderCacheEntry]? {
        let now = Date().timeIntervalSince1970
        var out: [String: LoaderCacheEntry] = [:]
        for (loader, entry) in entries {
            let ttl = entry.state == "supported" ? supportedTTL : notSupportedTTL(for: version)
            if now - entry.t < ttl { out[loader] = entry }
        }
        return out.isEmpty ? nil : out
    }

    private static func notSupportedTTL(for version: String) -> TimeInterval {
        isSnapshotVersion(version) || versionAtLeast(version, min: "1.21") ? notSupportedShortTTL : notSupportedTTL
    }

    // MARK: - 对外查询（同步，主线程可直接调）

    /// 某版本已定论的加载器状态（仅 supported / notSupported；unavailable 永不入缓存）。
    /// nil = 该版本完全无缓存；非 nil 但为空字典 = 缓存已全部过期
    public static func cachedLoaderStates(for version: String) -> [String: LoaderState]? {
        guard !version.isEmpty else { return nil }
        guard let entries = cacheEntries(for: version) else { return nil }
        var states: [String: LoaderState] = [:]
        for (loader, entry) in entries {
            states[loader] = entry.state == "supported" ? .supported : .notSupported
        }
        return states.isEmpty ? nil : states
    }

    /// 同步查询缓存命中（supported 名称列表）：nil = 未缓存；[] = 已缓存但明确不支持。
    /// 供 UI 层先查一次：命中时直接展示、不闪烁 loading；未命中再走流式检测。
    public static func cachedLoaders(for version: String) -> [String]? {
        guard let states = cachedLoaderStates(for: version) else { return nil }
        return states.compactMap { $0.value == .supported ? $0.key : nil }.sorted { orderIndex($0) < orderIndex($1) }
    }

    /// 该版本应检测的候选加载器显示名（按 MC 版本剔除明确不可能的项，如 <1.20.1 无 NeoForge）
    public static func candidateDisplayNames(for version: String) -> [String] {
        var names = ["Fabric", "Forge", "Quilt"]
        if maySupportNeoForge(version) { names.append("NeoForged") }
        return names
    }

    /// 缓存是否已覆盖全部候选（无 missing / unavailable 项）—— 全部定论则无需联网
    public static func isFullyResolved(_ states: [String: LoaderState], for version: String) -> Bool {
        for name in candidateDisplayNames(for: version) {
            if states[name] == nil || states[name] == .unavailable { return false }
        }
        return true
    }

    // MARK: - 对外异步查询（流式 / 聚合 / 预加载）

    /// 流式检测：先 yield 缓存已定论项（秒回），随后 TaskGroup 每完成一个加载器就立刻广播一个结果。
    /// 同版本的前台/预加载调用共享一个 in-flight 任务；每个流订阅者单独登记、终止时单独移除。
    public static func streamLoaderStates(for version: String) -> AsyncStream<(loader: String, state: LoaderState)> {
        AsyncStream { continuation in
            if let cached = cachedLoaderStates(for: version) {
                for (loader, state) in cached { continuation.yield((loader, state)) }
            }

            let subscriberID = UUID()
            let snapshot = subscribeInflight(version: version, subscriberID: subscriberID, continuation: continuation)
            continuation.onTermination = { _ in
                unsubscribeInflight(version: version, ownerID: snapshot.id, subscriberID: subscriberID)
            }
            Task {
                let finalStates = await snapshot.task.value
                // 覆盖「读取缓存 → 登记订阅」之间极小窗口内可能漏掉的广播；重复 yield 幂等。
                for (loader, state) in finalStates { continuation.yield((loader, state)) }
                continuation.finish()
                unsubscribeInflight(version: version, ownerID: snapshot.id, subscriberID: subscriberID)
                dismissInflight(version: version, ownerID: snapshot.id)
            }
        }
    }

    /// 检测某版本全部候选加载器（已定论项直接取缓存；仅未定论项联网并发检测，单请求 4s 超时）。
    /// 同版本 in-flight 合并：查询/创建/登记均在同一锁区间内，杜绝两个调用同时创建两组请求。
    public static func checkLoaderStates(for version: String) async -> [String: LoaderState] {
        let snapshot = getOrCreateInflight(for: version)
        let result = await snapshot.task.value
        // 归属校验：只有创建本任务的 ownerID 仍属于该版本时才清理，旧任务绝不清掉新任务。
        dismissInflight(version: version, ownerID: snapshot.id)
        return result
    }

    /// 静默预加载：已全部定论则 no-op；否则后台触发检测（in-flight 合并，详情页/列表悬停可放心调用）
    public static func prefetchForVersion(_ version: String) {
        guard !version.isEmpty else { return }
        if let states = cachedLoaderStates(for: version), isFullyResolved(states, for: version) { return }
        _ = Task { _ = await checkLoaderStates(for: version) }
    }

    /// 兼容旧调用：聚合三态结果（内部走单加载器缓存 + 未定论项检测）
    public static func supportedLoaders(for version: String) async -> LoaderSupportResult {
        if let cached = cachedLoaders(for: version) { return .supported(cached) }
        let states = await checkLoaderStates(for: version)
        let supported = states.compactMap { $0.value == .supported ? $0.key : nil }.sorted { orderIndex($0) < orderIndex($1) }
        let hasUnknown = states.values.contains { $0 == .unavailable }
        if !supported.isEmpty { return .supported(supported) }
        if !hasUnknown { return .notSupported }
        if let cached = cachedLoaders(for: version) { return .supported(cached) }  // 过期磁盘兜底
        return .unavailable
    }

    // MARK: - 检测响应数组缓存（供 LoaderVersionResolver 复用，下载解析免二次请求）

    private static var versionListCache: [String: Data] = [:]
    private static let versionListLock = NSLock()

    private static func storeVersionList(loader: String, mc: String, data: Data) {
        versionListLock.lock()
        versionListCache["\(loader)|\(mc)"] = data
        versionListLock.unlock()
    }

    /// 读取检测阶段缓存的加载器版本数组（原始响应），nil = 未检测过
    public static func cachedVersionList(loader: String, mc: String) -> Data? {
        versionListLock.lock()
        defer { versionListLock.unlock() }
        return versionListCache["\(loader)|\(mc)"]
    }

    // MARK: - 缓存清理

    public static func clearMemoryCache() {
        cacheLock.lock()
        memoryCache = [:]
        diskCache = nil
        cacheLock.unlock()
        inflightLock.lock()
        let runningTasks = inflight.values.map(\.task)
        inflight = [:]
        inflightLock.unlock()
        // 先摘除归属再取消：迟到回调无法找到条目，更不可能清理后续新任务。
        for task in runningTasks { task.cancel() }
        versionListLock.lock()
        versionListCache = [:]
        versionListLock.unlock()
    }

    public static func clearCache() {
        clearMemoryCache()
        try? FileManager.default.removeItem(at: cacheFile)
    }

    // MARK: - 按 MC 版本剔除明确不可能的候选（减少无谓请求 + 避免误判）

    private static func maySupportNeoForge(_ version: String) -> Bool {
        if version.range(of: #"^\d{2}w\d{2}"#, options: .regularExpression) != nil { return false }
        return versionAtLeast(version, min: "1.20.1")
    }

    private static func isSnapshotVersion(_ version: String) -> Bool {
        version.range(of: #"^\d{2}w\d{2}[a-z]?$"#, options: .regularExpression) != nil
    }

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

    private static func orderIndex(_ name: String) -> Int {
        loaderOrder.firstIndex(of: name) ?? 99
    }

    private static func displayName(for key: String) -> String {
        switch key {
        case "fabric": return "Fabric"
        case "forge": return "Forge"
        case "neoforge": return "NeoForged"
        case "quilt": return "Quilt"
        default: return key
        }
    }

    // MARK: - in-flight 合并（原子创建 + ownerID 归属保护 + 多订阅者广播）

    private struct InflightEntry {
        let id: UUID
        let task: Task<[String: LoaderState], Never>
        var subscribers: [UUID: AsyncStream<(loader: String, state: LoaderState)>.Continuation] = [:]
    }

    private struct InflightSnapshot {
        let id: UUID
        let task: Task<[String: LoaderState], Never>
    }

    private static let inflightLock = NSLock()
    private static var inflight: [String: InflightEntry] = [:]

    /// 查询或创建任务必须在同一锁区间内完成，杜绝并发调用同时创建两组网络请求。
    private static func getOrCreateInflight(for version: String) -> InflightSnapshot {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        if let existing = inflight[version] {
            return InflightSnapshot(id: existing.id, task: existing.task)
        }
        let id = UUID()
        let task = Task { await detectAndMergeStates(for: version) }
        inflight[version] = InflightEntry(id: id, task: task)
        return InflightSnapshot(id: id, task: task)
    }

    /// 注册流订阅者；查询/创建/登记在同一锁区间内，避免错过新任务归属。
    private static func subscribeInflight(
        version: String,
        subscriberID: UUID,
        continuation: AsyncStream<(loader: String, state: LoaderState)>.Continuation
    ) -> InflightSnapshot {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        if var existing = inflight[version] {
            existing.subscribers[subscriberID] = continuation
            inflight[version] = existing
            return InflightSnapshot(id: existing.id, task: existing.task)
        }
        let id = UUID()
        let task = Task { await detectAndMergeStates(for: version) }
        var entry = InflightEntry(id: id, task: task)
        entry.subscribers[subscriberID] = continuation
        inflight[version] = entry
        return InflightSnapshot(id: id, task: task)
    }

    /// TaskGroup 单项完成后立刻广播；复制 continuation 后解锁再 yield，避免回调重入锁。
    private static func publishInflight(version: String, loader: String, state: LoaderState) {
        inflightLock.lock()
        let subscribers: [AsyncStream<(loader: String, state: LoaderState)>.Continuation]
        if let entry = inflight[version] {
            subscribers = Array(entry.subscribers.values)
        } else {
            subscribers = []
        }
        inflightLock.unlock()
        for continuation in subscribers { continuation.yield((loader, state)) }
    }

    private static func unsubscribeInflight(version: String, ownerID: UUID, subscriberID: UUID) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard var entry = inflight[version], entry.id == ownerID else { return }
        entry.subscribers.removeValue(forKey: subscriberID)
        inflight[version] = entry
    }

    /// 归属校验清理：旧任务迟到完成时 ownerID 不匹配，绝不会清掉新任务。
    private static func dismissInflight(version: String, ownerID: UUID) {
        inflightLock.lock()
        defer { inflightLock.unlock() }
        guard inflight[version]?.id == ownerID else { return }
        inflight[version] = nil
    }

    // MARK: - 网络检测

    private enum LoaderCheckResult {
        case supported
        case notSupported
        case failed
    }

    /// 缓存定论 + 未定论项并发检测 → 全量状态；每项定论立即写单加载器缓存（unavailable 不写）
    private static func detectAndMergeStates(for version: String) async -> [String: LoaderState] {
        var states = cachedLoaderStates(for: version) ?? [:]

        let missing = candidateDisplayNames(for: version).filter { name in
            states[name] == nil || states[name] == .unavailable
        }
        guard !missing.isEmpty else { return states }

        await withTaskGroup(of: (String, LoaderCheckResult).self) { group in
            for name in missing {
                group.addTask {
                    let key = key(for: name)
                    let result = await checkLoaderSupport(key: key, version: version)
                    return (name, result)
                }
            }
            for await (name, result) in group {
                switch result {
                case .supported:
                    states[name] = .supported
                    writeEntry(version: version, loader: name, state: .supported)
                case .notSupported:
                    states[name] = .notSupported
                    writeEntry(version: version, loader: name, state: .notSupported)
                case .failed:
                    states[name] = .unavailable
                    // 不写缓存：下次只重查该未定论项
                }
                // 真流式：TaskGroup 每完成一个加载器就立即广播，不等其余端点结束。
                if let state = states[name] {
                    publishInflight(version: version, loader: name, state: state)
                }
            }
        }
        return states
    }

    /// 显示名 → 检测端点 key（纯函数，显式 nonisolated 防并发闭包隔离推断误判）
    private nonisolated static func key(for display: String) -> String {
        switch display {
        case "Fabric": return "fabric"
        case "Forge": return "forge"
        case "NeoForged": return "neoforge"
        case "Quilt": return "quilt"
        default: return display.lowercased()
        }
    }

    /// 检查单个加载器对某版本是否可用：单请求（4s 超时）；双源加载器 700ms 延迟并发备用源。
    /// 结论语义：权威源 404/410/空数组 = 明确不支持（notSupported）；网络错误或 5xx = failed（结果未知）。
    /// 快照版本的结果一律视为未知（notSupported 结论不适用于未列出的实验版本）。
    private static func checkLoaderSupport(key: String, version: String) async -> LoaderCheckResult {
        let encoded = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version
        var urls: [(URL, Bool)] = []   // (url, 空结果是否权威：官方源权威，镜像非权威不误伤)
        switch key {
        case "fabric":
            urls = [
                (URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(encoded)")!, true),
                (URL(string: "https://bmclapi2.bangbang93.com/fabric-meta/v2/versions/loader/\(encoded)")!, false)
            ]
        case "forge":
            urls = [(URL(string: "https://bmclapi2.bangbang93.com/forge/minecraft/\(encoded)")!, true)]
        case "neoforge":
            urls = [(URL(string: "https://bmclapi2.bangbang93.com/neoforge/list/\(encoded)")!, true)]
        case "quilt":
            urls = [
                (URL(string: "https://meta.quiltmc.org/v3/versions/loader/\(encoded)")!, true),
                (URL(string: "https://bmclapi2.bangbang93.com/quilt-meta/v3/versions/loader/\(encoded)")!, false)
            ]
        default:
            return .notSupported
        }
        guard !urls.isEmpty else { return .notSupported }

        if urls.count == 1 {
            return await requestOnce(url: urls[0].0, authoritativeEmpty: urls[0].1, key: key, version: version)
        }

        // 双源：主源立即请求；700ms 后主源仍无结论则并行发起备用源（不等主源完整超时）。
        // 任意源 supported / 权威 notSupported → 立即定论（withTaskGroup 离开时自动取消未完成 child）
        return await withTaskGroup(of: LoaderCheckResult.self) { group in
            group.addTask {
                await requestOnce(url: urls[0].0, authoritativeEmpty: urls[0].1, key: key, version: version)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return .failed }
                return await requestOnce(url: urls[1].0, authoritativeEmpty: urls[1].1, key: key, version: version)
            }
            for await result in group {
                switch result {
                case .supported: return .supported
                case .notSupported: return .notSupported
                case .failed: break
                }
            }
            return .failed
        }
    }

    /// 单次请求（不重试）：200 + 非空数组 = supported（并缓存响应数组）；权威源 4xx/空数组 = notSupported；
    /// 网络错误/5xx/镜像空结果 = failed（结果未知，绝不误判「不支持」）
    private static func requestOnce(url: URL, authoritativeEmpty: Bool, key: String, version: String) async -> LoaderCheckResult {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await metaSession.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // 仅 404/410 = 权威「不存在」；401/403/408/429 等均是鉴权、超时或限流，
                // 必须视为 unavailable，绝不能缓存成「不支持」。
                if (http.statusCode == 404 || http.statusCode == 410), authoritativeEmpty {
                    return isSnapshotVersion(version) ? .failed : .notSupported
                }
                return .failed
            }
            guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else { return .failed }
            if array.isEmpty {
                if authoritativeEmpty {
                    return isSnapshotVersion(version) ? .failed : .notSupported
                }
                return .failed
            }
            storeVersionList(loader: key, mc: version, data: data)
            return .supported
        } catch {
            return .failed
        }
    }
}
