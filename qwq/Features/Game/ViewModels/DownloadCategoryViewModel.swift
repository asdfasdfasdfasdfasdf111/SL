//
//  DownloadCategoryViewModel.swift
//  模块化收口：下载分类页（DownloadCategoryView）的状态与业务决策唯一持有者。
//
//  收口范围（对标 ContentView → NavigationState / HomeInteractionState / DropInstallCoordinator）：
//  - 持有侧边栏选中态、列表数据、搜索与分页、详情页选中态；
//  - 承担数据来源决策（本地全量目录 / 游戏版本清单 / Modrinth 检索）、搜索过滤决策树、
//    分页决策、请求归属校验，以及游戏版本清单 → 列表项的转换；
//  - 版本清单取数与分类规则分别委托 Game 模块的 `VersionCatalogService` 与
//    `VersionFilterUseCase`（Features/Game/Module/），本视图层不再直接触碰 `GameVersionManifest`。
//
//  刻意留在视图层的部分：
//  - 布局计算（GeometryReader 列宽/卡片宽）、滚动网格、所有 withAnimation 调用与动画参数；
//  - 侧边栏高亮 y 偏移（SidebarHighlight.offsets）、子项弹入透明度、内容淡入淡出等
//    纯视图坐标与视觉状态；
//  - 翻译状态对象 `CardTranslationModel`（视图以 @StateObject 持有，本视图模型按需接收其引用
//    以调度预取，不接管其生命周期与订阅）。
//
//  线程约定：与收口前一致——所有异步回写都经 `MainActor.run`，派生状态刷新延迟到渲染事务外执行。
//
//  隔离标注说明：本类型标注 `@MainActor`，与 `NavigationState`（App/ViewModels）一致。
//  收口前这些决策方法位于 `DownloadCategoryView`，而 `View` 协议带全局 actor 标注，
//  遵循类型会被推断为同一 actor 隔离，故标注后隔离语义与收口前相同；
//  这同时满足对 `CardTranslationModel`（`@MainActor` 类型）同步调用 `prefetch` 的要求。
//
//  依据条目：SwiftUI《View》/ Swift《Attributes》——被全局 actor 标注的协议，
//  其遵循类型推断为该 actor 隔离。
//  官方链接：https://developer.apple.com/documentation/swiftui/view
//  官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/
//

import SwiftUI
import Combine

@MainActor
final class DownloadCategoryViewModel: ObservableObject {

    // MARK: - 依赖

    /// 版本清单取数（默认接默认实现：模块未接线，与 ModBrowserModule 未接线前做法一致）
    private let versionCatalog: VersionCatalogService

    /// 版本分类过滤
    private let versionFilter: VersionFilterUseCase

    init(versionCatalog: VersionCatalogService = DefaultVersionCatalogService(),
         versionFilter: VersionFilterUseCase = VersionFilterUseCase()) {
        self.versionCatalog = versionCatalog
        self.versionFilter = versionFilter
    }

    // MARK: - 选中态

    @Published var selectedSection: GameSidebarSection = .game
    @Published var selectedSubCategory: GameSubCategory? = .release

    /// 详情页进入前置加载器（Sodium/Iris）前的分类，返回时恢复侧栏高亮
    @Published var pendingReturnSection: GameSidebarSection? = nil

    // MARK: - 列表数据

    @Published private(set) var items: [DownloadedItem] = []
    @Published private(set) var filteredResults: [DownloadedItem] = []
    @Published private(set) var isLoading = false

    /// 列表分页展示上限（CategoryResultsGrid 双向绑定）
    @Published var displayLimit = 120

    // MARK: - 搜索

    @Published var searchText = ""

    /// 与收口前一致：仅写入、无读取点（历史遗留字段，保持原状不删除）
    private var debouncedSearchText = ""
    private var searchDebounceTask: Task<Void, Never>?

    /// 与收口前一致：仅写入、无读取点（结果网格迁到 CategoryResultsGrid 后弹入动画未回接）
    private var searchPopInIds: Set<String> = []

    // MARK: - 分页

    private var currentOffset = 0
    private var hasMore = true
    private var isLoadingMore = false
    private var activeSearchQuery = ""

    // MARK: - 请求归属

    private var fetchTask: Task<Void, Never>?

    /// 请求归属令牌：每次 fetchItems 递增，迟到任务写回前校验 token 不一致即丢弃。
    /// 仅靠 cancel()+isCancelled 存在竞态窗口（旧任务已通过 isCancelled 检查、新任务已启动），
    /// 归属校验保证旧结果绝不覆盖新列表（崩溃 #4 教训的通用化）
    private var fetchToken = 0

    /// 视图存活标记（onAppear/onDisappear 联动，异步回调据此判断是否继续写回）
    private var isViewActive = false

    // MARK: - 派生展示值

    /// 分类页标题：游戏分类下显示子分类名，其余显示分类名
    var displayTitle: String {
        if selectedSection == .game, let sub = selectedSubCategory {
            return sub.rawValue
        }
        return selectedSection.rawValue
    }

    /// 详情页类型（分类 → 详情页形态）
    var currentDetailPageType: DetailPageType {
        switch selectedSection {
        case .resourcePack:
            return .resourcePack
        case .mod:
            return .mod
        case .shader:
            return .shader
        case .modpack:
            return .modpack
        case .game:
            return .loaderSelector
        }
    }

    /// 与收口前一致：详情页渲染以 selectedModItem 非空为准，本标记仅写入、无读取点
    @Published var showDetail = false

    /// 当前打开的详情项
    @Published var selectedModItem: DownloadedItem? = nil

    // MARK: - 生命周期

    /// 视图出现：允许异步回调写回
    func activate() {
        isViewActive = true
    }

    /// 视图消失：禁止异步回调写回并取消在途请求
    /// （语句顺序与收口前 onDisappear 一致：先置存活标记，再取消两个任务）
    func deactivate() {
        isViewActive = false
        fetchTask?.cancel()
        searchDebounceTask?.cancel()
    }

    // MARK: - 选中态变更

    /// 切换分类/子分类的状态重置。
    ///
    /// 只做重置与清理，**不触发请求**：收口前 selectSection 的语句顺序是
    /// 「重置 → 侧栏高亮位移 → 内容淡出 → 发起请求」，
    /// 其中高亮位移与淡出属视图动画，故请求由视图在这两步之后调用 `fetchItems(translation:)`。
    func selectSection(_ section: GameSidebarSection, sub: GameSubCategory?) {
        pendingReturnSection = nil
        selectedSection = section
        selectedSubCategory = sub
        searchText = ""
        debouncedSearchText = ""
        searchDebounceTask?.cancel()
        filteredResults = []
        displayLimit = 120
        showDetail = false
        selectedModItem = nil
    }

    /// 详情页展示项：用已翻译副标题替换原文（翻译状态由视图侧 `CardTranslationModel` 提供）
    func displayItem(for item: DownloadedItem, translatedSubtitle: String) -> DownloadedItem {
        DownloadedItem(
            id: item.id,
            name: item.name,
            subtitle: translatedSubtitle,
            iconURL: item.iconURL,
            tags: item.tags
        )
    }

    // MARK: - 列表派生刷新

    /// items 变更后的派生刷新。
    ///
    /// 由视图在 `onChange(of: items)` 内延迟到渲染事务外调用（与收口前一致：
    /// onChange 处于视图更新事务中，同步写 filteredResults/displayLimit 会触发
    /// "Modifying state during view update"，是 UAF 前兆）。
    func handleItemsChanged(_ newItems: [DownloadedItem], translation: CardTranslationModel) {
        filteredResults = newItems
        displayLimit = 120
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            applyFilter(translation: translation)
        }
    }

    // MARK: - 搜索

    /// 搜索过滤决策树（防抖 400ms）：
    /// 1. 空串：直接回填全部条目
    /// 2. 游戏版本页：本地过滤（统一谓词，tags 为空自动退化为标题+简介）
    /// 3. 其余分类：本地全量目录过滤（仅当后台解析完成，避免主线程同步解压目录）
    /// 4. 目录不可用：中文先翻译成英文再走 Modrinth 检索
    func applyFilter(translation: CardTranslationModel) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let normalized = searchText.replacingOccurrences(of: "。", with: ".")
            if normalized.trimmingCharacters(in: .whitespaces).isEmpty {
                await MainActor.run {
                    debouncedSearchText = searchText
                    activeSearchQuery = ""
                    filteredResults = items
                    displayLimit = 120
                    searchPopInIds = []
                }
                return
            }
            // 游戏版本页：本地过滤（本地版本列表；统一谓词，tags 为空自动退化为标题+简介）
            if selectedSection == .game {
                let filtered = items.filter { ItemFilter.matches($0, query: normalized) }
                await MainActor.run {
                    debouncedSearchText = searchText
                    activeSearchQuery = ""
                    filteredResults = filtered
                    displayLimit = 120
                    searchPopInIds = []
                }
                return
            }
            // 其余分类：优先本地全量目录过滤（标题/简介/标签，含中文标签直接匹配）
            // 仅当后台已解析完成时读取本地目录，避免主线程同步解压 12 万条目录造成卡顿
            if LocalModCatalog.isReady {
            let local = LocalModCatalog.items(for: selectedSection)
            if !local.isEmpty {
                let filtered = local.filter { ItemFilter.matches($0, query: normalized) }
                await MainActor.run {
                    debouncedSearchText = searchText
                    activeSearchQuery = ""
                    filteredResults = filtered
                    displayLimit = 120
                    searchPopInIds = []
                }
                translation.prefetch(filtered, service: TranslationService.shared)
                return
            }
            }
            // 目录不可用时：中文先翻译成英文，再调用 API 搜索全库（检索标题与简介）
            var searchQuery = normalized
            let hasChinese = ChineseText.contains(normalized)
            if hasChinese {
                let englishTerms = await SearchTranslator.translate(normalized)
                if !englishTerms.isEmpty {
                    searchQuery = englishTerms.joined(separator: " ")
                }
            }
            let section = selectedSection
            guard let type = ModrinthSectionType.type(for: section) else { return }
            let result = await ModrinthSearcher.search(type: type, label: "", query: searchQuery, offset: 0)
            if Task.isCancelled { return }
            guard isViewActive else { return }
            await MainActor.run {
                guard section == self.selectedSection else { return }
                debouncedSearchText = searchText
                activeSearchQuery = searchQuery
                items = result.items
                currentOffset = result.items.count
                hasMore = result.totalHits > result.items.count
                filteredResults = result.items
                displayLimit = 120
                searchPopInIds = []
            }
        }
    }

    // MARK: - 分页

    /// 触底加载下一页（仅 Modrinth 网络分类；本地全量目录与游戏版本页没有更多数据）
    func loadMore() {
        guard hasMore, !isLoadingMore, selectedSection != .game else { return }
        isLoadingMore = true
        let section = selectedSection
        guard let type = ModrinthSectionType.type(for: section) else {
            isLoadingMore = false
            return
        }
        let query = activeSearchQuery
        let offset = currentOffset
        let baseItems = items
        Task {
            let result = await ModrinthSearcher.search(type: type, label: "", query: query, offset: offset, limit: 30)
            if Task.isCancelled { return }
            await MainActor.run {
                guard section == self.selectedSection else { self.isLoadingMore = false; return }
                var merged = baseItems
                let existingIds = Set(baseItems.map { $0.id })
                for item in result.items where !existingIds.contains(item.id) {
                    merged.append(item)
                }
                items = merged
                currentOffset = offset + result.items.count
                hasMore = result.totalHits > offset + result.items.count
                filteredResults = merged
                displayLimit = 120
                isLoadingMore = false
            }
        }
    }

    // MARK: - 取数

    /// 取当前分类的列表数据。
    ///
    /// 分支顺序与收口前逐条一致：
    /// 1. 非游戏分类且本地全量目录就绪 → 直接加载全量（不翻译）
    /// 2. 游戏分类 → 磁盘/内存清单先立即渲染，联网刷新放后台（首屏不等网络）
    /// 3. 其它分类的内存/磁盘缓存
    /// 4. 联网：游戏版本清单 或 Modrinth 检索
    func fetchItems(translation: CardTranslationModel) {
        fetchTask?.cancel()
        fetchToken &+= 1
        let token = fetchToken

        // 本地全量目录模式：mod/resourcepack/shader/modpack 直接加载全量（不翻译）
        // 仅当后台已解析完成时走本地目录，主线程绝不触碰磁盘/解压 12 万条目录
        if selectedSection != .game && LocalModCatalog.isReady {
            let local = LocalModCatalog.items(for: selectedSection)
            if !local.isEmpty {
                isLoading = true
                items = []
                filteredResults = []
                fetchTask = Task {
                    let result = LocalModCatalog.items(for: selectedSection)
                    if Task.isCancelled { return }
                    var shouldPrefetch = false
                    await MainActor.run {
                        // 归属校验：期间已发起新请求（切换分类/刷新）则丢弃本次结果
                        guard token == fetchToken else { return }
                        items = result
                        currentOffset = result.count
                        hasMore = false
                        isLoading = false
                        filteredResults = result
                        displayLimit = 120
                        searchPopInIds = []
                        shouldPrefetch = true
                    }
                    if shouldPrefetch {
                        translation.prefetch(result, service: TranslationService.shared)
                    }
                }
                return
            }
        }

        // 游戏版本：磁盘/内存清单先立即渲染，联网刷新放后台，不再让首屏等待网络。
        if selectedSection == .game,
           let cachedVersions = versionCatalog.cachedVersions() {
            let cached = makeMinecraftVersionItems(cachedVersions, subCategory: selectedSubCategory)
            if !cached.isEmpty {
                items = cached
                filteredResults = cached
                currentOffset = cached.count
                hasMore = false
                isLoading = false
                ModrinthCategoryCache.cachedGameVersions = cached
                ModrinthCategoryCache.lastGameSubCategory = selectedSubCategory
            }
        } else if let cached = ModrinthCategoryCache.cache(for: selectedSection, sub: selectedSubCategory) {
            items = cached
            currentOffset = cached.count
            hasMore = true
            isLoading = false
            if selectedSection != .game {
                translation.prefetch(cached, service: TranslationService.shared)
            }
            return
        }

        let targetSection = selectedSection
        if targetSection != .game || items.isEmpty { isLoading = true }
        if targetSection != .game { items = [] }
        fetchTask = Task {
            let result: [DownloadedItem]
            var totalHits = 0
            switch targetSection {
            case .game:
                result = await fetchMinecraftVersions(subCategory: selectedSubCategory, forceRefresh: true)
                totalHits = result.count
            case .mod, .resourcePack, .shader, .modpack:
                // 四类 Modrinth 分类统一走搜索 + 内存/磁盘缓存写回（type 由 ModrinthSectionType 映射）
                let type = ModrinthSectionType.type(for: targetSection) ?? "mod"
                let r = await ModrinthSearcher.search(type: type, label: "", limit: 100)
                result = r.items; totalHits = r.totalHits
                if !result.isEmpty {
                    ModrinthCategoryCache.setCache(result, for: targetSection)
                    if let key = ModrinthCategoryCache.diskKey(for: targetSection) {
                        ModrinthCategoryCache.saveToDisk(result, for: key)
                    }
                }
            }
            if Task.isCancelled { return }
            var shouldPrefetch = false
            await MainActor.run {
                // 归属校验：期间已发起新请求（切换分类/刷新）则丢弃本次结果
                guard token == fetchToken else { return }
                items = result
                filteredResults = result
                currentOffset = result.count
                hasMore = totalHits > result.count
                isLoading = false
                shouldPrefetch = targetSection != .game
            }
            if shouldPrefetch {
                translation.prefetch(result, service: TranslationService.shared)
            }
        }
    }

    /// 游戏版本清单：命中上次同子分类的游戏版本缓存则直接返回，否则拉取并按子分类过滤。
    ///
    /// 清单取数（主源/镜像并发、三级缓存、未列出版本合并）与分类规则分别由
    /// `VersionCatalogService` / `VersionFilterUseCase` 承担，本方法只做「清单 → 列表项」的编排。
    private func fetchMinecraftVersions(subCategory: GameSubCategory?, forceRefresh: Bool = false) async -> [DownloadedItem] {
        if !forceRefresh, subCategory == ModrinthCategoryCache.lastGameSubCategory, let cached = ModrinthCategoryCache.cachedGameVersions {
            return cached
        }
        let versions = await versionCatalog.fetchVersions(forceRefresh: forceRefresh)
        guard !versions.isEmpty else { return ModrinthCategoryCache.cachedGameVersions ?? [] }
        return makeMinecraftVersionItems(versions, subCategory: subCategory)
    }

    /// 清单快照 → 列表项：按子分类过滤后取版本号，并回写游戏版本缓存。
    ///
    /// 缓存写回先于空列表判断（与收口前一致：`makeMinecraftVersionItems` 无论结果是否为空都写缓存）。
    private func makeMinecraftVersionItems(_ versions: [MinecraftVersionInfo], subCategory: GameSubCategory?) -> [DownloadedItem] {
        let result = versionFilter.ids(versions, subCategory: subCategory).map { id in
            DownloadedItem(id: id, name: id, subtitle: displayTitle, iconURL: nil, tags: [])
        }
        ModrinthCategoryCache.cachedGameVersions = result
        ModrinthCategoryCache.lastGameSubCategory = subCategory
        return result
    }
}
