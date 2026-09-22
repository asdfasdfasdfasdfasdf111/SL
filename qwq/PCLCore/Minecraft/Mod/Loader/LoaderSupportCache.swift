//
//  LoaderSupportCache.swift
//  PCL.Mac
//
//  加载器支持检测的缓存层（从 LoaderSupportChecker.swift 逐字搬移，逻辑、常量与文案未变）：
//  - 内存缓存 + 磁盘缓存（`SL启动器/LoaderSupportCache.json`）的读写与 TTL 过滤
//  - 单加载器定论写入（内存与磁盘分别持锁，磁盘走串行化读-改-写）
//  - 对外同步查询：cachedLoaderStates / cachedLoaders
//

import Foundation

extension LoaderSupportChecker {

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

    // MARK: - 延迟批量刷盘（消除写放大）
    //
    // 原 `writeEntry` 每次都「整文件读 + 整文件写」：一次 18 个版本的批量探测会产生
    // 十几次全量磁盘 IO。现改为：内存立即更新 + 结论并入 `pendingDisk` 累积缓冲，
    // 由 debounce（scheduleFlush）在空闲后合并为「1 次读 + 1 次写」。
    // 语义保证：内存结论在 writeEntry 内同步生效，pendingDisk 在刷盘前已含全部已得结论，
    // 进程内查询与改前一致；刷盘后磁盘内容与改前一致（缓存丢了只是重新探测，不会误判）。

    /// 待刷盘累积缓冲。本类型整体主 actor 隔离，flush 任务也排到主队列执行，
    /// 所有访问都发生在主 actor 上，故无需 `nonisolated`。
    private static var pendingDisk: [String: [String: LoaderCacheEntry]]? = nil
    /// debounce 的刷盘任务（取消旧任务以合并多次写入）
    private static var flushTask: DispatchWorkItem? = nil
    /// 末次写入后多久刷盘（秒）。批量探测期间多次 writeEntry 会不断重置该窗口，
    /// 探测结束空闲后即合并为一次写盘。
    private static let flushDebounceInterval: TimeInterval = 0.5

    /// 安排一次延迟合并刷盘：取消上一次未触发的任务并重新计时。
    private static func scheduleFlush() {
        flushTask?.cancel()
        let snapshot = pendingDisk ?? [:]
        let task = DispatchWorkItem { [snapshot] in
            saveDiskCache(snapshot)
        }
        flushTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + flushDebounceInterval, execute: task)
    }

    /// 显式立即刷盘（供探测层在批量结束后调用，保证「正常退出/显式 flush 后磁盘内容一致」）。
    /// 仅当确有累积结论时才写盘，避免用空缓冲覆盖已存在的磁盘缓存。
    static func flushLoaderSupportCache() {
        flushTask?.cancel()
        flushTask = nil
        guard let snapshot = pendingDisk else { return }
        saveDiskCache(snapshot)
    }

    /// 单加载器定论写入：内存（cacheLock 内）立即生效 + 磁盘结论并入 pendingDisk（diskLock 内），
    /// 由 debounce 合并刷盘（防并发丢更新、消除写放大）。访问级别为 internal：探测层
    /// （LoaderSupportProbe.swift）定论后调用。
    static func writeEntry(version: String, loader: String, state: LoaderState) {
        let entry = LoaderCacheEntry(state: state == .supported ? "supported" : "notSupported", t: Date().timeIntervalSince1970)
        cacheLock.lock()
        if memoryCache[version] == nil { memoryCache[version] = [:] }
        memoryCache[version]?[loader] = entry
        cacheLock.unlock()

        // 磁盘写入延迟合并：只把本结论并入 pendingDisk 累积缓冲，由 scheduleFlush 在空闲后
        // 统一刷盘。内存结论立即生效，pendingDisk 在刷盘前已含全部已得结论，故进程内查询与改前
        // 语义一致；磁盘最终内容也与改前一致。
        diskLock.lock()
        defer { diskLock.unlock() }
        if pendingDisk == nil { pendingDisk = loadDiskCache() ?? [:] }
        // pendingDisk 此刻必非 nil（上方已兜底），但它是可选类型，需解包后按字典操作
        var disk = pendingDisk!
        if disk[version] == nil { disk[version] = [:] }
        disk[version]?[loader] = entry
        pendingDisk = disk
        scheduleFlush()
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

    /// 清空内存缓存与磁盘缓存句柄（供 LoaderSupportChecker.clearMemoryCache 调用）
    static func clearCacheStorage() {
        cacheLock.lock()
        memoryCache = [:]
        diskCache = nil
        cacheLock.unlock()
        // 清掉待刷盘缓冲并取消未触发的刷盘，避免随后一次 flush 把刚清掉的旧结论写回磁盘
        flushTask?.cancel()
        flushTask = nil
        pendingDisk = nil
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
    ///
    /// 调用点在另一个文件的 `LoaderSupportState.swift` 的 `supportedLoaders(for:)` 内
    /// （约 `qwq/PCLCore/Minecraft/Mod/Loader/LoaderSupportState.swift:57` 与 `:66`）；
    /// 后者（`LoaderSupportState.supportedLoaders(for:)`）自身已无调用方、标注待清理，
    /// 故本方法实际也已无有效调用方。此处用注释而非 `@available` 标注 ——
    /// 加 `@available` 会让上述调用点新增编译告警，故保持文案一致的注释。
    public static func cachedLoaders(for version: String) -> [String]? {
        guard let states = cachedLoaderStates(for: version) else { return nil }
        return states.compactMap { $0.value == .supported ? $0.key : nil }.sorted { orderIndex($0) < orderIndex($1) }
    }
}
