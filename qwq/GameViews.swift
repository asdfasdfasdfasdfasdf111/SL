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
    // 滚动锚点：仅用于返回列表时恢复位置，无需触发视图重渲染，故不用 @State（快速滑动时
    // 每次 onAppear 写 @State 都会让整个列表 body 重算，是快速滑动卡顿的元凶之一）
    private nonisolated(unsafe) static var lastAnchorItemID: String? = nil
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

    // 圆形毛玻璃下载按钮 — 全局顶层，跨页面保留
    @State private var showCircleButton = false
    @State private var circleScale: CGFloat = 0.01
    @State private var circleOpacity: Double = 0

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
            // 游戏版本页：本地过滤（本地版本列表）
            if selectedSection == .game {
                let filtered = items.filter {
                    $0.name.localizedCaseInsensitiveContains(normalized) ||
                    $0.subtitle.localizedCaseInsensitiveContains(normalized)
                }
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
            if Self.localCatalogReady {
            let local = Self.localItems(for: selectedSection)
            if !local.isEmpty {
                let filtered = local.filter { item in
                    item.name.localizedCaseInsensitiveContains(normalized) ||
                    item.subtitle.localizedCaseInsensitiveContains(normalized) ||
                    item.tags.contains { $0.localizedCaseInsensitiveContains(normalized) } ||
                    ModrinthTagMap.contains { $1 == normalized && item.tags.contains($0) }
                }
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
                let englishTerms = await translateChineseToEnglish(normalized)
                if !englishTerms.isEmpty {
                    searchQuery = englishTerms.joined(separator: " ")
                }
            }
            let section = selectedSection
            let type: String
            switch section {
            case .mod: type = "mod"
            case .resourcePack: type = "resourcepack"
            case .shader: type = "shader"
            case .modpack: type = "modpack"
            default: return
            }
            let result = await fetchRawModrinthItems(type: type, label: "", query: searchQuery, offset: 0)
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
        let type: String
        switch section {
        case .mod: type = "mod"
        case .resourcePack: type = "resourcepack"
        case .shader: type = "shader"
        case .modpack: type = "modpack"
        default:
            isLoadingMore = false
            return
        }
        let query = activeSearchQuery
        let offset = currentOffset
        let baseItems = items
        Task {
            let result = await fetchRawModrinthItems(type: type, label: "", query: query, offset: offset, limit: 30)
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

    private func translateChineseToEnglish(_ text: String) async -> [String] {
        guard Self.isViewActive else { return [] }
        Self.searchTranslationCacheLock.lock()
        if let cached = Self.searchTranslationCache[text] { Self.searchTranslationCacheLock.unlock(); return cached }
        Self.searchTranslationCacheLock.unlock()
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")!
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "zh|en")
        ]
        guard let url = components.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]] else { return [] }
        var results: [String] = []
        var seen = Set<String>()
        for m in matches {
            guard let t = m["translation"] as? String,
                  !t.isEmpty, t.lowercased() != text.lowercased(),
                  !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            results.append(t)
        }
        guard !results.isEmpty else { return [] }
        Self.searchTranslationCacheLock.lock()
        // 限制缓存大小：超过 100 条则清空一半
        if Self.searchTranslationCache.count >= 100 {
            let keys = Array(Self.searchTranslationCache.keys.prefix(50))
            for k in keys { Self.searchTranslationCache.removeValue(forKey: k) }
        }
        Self.searchTranslationCache[text] = results
        Self.searchTranslationCacheLock.unlock()
        return results
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
            Self.loadCacheFromDisk()
            let idx = computedHighlightIndex
            sectionHighlightY = sidebarOffsets[idx]
            Self.preloadLocalCatalog()
            fetchItems()
            Self.preTranslateAllCategories()
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
        .onReceive(NotificationCenter.default.publisher(for: DownloadCategoryView.localCatalogReadyNotification)) { _ in
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
        // 最顶层 overlay：圆形毛玻璃按钮（不随页面变化消失）
        .overlay(alignment: .bottomTrailing) {
            if showCircleButton {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 55, height: 55)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 15, y: 6)

                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                }
                .scaleEffect(circleScale)
                .opacity(circleOpacity)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
        }
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
            gameSidebar
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
                    gameSubCategory: selectedSubCategory,
                    showCircleButton: $showCircleButton,
                    circleScale: $circleScale,
                    circleOpacity: $circleOpacity
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
                searchBarRow(cardPadding: cardPadding)
                contentBody(cardPadding: cardPadding, columns: columns, cardWidth: cardWidth)
            }
            .frame(width: contentWidth)
        }
        .frame(width: contentWidth + cardPadding * 2, alignment: .leading)
    }

    private func searchBarRow(cardPadding: CGFloat) -> some View {
        HStack {
            Text(displayTitle)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.primary)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("搜索\(displayTitle)...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 160)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            )
        }
        .padding(.top, cardPadding)
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
            resultsGrid(cardPadding: cardPadding, columns: columns, cardWidth: cardWidth)
        }
    }

    private func resultsGrid(cardPadding: CGFloat, columns: Int, cardWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: cardPadding), count: columns),
                    spacing: cardPadding
                ) {
                    // 分页切片：只对前 displayLimit 条做 diff，本地目录数万条时首帧仅 120 条，
                    // 避免整列 ForEach 全量 diff + LazyVGrid 布局卡死主线程
                    ForEach(filteredResults.prefix(displayLimit)) { item in
                        ContentCard(
                            title: item.name,
                            subtitle: translatedSubtitles[item.id] ?? item.subtitle,
                            cardWidth: cardWidth,
                            tags: item.tags,
                            action: { openDetail(item) }
                        )
                        .equatable()
                        .id(item.id)
                        .onAppear {
                            Self.lastAnchorItemID = item.id
                            // 本地目录分页：最后一张已展示卡片进入可视区时追加下一批（增量 120 条），
                            // 避免把数万条目录一次性注入 ForEach 做全量 diff；滚出再滚回会再次触发
                            if displayLimit < filteredResults.count {
                                let lastVisibleIndex = min(displayLimit, filteredResults.count) - 1
                                if filteredResults[lastVisibleIndex].id == item.id {
                                    displayLimit = min(displayLimit + 120, filteredResults.count)
                                }
                            }
                        }
                        .task(id: item.id) { await requestTranslation(for: item) }
                    }
                }
                .padding(.horizontal, cardPadding)
                .padding(.bottom, cardPadding)
            }
            .coordinateSpace(name: "listScroll")
            .onAppear {
                if let id = Self.lastAnchorItemID {
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
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
        if selectedSection != .game && Self.localCatalogReady {
            let local = Self.localItems(for: selectedSection)
            if !local.isEmpty {
                isLoading = true
                items = []
                filteredResults = []
                fetchTask = Task {
                    let result = Self.localItems(for: selectedSection)
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

        if let cached = Self.cache(for: selectedSection, sub: selectedSubCategory) {
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
            case .mod:
                let r = await fetchRawModrinthItems(type: "mod", label: "模组", limit: 100)
                result = r.items; totalHits = r.totalHits
                if !result.isEmpty { Self.cachedModItems = result; Self.saveCacheToDisk(result, for: .mod) }
            case .resourcePack:
                let r = await fetchRawModrinthItems(type: "resourcepack", label: "资源包", limit: 100)
                result = r.items; totalHits = r.totalHits
                if !result.isEmpty { Self.cachedResourcePackItems = result; Self.saveCacheToDisk(result, for: .resourcePack) }
            case .shader:
                let r = await fetchRawModrinthItems(type: "shader", label: "光影", limit: 100)
                result = r.items; totalHits = r.totalHits
                if !result.isEmpty { Self.cachedShaderItems = result; Self.saveCacheToDisk(result, for: .shader) }
            case .modpack:
                let r = await fetchRawModrinthItems(type: "modpack", label: "整合包", limit: 100)
                result = r.items; totalHits = r.totalHits
                if !result.isEmpty { Self.cachedModpackItems = result; Self.saveCacheToDisk(result, for: .modpack) }
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

    private static func cache(for section: GameSidebarSection, sub: GameSubCategory?) -> [DownloadedItem]? {
        switch section {
        case .game:
            if sub == lastSubCategory, let c = versionManifestCache { return c }
            return nil
        case .mod: return cachedModItems
        case .resourcePack: return cachedResourcePackItems
        case .shader: return cachedShaderItems
        case .modpack: return cachedModpackItems
        }
    }

    private static var versionManifestCache: [DownloadedItem]?
    private static var lastSubCategory: GameSubCategory?
    private static var cachedModItems: [DownloadedItem]?
    private static var cachedResourcePackItems: [DownloadedItem]?
    private static var cachedShaderItems: [DownloadedItem]?
    private static var cachedModpackItems: [DownloadedItem]?
    private static var isViewActive = false
    private static var searchTranslationCache: [String: [String]] = [:]
    private static let searchTranslationCacheLock = NSLock()

    /// 清理静态缓存（内存警告时调用）
    static func clearStaticCaches() {
        versionManifestCache = nil
        lastSubCategory = nil
        mergedManifestCache = nil
        mergedManifestFetchDate = nil
        cachedModItems = nil
        cachedResourcePackItems = nil
        cachedShaderItems = nil
        cachedModpackItems = nil
        searchTranslationCacheLock.lock()
        searchTranslationCache.removeAll()
        searchTranslationCacheLock.unlock()
        LoaderSupportChecker.clearMemoryCache()
    }

    // MARK: - 版本清单合并（官方 + 未列出，并发拉取）

    private static let officialManifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest.json")!
    private static let unlistedManifestURL = URL(string: "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto/version_manifest.json")!
    private static let unlistedManifestRoot = "https://zkitefly.github.io/unlisted-versions-of-minecraft"
    private static let unlistedManifestMirrorRoot = "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto"

    private static var mergedManifestCache: [[String: Any]]?
    private static var mergedManifestFetchDate: Date?

    /// 并发拉取官方 + 未列出版本清单并合并（按 releaseTime 降序；未列出版本 URL 重写到 alist 镜像）
    /// 注意：internal 可见性（被拆分出去的 ModDetailView 调用）
    static func fetchMergedVersionManifest() async -> [[String: Any]] {
        if let cached = mergedManifestCache,
           let date = mergedManifestFetchDate,
           Date().timeIntervalSince(date) < 300 {
            return cached
        }
        async let official = fetchManifestList(url: officialManifestURL)
        async let unlisted = fetchManifestList(url: unlistedManifestURL)
        var (merged, unlistedVersions) = await (official, unlisted)
        for i in unlistedVersions.indices {
            if let url = unlistedVersions[i]["url"] as? String {
                unlistedVersions[i]["url"] = url.replacingOccurrences(of: unlistedManifestRoot, with: unlistedManifestMirrorRoot)
            }
            merged.append(unlistedVersions[i])
        }
        // 按 id 去重（保留官方条目），再按 releaseTime 降序
        var seen = Set<String>()
        merged.removeAll { entry in
            let id = entry["id"] as? String ?? ""
            if id.isEmpty || seen.contains(id) { return true }
            seen.insert(id)
            return false
        }
        merged.sort { ($0["releaseTime"] as? String ?? "") > ($1["releaseTime"] as? String ?? "") }
        // 只在拉取成功（非空）时更新缓存；全部失败时保留旧缓存，避免空结果被缓存 5 分钟
        guard !merged.isEmpty else { return mergedManifestCache ?? merged }
        mergedManifestCache = merged
        mergedManifestFetchDate = Date()
        return merged
    }

    private static func fetchManifestList(url: URL) async -> [[String: Any]] {
        guard let (data, _) = try? await AppContext.shared.apiSession.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = json["versions"] as? [[String: Any]] else { return [] }
        return versions
    }

    private enum CacheKey: String {
        case mod = "modrinth_cache_mod"
        case resourcePack = "modrinth_cache_resourcepack"
        case shader = "modrinth_cache_shader"
        case modpack = "modrinth_cache_modpack"
    }

    private static func loadCacheFromDisk() {
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

    private static func saveCacheToDisk(_ items: [DownloadedItem], for key: CacheKey) {
        AppContext.shared.cacheManager.setObject(items, forKey: key.rawValue)
    }

    // MARK: - 本地全量目录（crawl_modrinth.py 生成：mod/resourcepack/shader/modpack 全部条目，不翻译）

    struct LocalCatalogItem: Codable {
        let projectID: String
        let projectType: String
        let title: String
        let description: String
        let categories: [String]
        let iconURL: String?
        let downloads: Int
    }

    private nonisolated(unsafe) static let localCatalogLock = NSLock()
    private nonisolated(unsafe) static var localCatalog: [LocalCatalogItem]?
    private nonisolated(unsafe) static var localCatalogItemsByType: [String: [DownloadedItem]] = [:]
    /// 本地全量目录是否已在后台解析完成。主线程只在它为 true 时才调用 localItems，
    /// 从而杜绝「切到 mod 页时主线程同步读盘+解压 12 万条目录 → 卡死/动画丢失/翻译失效」。
    private nonisolated(unsafe) static var localCatalogReady = false
    /// 本地目录解析完成通知（用于让已显示的 mod 页自动刷新为全量本地目录）
    static let localCatalogReadyNotification = Notification.Name("localCatalogReady")

    /// 解压 gzip 数据（系统 libz，windowBits=31 支持 gzip 格式）
    nonisolated private static func inflateGzipData(_ input: Data) -> Data? {
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
    private static func localCatalogCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("modrinth_local_catalog_v1.json")
    }

    /// 缓存是否仍有效：bundle 内的 gzip 源比磁盘缓存新则视为过期需重解
    private static func isLocalCatalogCacheFresh() -> Bool {
        guard let gzURL = Bundle.main.url(forResource: "modrinth_catalog", withExtension: "json.gz"),
              let cacheURL = localCatalogCacheURL() else { return false }
        let fm = FileManager.default
        let gzDate = (try? fm.attributesOfItem(atPath: gzURL.path)[.modificationDate] as? Date) ?? .distantPast
        let cacheDate = (try? fm.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date) ?? .distantPast
        return cacheDate >= gzDate
    }

    private static func loadLocalCatalogFromDisk() -> [LocalCatalogItem]? {
        guard isLocalCatalogCacheFresh(),
              let url = localCatalogCacheURL(),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([LocalCatalogItem].self, from: data),
              !items.isEmpty else { return nil }
        return items
    }

    private static func saveLocalCatalogToDisk(_ items: [LocalCatalogItem]) {
        guard let url = localCatalogCacheURL() else { return }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 从 bundle 读取 modrinth_catalog.json.gz 并解析（全量目录缓存）。
    /// 优先复用解析结果的磁盘缓存，避免每次冷启动都重新解压 12 万条 gzip。
    nonisolated static func loadLocalCatalog() -> [LocalCatalogItem] {
        localCatalogLock.lock()
        defer { localCatalogLock.unlock() }
        if let localCatalog { return localCatalog }

        // 1) 复用解析结果磁盘缓存（二次冷启动秒开）
        if let cached = Self.loadLocalCatalogFromDisk() {
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
        let catalog = entries.compactMap { entry -> LocalCatalogItem? in
            guard let projectID = entry["i"] as? String,
                  let projectType = entry["t"] as? String,
                  let title = entry["n"] as? String else { return nil }
            return LocalCatalogItem(
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
        Task.detached(priority: .utility) { Self.saveLocalCatalogToDisk(toCache) }
        return catalog
    }

    /// 按分类返回本地全量条目（首次按类型映射缓存，线程安全）
    nonisolated static func localItems(for section: GameSidebarSection) -> [DownloadedItem] {
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
        let catalog = loadLocalCatalog()
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

    /// 应用启动时预热本地全量目录（对应 PCL 的 PageLoaderInit：在用户打开下载页之前就后台解析，
    /// 让 mod/资源包/光影/整合包页首帧即有数据，消除「空白→填充」的延迟感）
    static func warmUpLocalCatalog() {
        preloadLocalCatalog()
    }

    /// 后台预加载四类本地目录，避免首次切页时阻塞主线程
    private static func preloadLocalCatalog() {
        guard !localCatalogReady else { return }
        Task.detached(priority: .userInitiated) {
            _ = localItems(for: .mod)
            _ = localItems(for: .resourcePack)
            _ = localItems(for: .shader)
            _ = localItems(for: .modpack)
            localCatalogReady = true
            // 本地目录就绪后通知界面：若当前停在 mod/资源包/光影/整合包页，自动刷新为全量本地目录
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: localCatalogReadyNotification, object: nil)
            }
        }
    }

    private static func preTranslateAllCategories() {
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

    // 愚人节版本列表（参考 PCL.Mac VersionManifest.swift）
    private static let aprilFoolVersions: [String] = [
        "15w14a", "1.rv-pre1", "3d shareware v1.34", "20w14infinite",
        "22w13oneblockatatime", "23w13a_or_b", "24w14potato", "25w14craftmine"
    ]

    // 判断是否为愚人节版本（参考 PCL.Mac isAprilFoolVersion）
    private static func isAprilFoolVersion(id: String, type: String) -> Bool {
        let normalized = id.replacingOccurrences(of: "point", with: ".")
        if aprilFoolVersions.contains(normalized.lowercased()) { return true }
        guard type == "snapshot" else { return false }
        // 新版 Mojang 命名（2026 起）：快照为「主版本号-snapshot-N」如 26.3-snapshot-7，
        // 正式版为「主版本号」如 26.2，这些是正式内容，绝不能判为愚人节。
        let snapshotPattern = #"^[0-9][0-9]?(\.[0-9]+)?-snapshot-[0-9]+$"#
        if normalized.range(of: snapshotPattern, options: .regularExpression) != nil { return false }
        // 旧版标准快照格式（如 23w33a、24w14a）：正式快照，非愚人节
        let oldSnapshotPattern = #"^[0-9]{2}w[0-9]{2}[a-z]$"#
        if normalized.range(of: oldSnapshotPattern, options: .regularExpression) != nil { return false }
        // 至少有一个字母（筛掉 1.x 与 1.x.x），且不是 -pre/-rc
        if normalized.rangeOfCharacter(from: .letters) == nil { return false }
        if normalized.contains("-pre") || normalized.contains("-rc") { return false }
        return true
    }

    private func fetchMinecraftVersions(subCategory: GameSubCategory?) async -> [DownloadedItem] {
        if subCategory == Self.lastSubCategory, let cached = Self.versionManifestCache {
            return cached
        }
        let versions = await Self.fetchMergedVersionManifest()
        guard !versions.isEmpty else { return Self.versionManifestCache ?? [] }
        let filtered: [[String: Any]]
        switch subCategory {
        case .release:
            // 正式版：所有 type == "release" 的版本（不截断，包含 1.7.x、1.8、1.12.2 等老版本）
            filtered = versions.filter { ($0["type"] as? String) == "release" }
        case .snapshot:
            // 快照：标准快照 + 未列出的 pending（combat/实验快照），排除愚人节版本（它们归到远古版）
            filtered = versions.filter { v in
                let t = v["type"] as? String ?? ""
                let id = v["id"] as? String ?? ""
                return (t == "snapshot" || t == "pending") && !Self.isAprilFoolVersion(id: id, type: t)
            }
        case .ancient:
            // 远古版：alpha/beta + 愚人节版本（参考 PCL.Mac）
            filtered = versions.filter {
                let t = $0["type"] as? String ?? ""
                let id = $0["id"] as? String ?? ""
                return t == "old_alpha" || t == "old_beta" || Self.isAprilFoolVersion(id: id, type: t)
            }
        case .none:
            filtered = []
        }
        let result = filtered.map { v in
            DownloadedItem(
                id: v["id"] as? String ?? UUID().uuidString,
                name: v["id"] as? String ?? "未知",
                subtitle: displayTitle,
                iconURL: nil,
                tags: []
            )
        }
        Self.versionManifestCache = result
        Self.lastSubCategory = subCategory
        return result
    }

    private func fetchRawModrinthItems(type: String, label: String, query: String = "", offset: Int = 0, limit: Int = 30) async -> (items: [DownloadedItem], totalHits: Int) {
        var components = URLComponents(string: "https://api.modrinth.com/v2/search")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "facets", value: "[[\"project_type:\(type)\"]]")
        ]
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return ([], 0) }
        var req = URLRequest(url: url)
        req.setValue("Swim111Launcher/1.0 (Minecraft Launcher)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else {
            return ([], 0)
        }
        let totalHits = json["total_hits"] as? Int ?? hits.count
        let items = hits.map { hit in
            let projectId = hit["project_id"] as? String ?? hit["slug"] as? String ?? UUID().uuidString
            let categories = hit["categories"] as? [String] ?? []
            return DownloadedItem(
                id: projectId,
                name: hit["title"] as? String ?? "未知\(label)",
                subtitle: hit["description"] as? String ?? "",
                iconURL: hit["icon_url"] as? String,
                tags: categories
            )
        }
        return (items, totalHits)
    }

    private var gameSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader(.game, expanded: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(GameSubCategory.allCases.enumerated()), id: \.element.id) { i, sub in
                    sidebarSubItem(sub, idx: 1 + i)
                }
            }

            ForEach(Array(GameSidebarSection.allCases.dropFirst().enumerated()), id: \.element.id) { i, section in
                sidebarSectionHeader(section, expanded: false)
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 0.5)
                )
                .padding(.horizontal, 6)
                .frame(height: 30)
                .offset(y: sectionHighlightY + 3)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: sectionHighlightY),
            alignment: .topLeading
        )
        // 启动器毛玻璃风格：左侧栏整体包成圆角矩形毛玻璃卡片（四周留 8pt 间隙）
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func sidebarSectionHeader(_ section: GameSidebarSection, expanded: Bool) -> some View {
        Button(action: {
            if section == .game { selectSection(section, sub: .release) }
            else { selectSection(section, sub: nil) }
        }) {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selectedSection == section ? theme.accentColor : .secondary)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selectedSection == section ? .primary : .secondary)
                Spacer()
                if section == .game {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarSubItem(_ sub: GameSubCategory, idx: Int) -> some View {
        Button(action: { selectSection(.game, sub: sub) }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor)
                    .frame(width: 3, height: 14)
                    .opacity(selectedSubCategory == sub ? 1 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: selectedSubCategory)
                Text(sub.rawValue)
                    .font(.system(size: 12))
                    .foregroundColor(selectedSubCategory == sub ? .primary : .secondary)
                Spacer()
            }
            .padding(.leading, 42)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(subItemOpacity[sub] ?? 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: subItemOpacity[sub] ?? 0)
    }
}

struct GameCategoryView: View {
    @EnvironmentObject var settings: LauncherSettings
    @ObservedObject var theme = ThemeManager.shared
    @State private var isLoading = true
    @State private var showCard = false
    @State private var loadingText = "游戏检索中"
    @State private var dotCount = 1
    @State private var versions: [String] = []
    @State private var hasVersions = false
    @State private var scanTimedOut = false
    @State private var showJavaPicker = false
    @State private var loadingTimer: Timer?

    private var javaPickerLabel: String {
        if let path = settings.selectedJavaPath {
            let list = settings.availableJavaList
            if let info = list.first(where: { $0.path == path }) {
                return "Java \(info.majorVersion)"
            }
            return "Java 自定义"
        }
        if settings.isJavaScanning {
            return "扫描中..."
        }
        if settings.availableJavaList.isEmpty {
            return "自动选择 Java"
        }
        return "自动选择 Java"
    }

    var body: some View {
        ZStack {
            if isLoading {
                Text(loadingText + String(repeating: ".", count: dotCount))
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.primary)
                    .transition(.opacity)
            }
            if showCard {
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 16) {
                            if hasVersions {
                                Text("选择游戏版本").font(.headline).foregroundColor(.secondary).padding(.bottom, 4)
                                ForEach(versions, id: \.self) { version in
                                    VersionButton(title: version, isSelected: settings.selectedMinecraftVersion == version) {
                                        withAnimation(.explosiveSpring) {
                                            settings.selectedMinecraftVersion = version
                                        }
                                    }
                                }
                            } else {
                                VStack(spacing: 20) {
                                    Text("未找到游戏版本").font(.headline).foregroundColor(.secondary)
                                    Text("请将 Minecraft 游戏文件夹（包含 versions 目录）放入常用目录（文稿、下载等），或手动选择")
                                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                                    Button(action: openFolderPicker) {
                                        Text("寻找版本")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(.primary)
                                            .frame(width: 160, height: 40)
                                            .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial).shadow(radius: 2))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 12)
                            }
                        }
                        .padding(24)
                        .frame(minWidth: 280)
                        .background(RoundedRectangle(cornerRadius: 24).fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 5))
                        .overlay(alignment: .topTrailing) {
                            if hasVersions {
                                Button(action: { showJavaPicker = true }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "cup.and.saucer.fill")
                                            .font(.system(size: 9))
                                            .foregroundColor(theme.accentColor)
                                        Text(javaPickerLabel)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $showJavaPicker, arrowEdge: .trailing) {
                                    JavaPickerView(selectedJavaPath: $settings.selectedJavaPath)
                                        .environmentObject(settings)
                                }
                                .padding([.top, .trailing], 10)
                            }
                        }
                        Spacer()
                    }
                    if (hasVersions || (versions.isEmpty && !isLoading)) {
                        VStack(spacing: 8) {
                            Button(action: openFolderPicker) {
                                Text("添加文件夹")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(theme.accentColor, lineWidth: 1)
                                            .background(.ultraThinMaterial)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            Button(action: {
                                isLoading = true
                                Task.detached(priority: .userInitiated) {
                                    let roots = await MinecraftVersionManager.asyncFullDiskScanForGames()
                                    let count = roots.count
                                    await MainActor.run {
                                        isLoading = false
                                        showCard = true
                                        settings.javaPopupMessage = "已找到 \(count) 个游戏"
                                        settings.showJavaPopup = true
                                        if let first = roots.first {
                                            let vlist = MinecraftVersionManager.getVersions(from: first)
                                            if !vlist.isEmpty {
                                                versions = vlist
                                                settings.selectedGameRoot = first
                                                settings.selectedMinecraftVersion = vlist.first ?? ""
                                                hasVersions = true
                                            }
                                        }
                                    }
                                }
                            }) {
                                Text("全盘查找游戏")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.4), value: showCard)
        .animation(.easeOut(duration: 0.4), value: isLoading)
        .onChange(of: isLoading) { newValue in
            if newValue { startLoadingAnimation() }
            else { stopLoadingAnimation() }
        }
        .onAppear {
            startScanning()
        }
        .onDisappear {
            loadingTimer?.invalidate()
            loadingTimer = nil
        }
    }

    private func startLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                self.dotCount = (self.dotCount % 4) + 1
            }
        }
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    private func startScanning() {
        isLoading = true; showCard = false; hasVersions = false; scanTimedOut = false
        let scanTask = Task.detached(priority: .userInitiated) { () -> (root: String, versions: [String])? in
            let savedRoot = await MainActor.run { settings.selectedGameRoot }
            if !savedRoot.isEmpty, FileManager.default.fileExists(atPath: savedRoot + "/versions") {
                let versions = MinecraftVersionManager.getVersions(from: savedRoot)
                if !versions.isEmpty { return (savedRoot, versions) }
            }
            if let result = await MinecraftVersionManager.asyncFindFirstValidGame() { return result }
            else { return nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if isLoading && !scanTimedOut {
                scanTimedOut = true
                withAnimation(.easeOut(duration: 0.8)) { showCard = true; hasVersions = false; isLoading = false }
            }
        }
        Task {
            let result = await scanTask.value
            await MainActor.run {
                if !scanTimedOut {
                    if let (root, versionList) = result, !versionList.isEmpty {
                        versions = versionList
                        if settings.selectedGameRoot.isEmpty || settings.selectedGameRoot != root { settings.selectedGameRoot = root }
                        if settings.selectedMinecraftVersion.isEmpty || !versionList.contains(settings.selectedMinecraftVersion) {
                            settings.selectedMinecraftVersion = versions.first ?? ""
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: NSNotification.Name("GameVersionSelected"), object: nil)
                            }
                        }
                        hasVersions = true
                    } else { hasVersions = false }
                    withAnimation(.easeOut(duration: 0.8)) { showCard = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeOut(duration: 0.4)) { isLoading = false }
                    }
                }
            }
        }
    }

    private func openFolderPicker() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择 Minecraft 游戏根目录（包含 versions 文件夹的目录）"
        openPanel.message = "请选择一个包含 versions 子目录的文件夹"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                let chosenPath = url.path
                let versionsPath = chosenPath + "/versions"
                if FileManager.default.fileExists(atPath: versionsPath) {
                    let versionList = MinecraftVersionManager.getVersions(from: chosenPath)
                    if !versionList.isEmpty {
                        versions = versionList
                        settings.selectedGameRoot = chosenPath
                        settings.selectedMinecraftVersion = versions.first ?? ""
                        hasVersions = true
                    } else {
                        settings.launchErrorMessage = "所选文件夹的 versions 目录下没有找到任何版本"
                        settings.showLaunchAlert = true
                    }
                } else {
                    settings.launchErrorMessage = "所选文件夹不包含 versions 子目录"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
}
