//
//  LocalModCatalog.swift
//  模块化拆分：本地 Modrinth 全量目录（从 GameViews.swift 拆出）
//  crawl_modrinth.py 生成的 modrinth_catalog.json.gz（mod/resourcepack/shader/modpack 全部条目，不翻译）
//  解析 + gzip → 磁盘缓存二次秒开 + 后台预热 + 搜索翻译预取
//

import Foundation
import zlib

enum LocalModCatalog {

    struct Item: Codable {
        let projectID: String
        let projectType: String
        let title: String
        let description: String
        let categories: [String]
        let iconURL: String?
        let downloads: Int
    }

    private nonisolated(unsafe) static let localCatalogLock = NSLock()
    private nonisolated(unsafe) static var localCatalog: [Item]?
    private nonisolated(unsafe) static var localCatalogItemsByType: [String: [DownloadedItem]] = [:]
    /// 本地全量目录是否已在后台解析完成。主线程只在它为 true 时才调用 items，
    /// 从而杜绝「切到 mod 页时主线程同步读盘+解压 12 万条目录 → 卡死/动画丢失/翻译失效」。
    private nonisolated(unsafe) static var localCatalogReady = false
    /// 本地目录解析完成通知（用于让已显示的 mod 页自动刷新为全量本地目录）
    static let readyNotification = Notification.Name("localCatalogReady")

    /// 本地目录是否已解析完成（主线程据此决定是否直接走全量目录模式）
    static var isReady: Bool { localCatalogReady }

    /// 应用启动时预热本地全量目录（对应 PCL 的 PageLoaderInit：在用户打开下载页之前就后台解析，
    /// 让 mod/资源包/光影/整合包页首帧即有数据，消除「空白→填充」的延迟感）
    static func warmUp() {
        preload()
    }

    /// 按分类返回本地全量条目（首次按类型映射缓存，线程安全）
    static func items(for section: GameSidebarSection) -> [DownloadedItem] {
        let type: String
        switch section {
        case .mod: type = "mod"
        case .resourcePack: type = "resourcepack"
        case .shader: type = "shader"
        case .modpack: type = "modpack"
        default: return []
        }
        localCatalogLock.lock()
        if let cached = localCatalogItemsByType[type] {
            localCatalogLock.unlock()
            return cached
        }
        localCatalogLock.unlock()
        let catalog = loadCatalog()
        guard !catalog.isEmpty else { return [] }
        let mapped = catalog
            .filter { $0.projectType == type }
            .map {
                DownloadedItem(
                    id: $0.projectID,
                    name: $0.title,
                    subtitle: $0.description,
                    iconURL: $0.iconURL,
                    tags: $0.categories
                )
            }
        localCatalogLock.lock()
        if let existing = localCatalogItemsByType[type] {
            localCatalogLock.unlock()
            return existing
        }
        localCatalogItemsByType[type] = mapped
        localCatalogLock.unlock()
        return mapped
    }

    // MARK: - 后台预热与翻译预取

    /// 后台预加载四类本地目录，避免首次切页时阻塞主线程
    private static func preload() {
        guard !localCatalogReady else { return }
        Task.detached(priority: .userInitiated) {
            _ = items(for: .mod)
            _ = items(for: .resourcePack)
            _ = items(for: .shader)
            _ = items(for: .modpack)
            localCatalogReady = true
            // 本地目录就绪后通知界面：若当前停在 mod/资源包/光影/整合包页，自动刷新为全量本地目录
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: readyNotification, object: nil)
            }
        }
    }

    /// 搜索翻译预取：后台对四类目录各取前 3 条未翻译项目预热翻译缓存
    static func preTranslateAll() {
        Task.detached(priority: .background) {
            let categories: [(String, String)] = [
                ("mod", "模组"), ("resourcepack", "资源包"),
                ("shader", "光影"), ("modpack", "整合包")
            ]
            let service = TranslationService.shared
            for (type, _) in categories {
                if Task.isCancelled { return }
                let facets = "[[\"project_type:\(type)\"]]"
                let encoded = facets.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                guard let url = URL(string: "https://api.modrinth.com/v2/search?query=&limit=10&facets=\(encoded)") else { continue }
                var req = URLRequest(url: url)
                req.setValue("qwq-Launcher/1.0 (qwq@example.com)", forHTTPHeaderField: "User-Agent")
                guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let hits = json["hits"] as? [[String: Any]] else { continue }
                for hit in hits.prefix(3) {
                    if Task.isCancelled { return }
                    let projectId = hit["project_id"] as? String ?? hit["slug"] as? String ?? ""
                    guard !projectId.isEmpty, service.cachedTranslation(for: projectId) == nil else { continue }
                    _ = try? await service.translateText(text: "", projectId: projectId)
                }
            }
        }
    }

    // MARK: - 目录解析（bundle gzip → 内存 → 磁盘缓存）

    /// 从 bundle 读取 modrinth_catalog.json.gz 并解析（全量目录缓存）。
    /// 优先复用解析结果的磁盘缓存，避免每次冷启动都重新解压 12 万条 gzip。
    static func loadCatalog() -> [Item] {
        localCatalogLock.lock()
        defer { localCatalogLock.unlock() }
        if let localCatalog { return localCatalog }

        // 1) 复用解析结果磁盘缓存（二次冷启动秒开）
        if let cached = loadCatalogFromDisk() {
            localCatalog = cached
            return cached
        }

        // 2) 冷启动：从 bundle 的 gzip 解析
        guard let url = Bundle.main.url(forResource: "modrinth_catalog", withExtension: "json.gz"),
              let compressed = try? Data(contentsOf: url),
              let data = inflateGzipData(compressed),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["items"] as? [[String: Any]] else {
            return []
        }
        let catalog = entries.compactMap { entry -> Item? in
            guard let projectID = entry["i"] as? String,
                  let projectType = entry["t"] as? String,
                  let title = entry["n"] as? String else { return nil }
            return Item(
                projectID: projectID,
                projectType: projectType,
                title: title,
                description: entry["d"] as? String ?? "",
                categories: entry["c"] as? [String] ?? [],
                iconURL: entry["u"] as? String,
                downloads: entry["x"] as? Int ?? 0
            )
        }
        localCatalog = catalog
        // 3) 异步写回磁盘缓存，供下次冷启动秒开
        let toCache = catalog
        Task.detached(priority: .utility) { saveCatalogToDisk(toCache) }
        return catalog
    }

    /// 解压 gzip 数据（系统 libz，windowBits=31 支持 gzip 格式）
    private static func inflateGzipData(_ input: Data) -> Data? {
        // 空 Data 时 withUnsafeBytes 的 baseAddress 为 nil，下方强解包会崩溃（bundle 资源被截断/损坏为 0 字节时触发）
        guard !input.isEmpty else { return nil }
        return input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            let src = srcRaw.bindMemory(to: UInt8.self)
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: src.baseAddress!)
            stream.avail_in = uInt(input.count)
            guard inflateInit2_(&stream, 16 + 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            var output = Data()
            let buffer = [UInt8](repeating: 0, count: 1 << 16)
            var lastStatus: Int32 = Z_OK
            while true {
                var localBuffer = buffer
                let produced = localBuffer.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                    stream.next_out = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(buffer.count)
                    lastStatus = inflate(&stream, Z_NO_FLUSH)
                    if lastStatus == Z_OK || lastStatus == Z_STREAM_END {
                        return buffer.count - Int(stream.avail_out)
                    }
                    return -1
                }
                if produced < 0 { return nil }
                if produced > 0 { output.append(localBuffer, count: produced) }
                if lastStatus == Z_STREAM_END { return output }
                if stream.avail_in == 0 && lastStatus == Z_OK { return nil }
            }
        }
    }

    /// 解析结果磁盘缓存路径（参考 PCL 的 Cache\download.json：二次冷启动跳过 gzip 解压，秒级出数据）
    private static func catalogCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("modrinth_local_catalog_v1.json")
    }

    /// 缓存是否仍有效：bundle 内的 gzip 源比磁盘缓存新则视为过期需重解
    private static func isCatalogCacheFresh() -> Bool {
        guard let gzURL = Bundle.main.url(forResource: "modrinth_catalog", withExtension: "json.gz"),
              let cacheURL = catalogCacheURL() else { return false }
        let fm = FileManager.default
        let gzDate = (try? fm.attributesOfItem(atPath: gzURL.path)[.modificationDate] as? Date) ?? .distantPast
        let cacheDate = (try? fm.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date) ?? .distantPast
        return cacheDate >= gzDate
    }

    private static func loadCatalogFromDisk() -> [Item]? {
        guard isCatalogCacheFresh(),
              let url = catalogCacheURL(),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Item].self, from: data),
              !items.isEmpty else { return nil }
        return items
    }

    private static func saveCatalogToDisk(_ items: [Item]) {
        guard let url = catalogCacheURL() else { return }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
