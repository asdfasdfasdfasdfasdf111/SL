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
/// 3. 联网并发检测（4 加载器 × 多端点 × 3 重试，30s 超时 + 自定义 UA）：失败回退磁盘旧缓存（即使已过期）
public enum LoaderSupportChecker {

    /// 显示名排序（Fabric → Forge → NeoForged → Quilt）
    public static let loaderOrder = ["Fabric", "Forge", "NeoForged", "Quilt"]

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

    /// 获取某游戏版本支持的加载器显示名列表（已按 loaderOrder 排序）。
    /// 命中任意缓存立即返回；未命中则联网检测，失败时回退磁盘旧缓存（保证「立刻可用」而非空白等待）。
    public static func supportedLoaders(for version: String) async -> [String] {
        if let cached = cachedLoaders(for: version) { return cached }

        // 联网并发检测
        let detected = await detectLoaders(for: version)
        if !detected.isEmpty {
            cacheLock.lock()
            memoryCache[version] = detected
            cacheLock.unlock()
            var disk = readDiskCache() ?? [:]
            disk[version] = detected
            writeDiskCache(disk)
            return detected
        }

        // 4. 联网全部失败：回退磁盘旧缓存（即使已过期）
        if let disk = readDiskCache(), let cached = disk[version] {
            cacheLock.lock()
            memoryCache[version] = cached
            cacheLock.unlock()
            return cached
        }
        return []
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

    // MARK: - 网络检测

    /// 并发检测 4 种加载器支持情况
    private static func detectLoaders(for version: String) async -> [String] {
        let candidates: [(key: String, display: String)] = [
            ("fabric", "Fabric"),
            ("forge", "Forge"),
            ("neoforge", "NeoForged"),
            ("quilt", "Quilt")
        ]
        var supported: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for candidate in candidates {
                group.addTask {
                    let ok = await checkLoaderSupport(key: candidate.key, version: version)
                    return (candidate.display, ok)
                }
            }
            for await (display, ok) in group where ok {
                supported.append(display)
            }
        }
        supported.sort {
            (loaderOrder.firstIndex(of: $0) ?? 99) < (loaderOrder.firstIndex(of: $1) ?? 99)
        }
        return supported
    }

    /// 检查单个加载器对某版本是否可用：多端点逐个尝试，每端点最多重试 2 次，
    /// 只要任意一次返回非空数组即视为支持。加载器 API（bmclapi / quilt meta）
    /// 高峰期不稳定，参考 PCL.Mac 不设过短超时。
    private static func checkLoaderSupport(key: String, version: String) async -> Bool {
        let encoded = version.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? version
        var urls: [URL] = []
        switch key {
        case "fabric":
            urls = [URL(string: "https://bmclapi2.bangbang93.com/fabric-meta/v2/versions/loader/\(encoded)")].compactMap { $0 }
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
        guard !urls.isEmpty else { return false }

        for url in urls {
            for attempt in 0..<3 {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
                // 独立于 apiSession 的较长超时（30s 请求 / 45s 资源），容忍慢速响应
                let cfg = URLSessionConfiguration.ephemeral
                cfg.timeoutIntervalForRequest = 30
                cfg.timeoutIntervalForResource = 45
                cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: cfg)
                do {
                    let (data, resp) = try await session.data(for: req)
                    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        if attempt < 2 { try? await Task.sleep(nanoseconds: 600_000_000) }
                        continue
                    }
                    // Fabric/Quilt meta 返回「loader 数组」；Forge 返回版本数组；NeoForge list 返回数组
                    guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                        if attempt < 2 { try? await Task.sleep(nanoseconds: 600_000_000) }
                        continue
                    }
                    return !array.isEmpty
                } catch {
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        continue
                    }
                }
            }
        }
        return false
    }
}
