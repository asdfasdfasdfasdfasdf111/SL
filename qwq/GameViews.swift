import SwiftUI
import AppKit
import Combine
import zlib

// ScrollBounceModifier → Core/ScrollBounceModifier.swift
// VersionButton → UI/VersionButton.swift
// JavaSelectionPopup, JavaPickerView, JavaPickerRow → UI/JavaPickerView.swift
// GameSubCategory, GameSidebarSection, ModrinthTagMap, DownloadedItem → Models/GameModels.swift

struct DownloadCategoryView: View {
    @EnvironmentObject var settings: LauncherSettings
    @ObservedObject var theme = ThemeManager.shared
    @State private var selectedSection: GameSidebarSection = .game
    @State private var selectedSubCategory: GameSubCategory? = .release
    @State private var subItemOpacity: [GameSubCategory: Double] = [
        .release: 0, .snapshot: 0, .ancient: 0
    ]
    @State private var sectionHighlightY: CGFloat = 12
    @State private var items: [DownloadedItem] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var filteredResults: [DownloadedItem] = []
    @State private var contentOpacity: Double = 1
    @State private var contentOffset: CGFloat = 0
    @State private var fetchTask: Task<Void, Never>?
    @State private var translateTask: Task<Void, Never>?
    @State private var translatedSubtitles: [String: String] = [:]
    @State private var pendingTranslationIDs: Set<String> = []
    // 滚动锚点已随 resultsGrid 迁移到 CategoryResultsGrid（仅用于返回列表时恢复位置）
    @State private var searchPopInIds: Set<String> = []
    @State private var selectedModItem: DownloadedItem? = nil
    @State private var showDetail = false
    @State private var geometryWidth: CGFloat = 0

    // 分页加载状态
    @State private var currentOffset = 0
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var activeSearchQuery = ""
    // 本地目录分页展示：全量目录（如 mod 分类可达数万条）不能一次注入 ForEach 做全量 diff，
    // 首帧只展示前 displayLimit 条，滚动到底部自动追加（网络模式条目 ≤ 100，永不触发截断）
    @State private var displayLimit = 120

    // 下载详情页与圆按钮状态已提升到全局 DownloadDetailManager（ContentView 顶层渲染），
    // 本视图不再持有相关 @State，避免视图销毁后回调写 State 触发 UAF

    private let sidebarOffsets: [CGFloat] = {
        let hs: [CGFloat] = [36, 28, 28, 28, 36, 36, 36, 36]
        var off: [CGFloat] = [12]
        for i in 0..<7 { off.append(off[i] + hs[i]) }
        return off
    }()

    private var computedHighlightIndex: Int {
        switch selectedSection {
        case .game:
            switch selectedSubCategory {
            case .release: return 1
            case .snapshot: return 2
            case .ancient: return 3
            case .none: return 0
            }
        case .mod: return 4
        case .resourcePack: return 5
        case .shader: return 6
        case .modpack: return 7
        }
    }

    private var displayTitle: String {
        if selectedSection == .game, let sub = selectedSubCategory {
            return sub.rawValue
        }
        return selectedSection.rawValue
    }
    
    private var currentDetailPageType: DetailPageType {
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

    private static let hasChineseRegex = try! NSRegularExpression(pattern: "\\p{Han}")

    private func applyFilter() {
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
                startSequentialTranslation(for: filtered)
                return
            }
            }
            // 目录不可用时：中文先翻译成英文，再调用 API 搜索全库（检索标题与简介）
            var searchQuery = normalized
            let range = NSRange(normalized.startIndex..., in: normalized)
            let hasChinese = Self.hasChineseRegex.firstMatch(in: normalized, range: range) != nil
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
            guard Self.isViewActive else { return }
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

    private func loadMore() {
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

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth: CGFloat = 180
            let separatorWidth: CGFloat = 0.5
            let cardPadding: CGFloat = 20
            let contentWidth = geometry.size.width - sidebarWidth - separatorWidth
            let columns = max(1, Int((contentWidth - cardPadding * 2) / 220))
            let cardWidth = ((contentWidth - cardPadding * 2) - cardPadding * CGFloat(columns - 1)) / CGFloat(columns)

            mainHStack(
                sidebarWidth: sidebarWidth,
                contentWidth: contentWidth,
                cardPadding: cardPadding,
                columns: columns,
                cardWidth: cardWidth,
                geometry: geometry
            )
        }
        .onAppear {
            Self.isViewActive = true
            ModrinthCategoryCache.loadFromDisk()
            let idx = computedHighlightIndex
            sectionHighlightY = sidebarOffsets[idx]
            LocalModCatalog.warmUp()
            fetchItems()
            LocalModCatalog.preTranslateAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    subItemOpacity[.release] = 1
                    subItemOpacity[.snapshot] = 1
                    subItemOpacity[.ancient] = 1
                }
            }
        }
        .onDisappear {
            Self.isViewActive = false
            fetchTask?.cancel()
            translateTask?.cancel()
            searchDebounceTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalModCatalog.readyNotification)) { _ in
            // 本地目录后台解析完成后，若正停在 mod/资源包/光影/整合包页，自动刷新为全量本地目录
            if selectedSection != .game {
                fetchItems()
            }
        }
        .onChange(of: searchText) { _ in applyFilter() }
        .onChange(of: items) { newItems in
            filteredResults = newItems
            displayLimit = 120
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                applyFilter()
            }
        }
        // 注意：圆形下载按钮与下载详情页已提升到 ContentView 顶层渲染
        // （对标 PCL.Mac AppRouter：详情页为独立页面整页切换，圆按钮为全局 overlay，
        //  不再挂在本宿主视图的 overlay 上——本视图会随分类切换销毁，是 UAF 崩溃根因）
    }

    private func mainHStack(
        sidebarWidth: CGFloat,
        contentWidth: CGFloat,
        cardPadding: CGFloat,
        columns: Int,
        cardWidth: CGFloat,
        geometry: GeometryProxy
    ) -> some View {
        HStack(spacing: 0) {
            GameSidebarView(
                theme: theme,
                sidebarOffsets: sidebarOffsets,
                selectedSection: $selectedSection,
                selectedSubCategory: $selectedSubCategory,
                subItemOpacity: $subItemOpacity,
                sectionHighlightY: $sectionHighlightY,
                onSelect: { section, sub in selectSection(section, sub: sub) }
            )
            .frame(width: sidebarWidth)
            .frame(maxHeight: .infinity)

            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)

            if let item = selectedModItem {
                ModDetailView(
                    item: item,
                    pageType: currentDetailPageType,
                    onClose: { closeDetail() },
                    onNavigateToMod: { modItem in
                        selectedSection = .mod
                        selectedSubCategory = nil
                        navigateTo(computedHighlightIndex)
                    },
                    gameSubCategory: selectedSubCategory
                )
                .frame(width: contentWidth)
                .frame(maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .trailing)
                ))
            } else {
                listContainer(
                    contentWidth: contentWidth,
                    cardPadding: cardPadding,
                    columns: columns,
                    cardWidth: cardWidth
                )
            }
        }
        .clipped()
        .overlay(
            Color.clear.frame(width: 0, height: 0)
                .onAppear { geometryWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { geometryWidth = $0 }
        )
    }

    private func listContainer(
        contentWidth: CGFloat,
        cardPadding: CGFloat,
        columns: Int,
        cardWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                CategorySearchBar(title: displayTitle, searchText: $searchText, cardPadding: cardPadding)
                contentBody(cardPadding: cardPadding, columns: columns, cardWidth: cardWidth)
            }
            .frame(width: contentWidth)
        }
        .frame(width: contentWidth + cardPadding * 2, alignment: .leading)
    }

    @ViewBuilder
    private func contentBody(cardPadding: CGFloat, columns: Int, cardWidth: CGFloat) -> some View {
        if isLoading {
            Spacer()
            HStack {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Spacer()
            }
            Spacer()
        } else if filteredResults.isEmpty && !items.isEmpty {
            Spacer()
            Text("无匹配结果")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
        } else if items.isEmpty {
            Spacer()
            Text("暂无内容")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
        } else {
            CategoryResultsGrid(
                results: filteredResults,
                translatedSubtitles: translatedSubtitles,
                cardWidth: cardWidth,
                cardPadding: cardPadding,
                columns: columns,
                displayLimit: $displayLimit,
                onOpen: { openDetail($0) },
                onRequestTranslation: { await requestTranslation(for: $0) }
            )
        }
    }

    private func openDetail(_ item: DownloadedItem) {
        let display = DownloadedItem(
            id: item.id,
            name: item.name,
            subtitle: translatedSubtitles[item.id] ?? item.subtitle,
            iconURL: item.iconURL,
            tags: item.tags
        )
        selectedModItem = display
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            showDetail = true
        }
    }

    private func closeDetail() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showDetail = false
            selectedModItem = nil
        }
        // 详情页翻译过的条目立即回写列表卡片（缓存已在磁盘）
        startSequentialTranslation(for: filteredResults)
    }

    private func navigateTo(_ idx: Int) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            sectionHighlightY = sidebarOffsets[idx]
        }
    }

    private func selectSection(_ section: GameSidebarSection, sub: GameSubCategory?) {
        selectedSection = section
        selectedSubCategory = sub
        searchText = ""
        debouncedSearchText = ""
        searchDebounceTask?.cancel()
        translateTask?.cancel()
        filteredResults = []
        displayLimit = 120
        showDetail = false
        selectedModItem = nil
        navigateTo(computedHighlightIndex)
        withAnimation(.easeInOut(duration: 0.12)) {
            contentOpacity = 0.6
            contentOffset = 8
        }
        fetchItems()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.18)) {
                contentOpacity = 1
                contentOffset = 0
            }
        }
    }

    private func fetchItems() {
        fetchTask?.cancel()

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
                    await MainActor.run {
                        items = result
                        currentOffset = result.count
                        hasMore = false
                        isLoading = false
                        filteredResults = result
                        displayLimit = 120
                        searchPopInIds = []
                    }
                    startSequentialTranslation(for: result)
                }
                return
            }
        }

        if let cached = ModrinthCategoryCache.cache(for: selectedSection, sub: selectedSubCategory) {
            items = cached
            currentOffset = cached.count
            hasMore = true
            isLoading = false
            if selectedSection != .game {
                startSequentialTranslation(for: cached)
            }
            return
        }

        isLoading = true
        items = []
        let targetSection = selectedSection
        fetchTask = Task {
            let result: [DownloadedItem]
            var totalHits = 0
            switch targetSection {
            case .game:
                result = await fetchMinecraftVersions(subCategory: selectedSubCategory)
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
            await MainActor.run {
                items = result
                currentOffset = result.count
                hasMore = totalHits > result.count
                isLoading = false
            }
            if targetSection != .game {
                startSequentialTranslation(for: result)
            }
        }
    }

    /// 批量应用翻译缓存（纯内存扫描 + 磁盘一次性批量预取）。
    /// 磁盘命中由 CacheManager.prefetchText 一次性枚举目录后批量读入内存：
    /// 相比逐条 fileExists+读盘，IO 次数从 O(n) 降到 O(1 次枚举 + 命中数)，
    /// 覆盖首屏 + 预加载窗口即可，避免对 12 万条本地目录做海量磁盘扫描
    private func startSequentialTranslation(for items: [DownloadedItem]) {
        translateTask?.cancel()
        let service = TranslationService.shared
        translateTask = Task.detached(priority: .background) {
            // 只预热前若干条目（覆盖首屏 + 预加载窗口），防止海量目录读盘拖慢启动
            let warmupCount = min(items.count, 5000)
            let ids = items.prefix(warmupCount).map { $0.id }
            let batch = service.prefetchTranslations(ids: ids)
            guard !batch.isEmpty, !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if Self.isViewActive {
                    // 单次 merge 写入：只触发一次 body 重算；merge 后裁剪超限条目
                    self.translatedSubtitles.merge(batch) { _, new in new }
                    self.trimTranslationsIfNeeded()
                }
            }
        }
    }

    /// 翻译结果内存上限：滚动浏览会不断累积条目，超限时裁剪「非活跃」条目
    /// （不在下载中的已完成翻译；滚动回看时由磁盘缓存瞬时恢复，功能不受影响）
    private static let maxTranslatedSubtitles = 2000

    /// 统一翻译写回入口：赋值 + 超限裁剪（裁剪移除非活跃条目，保留正在翻译的）
    private func setTranslated(_ id: String, _ value: String) {
        if translatedSubtitles[id] == nil, translatedSubtitles.count >= Self.maxTranslatedSubtitles {
            trimTranslationsIfNeeded()
        }
        translatedSubtitles[id] = value
    }

    private func trimTranslationsIfNeeded() {
        guard translatedSubtitles.count > Self.maxTranslatedSubtitles else { return }
        let active = pendingTranslationIDs
        translatedSubtitles = translatedSubtitles.filter { active.contains($0.key) }
    }

    /// 按需翻译单个卡片：缓存命中直接应用，否则排队翻译（滚动到哪翻译到哪）
    ///
    /// 关键修复：原先在主线程直接调用 `cachedTranslation`（会同步读盘），
    /// 滚动时每个进入可视区的卡片都触发一次磁盘读取，造成主线程阻塞、列表卡顿（“垃圾优化”）。
    /// 现在主线程只查内存缓存（内置表 + 内存 LRU，瞬时、零阻塞），
    /// 磁盘读取与网络翻译全部下沉到后台任务，彻底解除滚动卡顿。
    private func requestTranslation(for item: DownloadedItem) async {        let id = item.id
        guard !id.isEmpty, translatedSubtitles[id] == nil, !pendingTranslationIDs.contains(id) else { return }
        let service = TranslationService.shared
        // 仅查内存缓存（内置表 + 内存 LRU），主线程零阻塞、瞬时返回
        if let cached = service.cachedTranslationInMemory(for: id), !cached.isEmpty {
            // 淡入动画：与网络翻译完成时的效果一致，避免瞬时跳变
            withAnimation(.easeInOut(duration: 0.3)) { setTranslated(id, cached) }
            return
        }
        pendingTranslationIDs.insert(id)
        let subtitle = item.subtitle
        // 磁盘缓存查询走 detached 立即执行（毫秒级、成本低，无需防抖）；
        // 命中即应用，减少「卡片出现 → 等防抖 → 再查盘」的感知延迟
        if let diskCached = try? await Task.detached(priority: .utility, operation: { service.cachedTranslation(for: id) }).value,
           !diskCached.isEmpty {
            if Task.isCancelled {
                pendingTranslationIDs.remove(id)
                return
            }
            await MainActor.run {
                self.pendingTranslationIDs.remove(id)
                if !diskCached.isEmpty, Self.isViewActive {
                    withAnimation(.easeInOut(duration: 0.3)) { self.setTranslated(id, diskCached) }
                }
            }
            return
        }
        // 磁盘未命中 → 网络翻译：短暂防抖，快速滑动时这张卡的任务会被取消 → 直接返回，不产生无谓的网络请求
        try? await Task.sleep(nanoseconds: 120_000_000)
        if Task.isCancelled {
            pendingTranslationIDs.remove(id)
            return
        }
        Task.detached(priority: .utility) {
            // 后台线程发起网络翻译：translateText 内含信号量阻塞等待，必须脱离主线程执行
            let result = try? await service.translateText(text: subtitle, projectId: id)
            let final = result ?? ""
            await MainActor.run {
                self.pendingTranslationIDs.remove(id)
                if !final.isEmpty, Self.isViewActive {
                    // 淡入动画：翻译完成时副标题文字柔和过渡，不再生硬跳变
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.setTranslated(id, final)
                    }
                }
            }
        }
    }

    private static var isViewActive = false

    /// 清理静态缓存（内存警告时调用）
    static func clearStaticCaches() {
        ModrinthCategoryCache.clearAll()
        SearchTranslator.clearCache()
        GameVersionManifest.clearCache()
        LoaderSupportChecker.clearMemoryCache()
    }

    private func fetchMinecraftVersions(subCategory: GameSubCategory?) async -> [DownloadedItem] {
        if subCategory == ModrinthCategoryCache.lastGameSubCategory, let cached = ModrinthCategoryCache.cachedGameVersions {
            return cached
        }
        let versions = await GameVersionManifest.fetchMerged()
        guard !versions.isEmpty else { return ModrinthCategoryCache.cachedGameVersions ?? [] }
        // 分类过滤逻辑在 GameVersionFilter（release/snapshot/远古，与详情页共享同一规则）
        let result = GameVersionFilter.filteredIDs(versions, subCategory: subCategory).map { id in
            DownloadedItem(
                id: id,
                name: id,
                subtitle: displayTitle,
                iconURL: nil,
                tags: []
            )
        }
        ModrinthCategoryCache.cachedGameVersions = result
        ModrinthCategoryCache.lastGameSubCategory = subCategory
        return result
    }
}


