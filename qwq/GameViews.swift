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
    // 卡片副标题翻译状态与调度已下沉到 CardTranslationModel（与详情页共享同一套
    // 「内存→磁盘→网络」按需翻译流程；视图销毁后 model 不再写回，UAF 防护）
    @StateObject private var translationModel = CardTranslationModel()
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

    // 侧边栏高亮偏移表与 section→index 映射集中在 SidebarHighlight（与 GameSidebarView 共享）

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
                translationModel.prefetch(filtered, service: TranslationService.shared)
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
            translationModel.activate()
            ModrinthCategoryCache.loadFromDisk()
            let idx = SidebarHighlight.index(for: selectedSection, sub: selectedSubCategory)
            sectionHighlightY = SidebarHighlight.offsets[idx]
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
            translationModel.deactivate()
            fetchTask?.cancel()
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
                        navigateTo(SidebarHighlight.index(for: .mod, sub: nil))
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
                translatedSubtitles: translationModel.translated,
                cardWidth: cardWidth,
                cardPadding: cardPadding,
                columns: columns,
                displayLimit: $displayLimit,
                onOpen: { openDetail($0) },
                onRequestTranslation: { await translationModel.requestTranslation(for: $0, service: TranslationService.shared) }
            )
        }
    }

    private func openDetail(_ item: DownloadedItem) {
        let display = DownloadedItem(
            id: item.id,
            name: item.name,
            subtitle: translationModel.subtitle(for: item),
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
        translationModel.prefetch(filteredResults, service: TranslationService.shared)
    }

    private func navigateTo(_ idx: Int) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            sectionHighlightY = SidebarHighlight.offsets[idx]
        }
    }

    private func selectSection(_ section: GameSidebarSection, sub: GameSubCategory?) {
        selectedSection = section
        selectedSubCategory = sub
        searchText = ""
        debouncedSearchText = ""
        searchDebounceTask?.cancel()
        filteredResults = []
        displayLimit = 120
        showDetail = false
        selectedModItem = nil
        navigateTo(SidebarHighlight.index(for: section, sub: sub))
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
                    translationModel.prefetch(result, service: TranslationService.shared)
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
                translationModel.prefetch(cached, service: TranslationService.shared)
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
                translationModel.prefetch(result, service: TranslationService.shared)
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


