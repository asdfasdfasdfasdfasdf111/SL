//
//  LocalModCatalog.swift
//  模块化拆分：本地 Modrinth 全量目录（从 GameViews.swift 拆出）
//  crawl_modrinth.py 生成的 modrinth_catalog.json.gz（mod/resourcepack/shader/modpack 全部条目，不翻译）
//  解析 + gzip → 磁盘缓存二次秒开 + 后台预热 + 搜索翻译预取
//

import Foundation
import zlib
import os

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

    /// 目录内存锁（保护 `localCatalog` / `localCatalogItemsByType`，临界区只做字典读写）。
    ///
    /// 显式 `nonisolated`：工程启用 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，未标注的
    /// 静态成员会被推断为 `@MainActor`；本锁同时被后台预热路径（`Task.detached` 内的
    /// `items(for:)` / `loadCatalog()`）使用，必须能在主 actor 之外访问。
    /// 依据：《Concurrency》Nonstructured Concurrency —— `Task.detached` 不继承任何 actor 隔离，
    /// 其闭包内不得同步访问主 actor 隔离的静态成员。
    /// 依据：《Concurrency》Sendable Types —— 无可变状态、由其它并发安全数据构成的类型可跨并发域共享；
    /// 本锁自身的可变状态由锁自身串行化，不依赖主 actor。
    /// 官方链接：
    ///   https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
    ///   https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    private nonisolated static let localCatalogLock = NSLock()
    private nonisolated(unsafe) static var localCatalog: [Item]?
    private nonisolated(unsafe) static var localCatalogItemsByType: [String: [DownloadedItem]] = [:]
    /// 本地全量目录是否已在后台解析完成。主线程只在它为 true 时才调用 items，
    /// 从而杜绝「切到 mod 页时主线程同步读盘+解压 12 万条目录 → 卡死/动画丢失/翻译失效」。
    ///
    /// 该标志由 `Task.detached` 后台写入、由主线程渲染路径读取，因此不再用裸 `var` 承接，
    /// 改由 `OSAllocatedUnfairLock` 承载：它是 Sendable 的引用类型，其 `withLock` 属于
    /// async 安全的「作用域加锁」。原有的 `NSLock.lock()` / `unlock()` 在新版 SDK 中被标注
    /// `noasync`，在 async 闭包内直接调用会产生「unavailable from asynchronous contexts」
    /// 告警，并在 Swift 6 语言模式下升级为错误。
    ///
    /// 显式标注 `nonisolated`：工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 未标注隔离的静态成员会被推断为 `@MainActor`；本属性必须能被 `Task.detached` 的
    /// 后台上下文访问，且其自身是 Sendable 不可变引用，不需要主 actor 保护。
    private nonisolated static let localCatalogReadyState = OSAllocatedUnfairLock(initialState: false)
    /// 本地目录解析完成通知（用于让已显示的 mod 页自动刷新为全量本地目录）
    static let readyNotification = Notification.Name("localCatalogReady")

    /// 本地目录是否已解析完成（主线程据此决定是否直接走全量目录模式）
    static var isReady: Bool {
        localCatalogReadyState.withLock { $0 }
    }

    /// 应用启动时预热本地全量目录（对应 PCL 的 PageLoaderInit：在用户打开下载页之前就后台解析，
    /// 让 mod/资源包/光影/整合包页首帧即有数据，消除「空白→填充」的延迟感）
    static func warmUp() {
        preload()
    }

    /// 按分类返回本地全量条目（首次按类型映射缓存，线程安全）
    ///
    /// 显式 `nonisolated`：四类调用者中，`preload()` 的 `Task.detached` 预热路径位于主 actor 之外；
    /// 实现只做「加锁查内存缓存 → 读本地目录 → 建映射」，返回值是纯值类型，不触碰 UI / AppKit 状态，
    /// 因此不需要主 actor 保护。
    /// 依据：《Concurrency》Nonstructured Concurrency —— `Task.detached` 不继承任何 actor 隔离。
    /// 依据：SE-0466《Control default actor isolation inference》—— 需要并发时以 `nonisolated` 显式退出默认隔离。
    /// 官方链接：
    ///   https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
    ///   https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    nonisolated static func items(for section: GameSidebarSection) -> [DownloadedItem] {
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
        let ready = localCatalogReadyState.withLock { $0 }
        guard !ready else { return }
        Task.detached(priority: .userInitiated) {
            _ = items(for: .mod)
            _ = items(for: .resourcePack)
            _ = items(for: .shader)
            _ = items(for: .modpack)
            localCatalogReadyState.withLock { $0 = true }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: readyNotification, object: nil)
            }
        }
    }

    /// 搜索翻译预取：后台对四类目录各取前 3 条未翻译项目预热翻译缓存
    ///
    /// 隔离说明：`TranslationService` 受工程默认隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）
    /// 保护，其静态单例与实例方法均为主 actor 隔离，不能在 `Task.detached`（不继承任何 actor 隔离）
    /// 的上下文里同步访问。本方法把重活（Modrinth 搜索网络请求 + JSON 解析）留在后台任务内，
    /// 仅把「缓存判定 + 触发翻译」交给 `@MainActor` 的 `preTranslateOne(projectId:)`。
    /// 依据：《Concurrency》Nonstructured Concurrency（`Task.detached` 不继承任何 actor 隔离）
    ///       + The Main Actor（主 actor 隔离成员只能由主 actor 代码同步调用，非主 actor 需 `await` 切换）。
    /// 官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
    static func preTranslateAll() {
        Task.detached(priority: .background) {
            let categories: [(String, String)] = [
                ("mod", "模组"), ("resourcepack", "资源包"),
                ("shader", "光影"), ("modpack", "整合包")
            ]
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
                    guard !projectId.isEmpty else { continue }
                    // 切到主 actor 完成缓存判定与翻译触发；不把非 Sendable 的 TranslationService
                    // 引用带出隔离域，因此该步骤不返回实例
                    await preTranslateOne(projectId: projectId)
                }
            }
        }
    }

    /// 单条翻译预热：缓存判定 + 触发翻译。
    ///
    /// 显式 `@MainActor`：`TranslationService` 及其依赖的 `CacheManager` 均由工程默认隔离推断为
    /// 主 actor 隔离，其同步成员（`cachedTranslation(for:)`）只能在主 actor 上调用；本方法把需要在
    /// 主 actor 上完成的一小段逻辑收敛于此，网络等重活仍留在 `preTranslateAll()` 的后台任务内。
    /// 依据：《Concurrency》The Main Actor —— `@MainActor func` 只在主 actor 上运行，
    /// 从非主 actor 代码调用必须 `await`（切换到主 actor 引入潜在挂起点）。
    /// 官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
    @MainActor
    private static func preTranslateOne(projectId: String) async {
        guard TranslationService.shared.cachedTranslation(for: projectId) == nil else { return }
        _ = try? await TranslationService.shared.translateText(text: "", projectId: projectId)
    }

    // MARK: - 目录解析（bundle gzip → 内存 → 磁盘缓存）

    /// 从 bundle 读取 modrinth_catalog.json.gz 并解析（全量目录缓存）。
    /// 优先复用解析结果的磁盘缓存，避免每次冷启动都重新解压 12 万条 gzip。
    ///
    /// 临界区约定：`localCatalogLock` 只保护 `localCatalog` 的「读—判—写」，
    /// 最后一次赋值用锁，解压与解析全程在锁外；与 `items(for:)` 的双重检查模式一致。
    ///
    /// 显式 `nonisolated`：由 `preload()`（`Task.detached`）与 `items(for:)` 共同调用，
    /// 实现全部是本地文件 / gzip / JSON 解析，属纯 CPU+IO，与主 actor 状态无关；
    /// 内部写回磁盘缓存的 `Task.detached` 也据此无需回主 actor。
    /// 依据：《Concurrency》Nonstructured Concurrency + SE-0466。
    /// 官方链接：
    ///   https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
    ///   https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    nonisolated static func loadCatalog() -> [Item] {
        // 快路径：临界区内只做一次「读已解析结果」，不持锁做任何 IO / CPU 重活。
        localCatalogLock.lock()
        let cached = localCatalog
        localCatalogLock.unlock()
        if let cached { return cached }

        // 耗时工作全部放在临界区之外：读磁盘缓存、解压 gzip、解析 12 万条 JSON。
        // 旧实现把这一整段（含 Data(contentsOf:) 与 inflate）放在锁内，期间 items(for:)
        // 及其它访问者全部排队等待；现在锁只在最后赋值时短暂持有。
        // 代价：并发调用可能重复解析（多算一次、结果丢弃），换取的是临界区从「秒级」降到「µs 级」。
        let catalog: [Item]
        let parsedFromBundle: Bool
        // 1) 复用解析结果磁盘缓存（二次冷启动秒开）
        if let fromDisk = loadCatalogFromDisk() {
            catalog = fromDisk
            parsedFromBundle = false
        // 2) 冷启动：从 bundle 的 gzip 解析
        } else if let url = Bundle.main.url(forResource: "modrinth_catalog", withExtension: "json.gz"),
                  let compressed = try? Data(contentsOf: url),
                  let data = inflateGzipData(compressed),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["items"] as? [[String: Any]] {
            catalog = entries.compactMap { entry -> Item? in
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
            parsedFromBundle = true
        } else {
            // 解析/读缓存失败：不写 localCatalog，保留「下次调用可重试」的旧语义
            return []
        }

        // 临界区：只做赋值。并发下的重复解析结果一律丢弃、先到者胜，
        // 与旧实现在锁内「先查后写」的可观察语义一致，也与 items(for:) 的双重检查写法保持一致。
        localCatalogLock.lock()
        if let existing = localCatalog {
            localCatalogLock.unlock()
            return existing
        }
        localCatalog = catalog
        localCatalogLock.unlock()

        // 3) 异步写回磁盘缓存，供下次冷启动秒开。仅由「结果真正被采用」的那次调用发起，
        // 并发重复解析的落败者不再重复写盘（写盘内容相同，观察结果不变）。
        if parsedFromBundle {
            Task.detached(priority: .utility) { saveCatalogToDisk(catalog) }
        }
        return catalog
    }

    /// 解压 gzip 数据（系统 libz，windowBits=31 支持 gzip 格式）
    ///
    /// 显式 `nonisolated`：与 `loadCatalog()` 同属非主 actor 的解析链路，只做 C 库解压，无隔离状态。
    /// 官方链接：https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    private nonisolated static func inflateGzipData(_ input: Data) -> Data? {
        // 空 Data 时 withUnsafeBytes 的 baseAddress 为 nil，下方强解包会崩溃（bundle 资源被截断/损坏为 0 字节时触发）
        guard !input.isEmpty else { return nil }
        return input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data? in
            let src = srcRaw.bindMemory(to: UInt8.self)
            var stream = z_stream()
            guard let srcBase = src.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcBase)
            stream.avail_in = uInt(input.count)
            guard inflateInit2_(&stream, 16 + 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            var output = Data()
            let buffer = [UInt8](repeating: 0, count: 1 << 16)
            var lastStatus: Int32 = Z_OK
            while true {
                var localBuffer = buffer
                let produced = localBuffer.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
                    guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    stream.next_out = dstBase
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
    ///
    /// 显式 `nonisolated`：仅拼接「缓存目录」路径，无隔离状态；
    /// 供非主 actor 的 `loadCatalog()` / `saveCatalogToDisk(_:)` 复用。
    /// 官方链接：https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    private nonisolated static func catalogCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("modrinth_local_catalog_v1.json")
    }

    /// 缓存是否仍有效：bundle 内的 gzip 源比磁盘缓存新则视为过期需重解
    ///
    /// 显式 `nonisolated`：只比较两个文件的时间戳，无隔离状态。
    /// 官方链接：https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    private nonisolated static func isCatalogCacheFresh() -> Bool {
        guard let gzURL = Bundle.main.url(forResource: "modrinth_catalog", withExtension: "json.gz"),
              let cacheURL = catalogCacheURL() else { return false }
        let fm = FileManager.default
        let gzDate = (try? fm.attributesOfItem(atPath: gzURL.path)[.modificationDate] as? Date) ?? .distantPast
        let cacheDate = (try? fm.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date) ?? .distantPast
        return cacheDate >= gzDate
    }

    /// 显式 `nonisolated`：只读磁盘缓存文件并解码，无隔离状态。
    /// 官方链接：https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    private nonisolated static func loadCatalogFromDisk() -> [Item]? {
        guard isCatalogCacheFresh(),
              let url = catalogCacheURL(),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Item].self, from: data),
              !items.isEmpty else { return nil }
        return items
    }

    /// 显式 `nonisolated`：由 `loadCatalog()` 内的 `Task.detached(priority: .utility)` 调用，
    /// 只做 JSON 编码 + 原子写盘；参数 `[Item]` 是纯值类型，不涉及主 actor 状态。
    /// 依据：《Concurrency》Nonstructured Concurrency —— `Task.detached` 不继承任何 actor 隔离。
    /// 官方链接：
    ///   https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
    ///   https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md
    private nonisolated static func saveCatalogToDisk(_ items: [Item]) {
        guard let url = catalogCacheURL() else { return }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
