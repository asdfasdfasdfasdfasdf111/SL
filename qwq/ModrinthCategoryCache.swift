import Foundation

// MARK: - Modrinth 分类缓存（内存 + 磁盘两级，自 GameViews 拆出）

enum ModrinthCategoryCache {
    // 内存缓存（切换分类/翻页期间避免重复请求）
    static var cachedModItems: [DownloadedItem]?
    static var cachedResourcePackItems: [DownloadedItem]?
    static var cachedShaderItems: [DownloadedItem]?
    static var cachedModpackItems: [DownloadedItem]?
    // 游戏版本清单缓存（按子分类：release/snapshot/ancient）
    static var cachedGameVersions: [DownloadedItem]?
    static var lastGameSubCategory: GameSubCategory?

    /// 先展示版本缓存，随后由 GameVersionManifest 后台刷新。
    static func cachedGameVersions(for sub: GameSubCategory?) -> [DownloadedItem]? {
        guard sub == lastGameSubCategory else { return nil }
        return cachedGameVersions
    }

    enum CacheKey: String {
        case mod = "modrinth_cache_mod"
        case resourcePack = "modrinth_cache_resourcepack"
        case shader = "modrinth_cache_shader"
        case modpack = "modrinth_cache_modpack"
    }

    /// 按分类取内存缓存
    static func cache(for section: GameSidebarSection, sub: GameSubCategory?) -> [DownloadedItem]? {
        switch section {
        case .game:
            if sub == lastGameSubCategory, let c = cachedGameVersions { return c }
            return nil
        case .mod: return cachedModItems
        case .resourcePack: return cachedResourcePackItems
        case .shader: return cachedShaderItems
        case .modpack: return cachedModpackItems
        }
    }

    /// 按分类写内存缓存（统一写入口，消除四处重复赋值）
    static func setCache(_ items: [DownloadedItem], for section: GameSidebarSection) {
        switch section {
        case .game: cachedGameVersions = items
        case .mod: cachedModItems = items
        case .resourcePack: cachedResourcePackItems = items
        case .shader: cachedShaderItems = items
        case .modpack: cachedModpackItems = items
        }
    }

    /// 分类 → 磁盘缓存键（游戏版本清单走内存缓存，无磁盘键）
    static func diskKey(for section: GameSidebarSection) -> CacheKey? {
        switch section {
        case .mod: return .mod
        case .resourcePack: return .resourcePack
        case .shader: return .shader
        case .modpack: return .modpack
        case .game: return nil
        }
    }

    /// 清空内存缓存（内存警告时调用）
    static func clearAll() {
        cachedModItems = nil
        cachedResourcePackItems = nil
        cachedShaderItems = nil
        cachedModpackItems = nil
        cachedGameVersions = nil
        lastGameSubCategory = nil
    }

    /// 启动时从磁盘读一次，填充内存缓存
    static func loadFromDisk() {
        let cache = AppContext.shared.cacheManager
        let decoder = JSONDecoder()
        for key in [CacheKey.mod, .resourcePack, .shader, .modpack] {
            guard let items: [DownloadedItem] = cache.object([DownloadedItem].self, forKey: key.rawValue) else { continue }
            switch key {
            case .mod: cachedModItems = items
            case .resourcePack: cachedResourcePackItems = items
            case .shader: cachedShaderItems = items
            case .modpack: cachedModpackItems = items
            }
        }
    }

    /// 拉取成功后写回磁盘缓存
    static func saveToDisk(_ items: [DownloadedItem], for key: CacheKey) {
        AppContext.shared.cacheManager.setObject(items, forKey: key.rawValue)
    }
}
