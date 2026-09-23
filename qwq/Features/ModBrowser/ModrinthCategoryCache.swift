import Foundation

// MARK: - Modrinth 分类缓存（内存 + 磁盘两级，自 GameViews 拆出）
//
//  ⚠️ 全部状态是 **static var**（全局可变、无锁）—— 读写都假定在主线程。
//  任何后台线程调 `setCache` / `clearAll` / `loadFromDisk` 都是数据竞争。
//
//  ⚠️ 磁盘那一级只存四类**内容列表**（mod / resourcepack / shader / modpack），
//  游戏版本清单（`.game`）**只走内存**、没有磁盘键 —— 见 `diskKey(for:)` 的 nil 分支。

/// 分类列表的两级缓存（全局静态状态，无实例）。
enum ModrinthCategoryCache {
    // 内存缓存（切换分类/翻页期间避免重复请求）。
    // ⚠️ nil 与空数组含义不同：nil = 「这一屏还没拉过」，[] = 「拉过但确实没有结果」。
    static var cachedModItems: [DownloadedItem]?
    static var cachedResourcePackItems: [DownloadedItem]?
    static var cachedShaderItems: [DownloadedItem]?
    static var cachedModpackItems: [DownloadedItem]?
    // 游戏版本清单缓存（按子分类：release/snapshot/ancient）
    // ⚠️ 下面两个字段必须**成对解读**：`cachedGameVersions` 自己不记录「这是哪个子分类的」，
    // 靠 `lastGameSubCategory` 标记。换子分类后若只看前者，会拿到别的分类的列表。
    static var cachedGameVersions: [DownloadedItem]?
    static var lastGameSubCategory: GameSubCategory?

    /// 先展示版本缓存，随后由 GameVersionManifest 后台刷新。
    /// ⚠️ `sub` 与 `lastGameSubCategory` 同时为 nil 也算相等 ——
    /// 「从未选择过子分类」会命中缓存（此时缓存大概率为空，副作用有限）。
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

    /// 按分类取内存缓存。游戏分类额外要求子分类一致（见 `cachedGameVersions(for:)`）。
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

    /// 按分类写内存缓存（统一写入口，消除四处重复赋值）。
    /// ⚠️ 写 `.game` 时**不会**更新 `lastGameSubCategory` —— 那个标记仍由调用方另行维护，
    /// 忘记更新会让 `cachedGameVersions(for:)` 拿旧子分类去比对而漏命中。
    static func setCache(_ items: [DownloadedItem], for section: GameSidebarSection) {
        switch section {
        case .game: cachedGameVersions = items
        case .mod: cachedModItems = items
        case .resourcePack: cachedResourcePackItems = items
        case .shader: cachedShaderItems = items
        case .modpack: cachedModpackItems = items
        }
    }

    /// 分类 → 磁盘缓存键（游戏版本清单走内存缓存，无磁盘键）。
    /// ⚠️ `.game` 返回 nil 是设计如此：版本清单变动频繁、体积大，不值得落盘。
    static func diskKey(for section: GameSidebarSection) -> CacheKey? {
        switch section {
        case .mod: return .mod
        case .resourcePack: return .resourcePack
        case .shader: return .shader
        case .modpack: return .modpack
        case .game: return nil
        }
    }

    /// 清空内存缓存（内存警告时调用）。
    /// ⚠️ **不动磁盘缓存** —— 下次 `loadFromDisk()` 会把它们原样读回来。
    static func clearAll() {
        cachedModItems = nil
        cachedResourcePackItems = nil
        cachedShaderItems = nil
        cachedModpackItems = nil
        cachedGameVersions = nil
        lastGameSubCategory = nil
    }

    /// 启动时从磁盘读一次，填充内存缓存。
    /// ⚠️ 只覆盖四类内容列表，**不含** `cachedGameVersions`（版本清单不落盘）。
    static func loadFromDisk() {
        let cache = AppContext.shared.cacheManager
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

    /// 拉取成功后写回磁盘缓存。
    /// ⚠️ **只写磁盘、不更新内存** —— 想让内存缓存同步生效，调用方必须另外调 `setCache`。
    static func saveToDisk(_ items: [DownloadedItem], for key: CacheKey) {
        AppContext.shared.cacheManager.setObject(items, forKey: key.rawValue)
    }
}
