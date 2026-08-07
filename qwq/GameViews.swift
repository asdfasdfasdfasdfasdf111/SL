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
    @State private var lastAnchorItemID: String? = nil
    @State private var searchPopInIds: Set<String> = []
    @State private var selectedModItem: DownloadedItem? = nil
    @State private var showDetail = false
    @State private var geometryWidth: CGFloat = 0

    // 分页加载状态
    @State private var currentOffset = 0
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var activeSearchQuery = ""

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
                    searchPopInIds = []
                }
                return
            }
            // 其余分类：优先本地全量目录过滤（标题/简介/标签，含中文标签直接匹配）
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
                    searchPopInIds = []
                }
                startSequentialTranslation(for: filtered)
                return
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
        .onChange(of: searchText) { _ in applyFilter() }
        .onChange(of: items) { newItems in
            filteredResults = newItems
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
                    ForEach(filteredResults) { item in
                        ContentCard(
                            title: item.name,
                            subtitle: translatedSubtitles[item.id] ?? item.subtitle,
                            cardWidth: cardWidth,
                            tags: item.tags,
                            action: { openDetail(item) }
                        )
                        .id(item.id)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear {
                                        trackVisibility(item, geo)
                                    }
                            }
                        )
                    }
                }
                .padding(.horizontal, cardPadding)
                .padding(.bottom, cardPadding)
            }
            .coordinateSpace(name: "listScroll")
            .onAppear {
                if let id = lastAnchorItemID {
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
        }
    }

    /// 卡片进入可视区域时：更新滚动恢复锚点，并按需发起翻译
    private func trackVisibility(_ item: DownloadedItem, _ geo: GeometryProxy) {
        let frame = geo.frame(in: .named("listScroll"))
        if frame.minY > -60 && frame.minY < 160 {
            lastAnchorItemID = item.id
        }
        requestTranslation(for: item)
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
        if selectedSection != .game {
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

    /// 批量应用磁盘翻译缓存（全量遍历仅查内存缓存，速度快）；网络翻译由卡片可见性按需触发
    private func startSequentialTranslation(for items: [DownloadedItem]) {
        translateTask?.cancel()
        let service = TranslationService.shared
        translateTask = Task.detached(priority: .background) {
            var batch: [String: String] = [:]
            for item in items {
                if Task.isCancelled { return }
                if let cached = service.cachedTranslation(for: item.id), !cached.isEmpty {
                    batch[item.id] = cached
                }
            }
            if !batch.isEmpty {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    for (id, text) in batch {
                        if !text.isEmpty, Self.isViewActive {
                            self.translatedSubtitles[id] = text
                        }
                    }
                }
            }
        }
    }

    /// 按需翻译单个卡片：缓存命中直接应用，否则排队翻译（滚动到哪翻译到哪）
    private func requestTranslation(for item: DownloadedItem) {
        let id = item.id
        guard !id.isEmpty, translatedSubtitles[id] == nil, !pendingTranslationIDs.contains(id) else { return }
        let service = TranslationService.shared
        if let cached = service.cachedTranslation(for: id), !cached.isEmpty {
            translatedSubtitles[id] = cached
            return
        }
        pendingTranslationIDs.insert(id)
        let subtitle = item.subtitle
        Task.detached(priority: .background) {
            do {
                let translated = try await service.translateText(text: subtitle, projectId: id)
                await MainActor.run {
                    self.pendingTranslationIDs.remove(id)
                    if !translated.isEmpty, Self.isViewActive {
                        self.translatedSubtitles[id] = translated
                    }
                }
            } catch {
                await MainActor.run {
                    self.pendingTranslationIDs.remove(id)
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
    }

    // MARK: - 版本清单合并（官方 + 未列出，并发拉取）

    private static let officialManifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest.json")!
    private static let unlistedManifestURL = URL(string: "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto/version_manifest.json")!
    private static let unlistedManifestRoot = "https://zkitefly.github.io/unlisted-versions-of-minecraft"
    private static let unlistedManifestMirrorRoot = "https://alist.8mi.tech/d/mirror/unlisted-versions-of-minecraft/Auto"

    private static var mergedManifestCache: [[String: Any]]?
    private static var mergedManifestFetchDate: Date?

    /// 并发拉取官方 + 未列出版本清单并合并（按 releaseTime 降序；未列出版本 URL 重写到 alist 镜像）
    fileprivate static func fetchMergedVersionManifest() async -> [[String: Any]] {
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

    struct LocalCatalogItem {
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

    /// 从 bundle 读取 modrinth_catalog.json.gz 并解析（全量目录缓存）
    nonisolated static func loadLocalCatalog() -> [LocalCatalogItem] {
        localCatalogLock.lock()
        defer { localCatalogLock.unlock() }
        if let localCatalog { return localCatalog }
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

    /// 后台预加载四类本地目录，避免首次切页时阻塞主线程
    private static func preloadLocalCatalog() {
        Task.detached(priority: .utility) {
            _ = localItems(for: .mod)
            _ = localItems(for: .resourcePack)
            _ = localItems(for: .shader)
            _ = localItems(for: .modpack)
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

struct ContentCard: View {
    let title: String
    let subtitle: String
    let cardWidth: CGFloat
    var tags: [String] = []
    var action: (() -> Void)? = nil
    @ObservedObject var theme = ThemeManager.shared
    @State private var scale: CGFloat = 1.0

    private var translatedTags: [String] {
        tags.compactMap { ModrinthTagMap[$0] }
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { scale = 1.06 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { scale = 1.0 }
            }
            action?()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if !translatedTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(translatedTags.prefix(6), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(theme.accentColor.opacity(0.8))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(theme.accentColor.opacity(0.12))
                                    )
                            }
                        }
                    }
                    .scrollBounceIfAvailable()
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: cardWidth, height: cardWidth * 0.55)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(.spring(response: 0.4, dampingFraction: 0.5), value: scale)
    }
}

enum DetailPageType {
    case resourcePack
    case mod
    case shader
    case modpack
    case loaderSelector

    var titleText: String {
        switch self {
        case .resourcePack, .mod, .shader:
            return "你拥有的受支持的版本"
        case .modpack:
            return "请选择下载版本"
        case .loaderSelector:
            return "请选择下载的模组加载器"
        }
    }

    var supportedVersionTitle: String {
        switch self {
        case .resourcePack:
            return "此资源包目前严格意义上支持的游戏版本"
        case .mod:
            return "此模组支持的游戏版本"
        case .shader:
            return "此光影目前严格意义上支持的游戏版本"
        default:
            return ""
        }
    }

    var isCrossVersionDownload: Bool {
        switch self {
        case .resourcePack, .shader:
            return true
        default:
            return false
        }
    }
}

struct ModDetailView: View {
    let item: DownloadedItem
    let pageType: DetailPageType
    let onClose: () -> Void
    var onNavigateToMod: ((DownloadedItem) -> Void)? = nil
    var gameSubCategory: GameSubCategory? = nil

    @ObservedObject var theme = ThemeManager.shared
    @ObservedObject var settings = LauncherSettings.shared

    @State private var selectedVersion: String = ""
    @State private var selectedLoader: String = "fabric"
    @State private var sortedVersions: [String] = []
    @State private var hasShaderFolder: Bool = false
    @State private var shaderFolderChecked: Bool = false
    @State private var manifestVersions: [String] = []

    @State private var prerequisiteStack: [DownloadedItem] = []
    @State private var navSlideOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0

    @State private var entryScale: CGFloat = 0.85
    @State private var entryOpacity: Double = 0

    @State private var isDownloading = false
    @State private var bounceScale: CGFloat = 1.0

    // 外部绑定：圆形毛玻璃按钮在最外层视图上，跨页面保留
    @Binding var showCircleButton: Bool
    @Binding var circleScale: CGFloat
    @Binding var circleOpacity: Double

    @State private var modpackVersions: [ModpackVersion] = []
    @State private var isLoadingModpackVersions = false
    @State private var selectedModpackVersionId: String = ""
    @State private var cachedUniqueVersions: [(gameVersion: String, version: ModpackVersion)]? = nil

    @State private var localVersionLoaders: [String: ModLoader] = [:]
    @State private var hasScannedLocalVersions = false


    @State private var translatedSubtitles: [String: String] = [:]
    @State private var projectGameVersions: [String] = []
    @State private var projectLoaders: [String] = []
    @State private var isLoadingProject = false

    @State private var availableLoaders: [String] = []
    @State private var isLoadingLoaders = false

    private static let loaderAssetMap: [String: String] = [
        "fabric": "fabric", "forge": "Forge", "neoforge": "NeoForged",
        "neoforged": "NeoForged", "quilt": "Quilt", "rift": "fabric"
    ]

    private func assetName(for loader: String) -> String {
        Self.loaderAssetMap[loader.lowercased()] ?? "fabric"
    }

    private func fetchProjectDetails() {
        guard !item.id.isEmpty, projectGameVersions.isEmpty else { return }
        isLoadingProject = true
        Task {
            do {
                let downloader = ModDownloader()
                let project = try await downloader.getProject(modId: item.id)
                await MainActor.run {
                    projectGameVersions = project.game_versions ?? []
                    projectLoaders = project.loaders ?? []
                    isLoadingProject = false
                    // 模组/光影/资源包页：版本列表规则如下——
                    // 1. 模组(.mod)：版本列表 = 本地已安装版本 ∩ API 返回的兼容版本，
                    //    即先看本地 versions 文件夹有哪些版本，再筛出该模组兼容的版本，全部列出来。
                    // 2. 资源包/光影(.shader/.resourcePack)：跨版本可用，
                    //    直接显示本地已安装的全部版本，并默认选中最近的版本（当前实例版本优先，其次最新）。
                    if pageType == .mod {
                        if !projectGameVersions.isEmpty {
                            // 本地已安装的版本（用于求交集）
                            let ownedSet = Set(localOwnedVersions())
                            // 交集：本地拥有且该模组兼容的版本
                            let compatible = projectGameVersions.filter { ownedSet.contains($0) }
                            if !compatible.isEmpty {
                                // 只显示本地拥有且模组兼容的版本，全部列出
                                sortedVersions = sortVersionsForDisplay(compatible)
                                if let first = sortedVersions.first {
                                    selectedVersion = first
                                }
                            }
                            // 如果本地没有任何兼容版本，保留本地版本列表（不覆盖），
                            // 方便用户看到本地拥有的全部版本。
                        }
                    } else if pageType == .shader || pageType == .resourcePack {
                        // 跨版本内容：本地拥有的全部版本都列出来，默认选最近的版本
                        let owned = localOwnedVersions()
                        if !owned.isEmpty {
                            sortedVersions = sortVersionsForDisplay(owned)
                            if let first = sortedVersions.first {
                                selectedVersion = first
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { isLoadingProject = false }
            }
        }
    }

    private var versionRangeText: String {
        guard !projectGameVersions.isEmpty else { return "" }
        let sorted = projectGameVersions.sorted { compareVersions($0, $1) < 0 }
        if let first = sorted.first, let last = sorted.last {
            return first == last ? first : "\(first)-\(last)"
        }
        return sorted.first ?? ""
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                ForEach(Array(allPages.enumerated()), id: \.offset) { index, pageItem in
                    detailPageContent(
                        item: pageItem,
                        pageTypeForIndex: index == 0 ? pageType : .mod,
                        isBasePage: index == 0
                    )
                    .frame(width: width)
                    .offset(x: navSlideOffset + CGFloat(index) * width)
                    .clipped()
                }
            }
            .clipped()
            .onAppear {
                withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 240, damping: 14, initialVelocity: 8)) {
                    entryScale = 1.0
                    entryOpacity = 1.0
                    pageWidth = width
                }
                if sortedVersions.isEmpty {
                    if (pageType == .mod || pageType == .shader || pageType == .resourcePack), !hasScannedLocalVersions {
                        scanLocalVersions()
                    }
                    sortedVersions = availableVersions
                    
                    // 默认选中：优先当前实例版本，其次第一个可用版本
                    if let defaultInstanceVersion = getDefaultInstanceVersion(),
                       sortedVersions.contains(defaultInstanceVersion) {
                        selectedVersion = defaultInstanceVersion
                    } else if let first = sortedVersions.first {
                        selectedVersion = first
                    }
                }
                // 游戏版本页：异步获取 Mojang 版本清单
                if pageType == .loaderSelector && manifestVersions.isEmpty {
                    fetchManifestVersions()
                }
                if pageType == .shader, !shaderFolderChecked {
                    checkShaderFolders()
                }
                if pageType == .modpack, modpackVersions.isEmpty {
                    fetchModpackVersions()
                }
                if !item.id.isEmpty {
                    translateDetailDescription()
                    fetchProjectDetails()
                }
            }
            .onChange(of: geometry.size.width) { pageWidth = $0 }
            .onChange(of: selectedVersion) { newValue in
                if pageType == .loaderSelector {
                    fetchLoaderSupport(for: newValue)
                }
            }
        }
        .scaleEffect(entryScale)
        .opacity(entryOpacity)
        // 页面框架与背景不动（左侧贴紧分类栏边界）。
        // 内容距左侧的间距由 detailPageContent 内容层 .padding(.leading) 单独控制，
        // 保证页面背景从左边缘正常渲染，仅内容文字右移（含返回、标题、下载按钮）。
        .padding(.top, 20)
        .padding(.bottom, 20)
        .padding(.trailing, 20)
        .overlay(alignment: .bottomTrailing) {
            // 下载按钮：初始在右下角，圆按钮出现后动画左移
            if !selectedVersion.isEmpty {
                Button(action: { startDownload() }) {
                    Text("下载")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 120)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .scaleEffect(bounceScale)
                .padding(.trailing, showCircleButton ? 88 : 12)
                .padding(.bottom, 12)
                .animation(.interpolatingSpring(stiffness: 170, damping: 14), value: showCircleButton)
            }
        }
    }

    private var allPages: [DownloadedItem] {
        [item] + prerequisiteStack
    }

    private var baseVersions: [String] {
        ["1.21.4", "1.21.1", "1.18", "1.19.1"]
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
        // 旧版标准快照格式（如 23w33a）：正式快照，非愚人节
        let oldSnapshotPattern = #"^[0-9]{2}w[0-9]{2}[a-z]$"#
        if normalized.range(of: oldSnapshotPattern, options: .regularExpression) != nil { return false }
        // 至少有一个字母（筛掉 1.x 与 1.x.x），且不是 -pre/-rc
        if normalized.rangeOfCharacter(from: .letters) == nil { return false }
        if normalized.contains("-pre") || normalized.contains("-rc") { return false }
        return true
    }

    private func fetchManifestVersions() {
        Task {
            let versions = await DownloadCategoryView.fetchMergedVersionManifest()
            guard !versions.isEmpty else { return }
            let filtered: [String]
            switch gameSubCategory {
            case .release:
                filtered = versions.filter { ($0["type"] as? String) == "release" }
                    .compactMap { $0["id"] as? String }
            case .snapshot:
                filtered = versions.filter { v in
                    let t = v["type"] as? String ?? ""
                    let id = v["id"] as? String ?? ""
                    return (t == "snapshot" || t == "pending") && !Self.isAprilFoolVersion(id: id, type: t)
                }.compactMap { $0["id"] as? String }
            case .ancient:
                filtered = versions.filter {
                    let t = $0["type"] as? String ?? ""
                    let id = $0["id"] as? String ?? ""
                    return t == "old_alpha" || t == "old_beta" || Self.isAprilFoolVersion(id: id, type: t)
                }.compactMap { $0["id"] as? String }
            case .none:
                filtered = []
            }
            await MainActor.run {
                manifestVersions = filtered
                sortedVersions = availableVersions
                if let first = sortedVersions.first {
                    selectedVersion = first
                }
            }
        }
    }

    // 加载器支持检测：内存缓存，避免同一版本反复联网请求（PCL 速度来源之一）。
    // 键 = 游戏版本（如 "26.2"），值 = 该版本支持的加载器显示名列表（已按 loaderOrder 排序）。
    private static var loaderSupportCache: [String: [String]] = [:]

    private static let loaderOrder = ["Fabric", "Forge", "NeoForged", "Quilt"]

    private func fetchLoaderSupport(for version: String) {
        guard !version.isEmpty else { return }
        // 命中本地缓存：直接使用，不联网，秒级返回
        if let cached = Self.loaderSupportCache[version] {
            availableLoaders = cached
            isLoadingLoaders = false
            if !cached.contains(selectedLoader), let first = cached.first {
                selectedLoader = first
            }
            return
        }
        // 未命中缓存：联网并发检测
        isLoadingLoaders = true
        Task {
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
                        let ok = await self.checkLoaderSupport(key: candidate.key, version: version)
                        return (candidate.display, ok)
                    }
                }
                for await (display, ok) in group where ok {
                    supported.append(display)
                }
            }
            supported.sort {
                (Self.loaderOrder.firstIndex(of: $0) ?? 99) < (Self.loaderOrder.firstIndex(of: $1) ?? 99)
            }
            // 写入内存缓存，同版本下次直接命中
            Self.loaderSupportCache[version] = supported
            await MainActor.run {
                availableLoaders = supported
                isLoadingLoaders = false
                if !supported.contains(selectedLoader), let first = supported.first {
                    selectedLoader = first
                }
            }
        }
    }

    private func checkLoaderSupport(key: String, version: String) async -> Bool {
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
        // 加载器 API（bmclapi / quilt meta）在高峰期不稳定，可能偶发超时或 5xx。
        // 参考 PCL.Mac：不设置过短的超时，并对「可用端点列表」逐个尝试；
        // 每个端点最多重试 2 次，只要任意一次返回非空数组即视为支持。
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

    /// 读取本地游戏根目录 versions 文件夹，返回本地实际安装的有效版本列表。
    /// 有效版本 = 目录中存在同名 .jar 或 .json 文件。
    /// 注意：这里只做「本地拥有」判断，不做任何加载器/兼容性过滤，
    /// 模组兼容性过滤由 fetchProjectDetails 结合 API 的 game_versions 求交集完成。
    private func localOwnedVersions() -> [String] {
        let gameRoot = settings.selectedGameRoot
        guard !gameRoot.isEmpty else { return [] }
        let versionsPath = gameRoot + "/versions"
        guard let versionDirs = try? FileManager.default.contentsOfDirectory(atPath: versionsPath) else { return [] }
        return versionDirs.filter { dir in
            let jarPath = "\(versionsPath)/\(dir)/\(dir).jar"
            let jsonPath = "\(versionsPath)/\(dir)/\(dir).json"
            return FileManager.default.fileExists(atPath: jarPath) || FileManager.default.fileExists(atPath: jsonPath)
        }
    }

    /// 版本下拉列表的版本来源（仅决定「有哪些版本可显示」，不做过滤）：
    /// - 游戏版本页（加载器选择器）：优先使用 Mojang manifest 获取的版本列表
    /// - 其他页面：显示本地 versions 文件夹里实际安装的版本
    /// - 本地没有任何版本时：回退到默认版本列表
    private var availableVersions: [String] {
        // 游戏版本页：优先使用 Mojang manifest 获取的版本列表
        if pageType == .loaderSelector && !manifestVersions.isEmpty {
            return sortVersionsForDisplay(manifestVersions)
        }
        // 本地实际安装的版本
        let owned = localOwnedVersions()
        if !owned.isEmpty {
            return sortVersionsForDisplay(owned)
        }
        return sortVersionsForDisplay(baseVersions)
    }

    private func scanLocalVersions() {
        hasScannedLocalVersions = true
        let gameRoot = settings.selectedGameRoot
        guard !gameRoot.isEmpty else { return }
        let versionsPath = gameRoot + "/versions"
        guard let versionDirs = try? FileManager.default.contentsOfDirectory(atPath: versionsPath) else { return }
        for versionDir in versionDirs.prefix(10) {
            let modsPath = "\(versionsPath)/\(versionDir)/mods"
            guard let modFiles = try? FileManager.default.contentsOfDirectory(atPath: modsPath) else { continue }
            var scannedCount = 0
            for modFile in modFiles where modFile.hasSuffix(".jar") {
                guard scannedCount < 3 else { break }
                let jarURL = URL(fileURLWithPath: "\(modsPath)/\(modFile)")
                let loader = ModLoaderDetector.detect(from: jarURL)
                if loader != .unknown {
                    localVersionLoaders[versionDir] = loader
                    break
                }
                scannedCount += 1
            }
        }
    }

    private func getDefaultInstanceVersion() -> String? {
        // 从 LauncherSettings 获取当前选中的版本
        let selectedVersion = settings.selectedMinecraftVersion
        if !selectedVersion.isEmpty {
            return selectedVersion
        }
        return nil
    }

    private func fetchModpackVersions() {
        guard !item.id.isEmpty else { return }
        isLoadingModpackVersions = true
        Task {
            do {
                let downloader = ModpackDownloader()
                let versions = try await downloader.versions(packId: item.id)
                await MainActor.run {
                    modpackVersions = versions
                    cachedUniqueVersions = nil // 清除缓存以重新计算
                    isLoadingModpackVersions = false
                    let unique = uniqueGameVersions()
                    if let first = unique.first {
                        selectedModpackVersionId = first.version.id
                        selectedVersion = first.gameVersion
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingModpackVersions = false
                }
            }
        }
    }

    private func uniqueGameVersions() -> [(gameVersion: String, version: ModpackVersion)] {
        if let cached = cachedUniqueVersions { return cached }
        var seen: Set<String> = []
        var result: [(String, ModpackVersion)] = []
        for v in modpackVersions {
            if let gv = v.game_versions.first, !seen.contains(gv) {
                seen.insert(gv)
                result.append((gv, v))
            }
        }
        let sorted = result.sorted(by: { a, b in
            compareVersions(a.0, b.0) > 0
        })
        cachedUniqueVersions = sorted
        return sorted
    }

    private func sortVersionsForDisplay(_ versions: [String]) -> [String] {
        let gameSelected = settings.selectedMinecraftVersion
        var sorted = versions.sorted { compareVersions($0, $1) > 0 }
        if !gameSelected.isEmpty, let idx = sorted.firstIndex(of: gameSelected) {
            sorted.remove(at: idx)
            sorted.insert(gameSelected, at: 0)
        }
        return sorted
    }

    private func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va - vb }
        }
        return 0
    }

    private func checkShaderFolders() {
        shaderFolderChecked = true
        let gameRoot = settings.selectedGameRoot
        guard !gameRoot.isEmpty else {
            hasShaderFolder = false
            return
        }
        for version in baseVersions {
            let shaderPath = "\(gameRoot)/versions/\(version)/shaderpacks"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: shaderPath, isDirectory: &isDir), isDir.boolValue {
                hasShaderFolder = true
                return
            }
        }
        let globalShaderPath = "\(gameRoot)/shaderpacks"
        var isDir: ObjCBool = false
        hasShaderFolder = FileManager.default.fileExists(atPath: globalShaderPath, isDirectory: &isDir) && isDir.boolValue
    }

    private func findCrossVersionDownload(for targetVersion: String) -> String? {
        let sorted = sortedVersions.filter { $0 != targetVersion }
        let targetIdx = sorted.firstIndex(of: targetVersion)
        var candidates = sorted
        if let idx = targetIdx {
            let above = Array(sorted[0..<idx]).reversed()
            let below = Array(sorted[(idx + 1)...])
            candidates = above + below
        }
        for candidate in candidates {
            if pageType == .resourcePack {
                let gameRoot = settings.selectedGameRoot
                let rpPath = "\(gameRoot)/versions/\(candidate)/resourcepacks"
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: rpPath, isDirectory: &isDir), isDir.boolValue {
                    return candidate
                }
            } else if pageType == .shader {
                let gameRoot = settings.selectedGameRoot
                let spPath = "\(gameRoot)/versions/\(candidate)/shaderpacks"
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: spPath, isDirectory: &isDir), isDir.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }

    private func navigateToPrerequisite(_ prereq: DownloadedItem) {
        onNavigateToMod?(prereq)
        prerequisiteStack.append(prereq)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            navSlideOffset -= pageWidth
        }
    }

    private func goBack() {
        if !prerequisiteStack.isEmpty {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                navSlideOffset += pageWidth
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !prerequisiteStack.isEmpty {
                    prerequisiteStack.removeLast()
                }
            }
        } else {
            onClose()
        }
    }

    private func startDownload() {
        guard !selectedVersion.isEmpty else { return }
        isDownloading = true
        
        // 下载按钮弹动画（放大 → 缩小回弹，不消失）
        withAnimation(.interpolatingSpring(stiffness: 220, damping: 14)) {
            bounceScale = 1.25
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.interpolatingSpring(stiffness: 200, damping: 16)) {
                bounceScale = 0.92
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.interpolatingSpring(stiffness: 220, damping: 18)) {
                bounceScale = 1.0
            }
        }
        
        // 圆形毛玻璃按钮弹入（通过绑定作用在最外层视图）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            showCircleButton = true
            withAnimation(.interpolatingSpring(stiffness: 170, damping: 14)) {
                circleScale = 1.0
                circleOpacity = 1.0
            }
        }
        
        // 真正的下载逻辑
        Task.detached(priority: .userInitiated) {
            do {
                switch pageType {
                case .mod:
                    try await downloadMod()
                case .shader:
                    try await downloadShader()
                case .resourcePack:
                    try await downloadResourcePack()
                case .modpack:
                    try await downloadModpack()
                case .loaderSelector:
                    // 游戏版本页不需要下载
                    break
                }
                await MainActor.run {
                    isDownloading = false
                    settings.javaPopupMessage = "下载完成"
                    settings.showJavaPopup = true
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    settings.launchErrorMessage = "下载失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
    
    private func downloadMod() async throws {
        guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "模组 ID 为空"]) }
        
        let settings = LauncherSettings.shared
        let gameVersion = selectedVersion
        let gameRoot = settings.selectedGameRoot
        
        guard !gameVersion.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择游戏版本"]) }
        guard !gameRoot.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未设置游戏根目录"]) }
        
        let modsDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("mods")
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        
        let downloader = ModDownloader()
        
        // 使用选中的加载器
        let loader: ModLoader
        switch selectedLoader.lowercased() {
        case "fabric": loader = .fabric
        case "forge": loader = .forge
        case "neoforge", "neoforged": loader = .neoforge
        case "quilt": loader = .quilt
        default: loader = .fabric
        }
        
        _ = try await downloader.downloadLatestMod(modId: item.id, gameVersion: gameVersion, loader: loader, destination: modsDir)
    }
    
    private func downloadShader() async throws {
        guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "光影 ID 为空"]) }
        
        let settings = LauncherSettings.shared
        let gameVersion = selectedVersion
        let gameRoot = settings.selectedGameRoot
        
        guard !gameVersion.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择游戏版本"]) }
        guard !gameRoot.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未设置游戏根目录"]) }
        
        // 光影通常放在 shaderpacks 文件夹
        let shaderDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("shaderpacks")
        try FileManager.default.createDirectory(at: shaderDir, withIntermediateDirectories: true)
        
        // 光影通常是 Fabric/Quilt 模组形式分发，尝试用 ModDownloader
        let downloader = ModDownloader()
        
        // 光影加载器通常是 iris/optifine，尝试作为 fabric 模组下载
        _ = try await downloader.downloadLatestMod(modId: item.id, gameVersion: gameVersion, loader: .fabric, destination: shaderDir)
    }
    
    private func downloadResourcePack() async throws {
        guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "资源包 ID 为空"]) }
        
        let settings = LauncherSettings.shared
        let gameVersion = selectedVersion
        let gameRoot = settings.selectedGameRoot
        
        guard !gameVersion.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择游戏版本"]) }
        guard !gameRoot.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未设置游戏根目录"]) }
        
        let resourcePackDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("resourcepacks")
        try FileManager.default.createDirectory(at: resourcePackDir, withIntermediateDirectories: true)
        
        let downloader = ModDownloader()
        _ = try await downloader.downloadLatestMod(modId: item.id, gameVersion: gameVersion, loader: .fabric, destination: resourcePackDir)
    }
    
    private func downloadModpack() async throws {
        guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "整合包 ID 为空"]) }
        
        let settings = LauncherSettings.shared
        let gameRoot = settings.selectedGameRoot
        
        guard !gameRoot.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未设置游戏根目录"]) }
        
        // 整合包下载到版本目录
        let versionDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(selectedModpackVersionId)")
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        
        let downloader = ModpackDownloader()
        let packURL = try await downloader.downloadLatest(packId: item.id, to: versionDir)
        
        // 安装整合包
        try await ModpackInstaller().install(packURL: packURL, to: URL(fileURLWithPath: gameRoot))
    }

    @ViewBuilder
    private func detailPageContent(item pageItem: DownloadedItem, pageTypeForIndex: DetailPageType, isBasePage: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: { goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .shadow(color: .black.opacity(0.08), radius: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.bottom, 10)

            Text(pageItem.name)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.primary)

            Text(translatedSubtitles[pageItem.id] ?? pageItem.subtitle)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(.bottom, 8)

            if !pageItem.tags.isEmpty {
                let translated = pageItem.tags.compactMap { ModrinthTagMap[$0] }
                if !translated.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(translated, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.accentColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(theme.accentColor.opacity(0.1))
                                    )
                            }
                        }
                    }
                    .scrollBounceIfAvailable()
                    .padding(.bottom, 24)
                } else {
                    Color.clear.frame(height: 0).padding(.bottom, 24)
                }
            } else {
                Color.clear.frame(height: 0).padding(.bottom, 24)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(pageTypeForIndex.titleText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                if pageTypeForIndex == .modpack {
                    if isLoadingModpackVersions {
                        HStack {
                            Spacer()
                            ProgressView().scaleEffect(0.8)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else {
                        let uniqueVersions = uniqueGameVersions()
                        ScrollView(.horizontal, showsIndicators: true) {
                            VStack(spacing: 12) {
                                let chunkSize = 4
                                let rows = stride(from: 0, to: uniqueVersions.count, by: chunkSize).map {
                                    Array(uniqueVersions[$0..<min($0 + chunkSize, uniqueVersions.count)])
                                }
                                ForEach(rows.indices, id: \.self) { rowIdx in
                                    HStack(spacing: 12) {
                                        ForEach(rows[rowIdx], id: \.gameVersion) { item in
                                            VersionLoaderCard(
                                                version: item.gameVersion,
                                                isSelected: selectedModpackVersionId == item.version.id,
                                                loader: assetName(for: item.version.loaders.first ?? "fabric")
                                            ) {
                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                                    selectedModpackVersionId = item.version.id
                                                    selectedVersion = item.gameVersion
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                        .scrollBounceIfAvailable()
                    }
                } else if pageTypeForIndex == .loaderSelector {
                    if isLoadingLoaders {
                        HStack {
                            Spacer()
                            ProgressView().scaleEffect(0.8)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if availableLoaders.isEmpty {
                        Text("该版本暂无可用的加载器")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(availableLoaders, id: \.self) { loader in
                                    LoaderSelectorCard(
                                        loader: loader,
                                        isSelected: selectedLoader == loader
                                    ) {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                            selectedLoader = loader
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(sortedVersions, id: \.self) { version in
                                VersionLoaderCard(
                                    version: version,
                                    isSelected: selectedVersion == version,
                                    loader: assetName(for: projectLoaders.first ?? getLoaderForVersion(version))
                                ) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                        selectedVersion = version
                                    }
                                }
                            }
                        }
                        // 水平方向预留放大动画空间（scaleEffect 1.08 放大时最左/最右卡片不被裁剪）
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                    }
                }

                if pageTypeForIndex == .shader, !hasShaderFolder, shaderFolderChecked, isBasePage {
                    shaderPrerequisiteSection
                }

                if pageTypeForIndex != .loaderSelector && pageTypeForIndex != .modpack {
                    // 光影页面：加载器只显示 Iris/OptiFine 等光影加载器，过滤模组加载器
                    let shaderOnly: Set<String> = ["iris", "optifine"]
                    // 获取模组支持的加载器
                    let rawLoaders: [String] = {
                        if !projectLoaders.isEmpty { return Array(Set(projectLoaders.map { $0.lowercased() })) }
                        return []
                    }()
                    let filteredLoaders: [String] = {
                        if pageTypeForIndex == .shader {
                            let fromProject = rawLoaders.filter { shaderOnly.contains($0.lowercased()) }
                            return fromProject.isEmpty ? ["iris", "optifine"] : fromProject
                        } else {
                            return rawLoaders
                        }
                    }()
                    if !versionRangeText.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pageTypeForIndex.supportedVersionTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                            Text(versionRangeText)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    if !filteredLoaders.isEmpty {
                        HStack(spacing: 16) {
                            ForEach(filteredLoaders, id: \.self) { loader in
                                Image(assetName(for: loader))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 28)
                                    .cornerRadius(6)
                                    .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                if pageTypeForIndex == .mod, isBasePage, let prereqs = getModPrerequisites(for: pageItem), !prereqs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("前置模组")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(prereqs, id: \.id) { prereq in
                                    PrerequisiteModCard(item: prereq) {
                                        navigateToPrerequisite(prereq)
                                    }
                                }
                            }
                        }
                    }
                }

                if let crossVersion = findCrossVersionDownload(for: selectedVersion),
                   pageTypeForIndex.isCrossVersionDownload, isBasePage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动匹配版本「\(crossVersion)」中的\(pageTypeForIndex == .resourcePack ? "资源包" : "光影")")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            // 内容距左侧 28pt：仅内容（返回、标题、正文）右移，
            // 页面背景仍从左侧分类栏边界铺满渲染（间距由内容层 padding 提供）。
            .padding(.leading, 28)
            .padding(.vertical, 8)
        }
        .padding(.bottom, 90)
        }
        }
    }

    private var shaderPrerequisiteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("光影必要的光影加载器（启动运行后起效）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    PrerequisiteModCard(
                        item: DownloadedItem(id: "AANobbMI", name: "Sodium", subtitle: "性能优化模组", iconURL: nil, tags: [])
                    ) {
                        navigateToPrerequisite(DownloadedItem(id: "AANobbMI", name: "Sodium", subtitle: "现代渲染引擎优化模组", iconURL: nil, tags: []))
                    }
                    PrerequisiteModCard(
                        item: DownloadedItem(id: "YL57xq9U", name: "Iris", subtitle: "光影加载器", iconURL: nil, tags: [])
                    ) {
                        navigateToPrerequisite(DownloadedItem(id: "YL57xq9U", name: "Iris", subtitle: "兼容Sodium的光影加载器", iconURL: nil, tags: []))
                    }
                }
            }
        }
    }

    private func getModPrerequisites(for item: DownloadedItem) -> [DownloadedItem]? {
        return nil
    }

    private func getLoaderForVersion(_ version: String) -> String {
        // 优先从本地扫描结果获取
        if let detected = localVersionLoaders[version] {
            return detected.assetName
        }
        // 从版本字符串后缀解析加载器（如 "1.20.1-Forge"、"26.3-snapshot-3-Fabric"）
        let lower = version.lowercased()
        let parts = lower.split(separator: "-")
        for part in parts.reversed() {
            let p = String(part).trimmingCharacters(in: .whitespaces)
            if let matched = Self.loaderAssetMap[p] {
                return matched
            }
        }
        // 子串模糊匹配
        if lower.contains("neoforge") || lower.contains("neoforged") { return "NeoForged" }
        if lower.contains("forge") { return "Forge" }
        if lower.contains("quilt") { return "Quilt" }
        if lower.contains("fabric") { return "fabric" }
        if lower.contains("rift") { return "fabric" }
        // 回退：使用用户选择的 loader，而非硬编码版本
        return selectedLoader
    }

    private func translateDetailDescription() {
        let pages = allPages
        let service = TranslationService.shared
        for pageItem in pages {
            let id = pageItem.id
            guard !id.isEmpty else { continue }
            if let cached = service.cachedTranslation(for: id), !cached.isEmpty {
                translatedSubtitles[id] = cached
                continue
            }
            Task.detached(priority: .background) {
                do {
                    let translated = try await service.translateText(text: pageItem.subtitle, projectId: id)
                    await MainActor.run {
                        translatedSubtitles[id] = translated
                    }
                } catch {
                    _ = error
                }
            }
        }
    }
}

struct PrerequisiteModCard: View {
    let item: DownloadedItem
    let action: () -> Void
    @State private var scale: CGFloat = 1.0
    @State private var appearOpacity: Double = 0
    @State private var appearOffset: CGFloat = 12
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 130)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .scaleEffect(scale)
        .opacity(appearOpacity)
        .offset(y: appearOffset)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.punchySpring) { scale = 1.06 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { scale = 1.0 }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                appearOpacity = 1
                appearOffset = 0
            }
        }
    }
}

struct LoaderSelectorCard: View {
    let loader: String
    let isSelected: Bool
    let action: () -> Void
    @State private var scale: CGFloat = 1.0
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 8) {
            Text(loader)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            Image(mapLoaderAsset(loader))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .cornerRadius(6)
                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? theme.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(scale)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.punchySpring) { scale = 1.08 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { scale = 1.0 }
            }
        }
    }

    private func mapLoaderAsset(_ name: String) -> String {
        let m: [String: String] = [
            "fabric": "fabric", "Fabric": "fabric",
            "forge": "Forge", "Forge": "Forge",
            "neoforge": "NeoForged", "NeoForged": "NeoForged", "neoforged": "NeoForged",
            "quilt": "Quilt", "Quilt": "Quilt",
            "rift": "fabric"
        ]
        return m[name] ?? "fabric"
    }
}

struct VersionLoaderCard: View {
    let version: String
    let isSelected: Bool
    let loader: String
    let action: () -> Void
    @State private var scale: CGFloat = 1.0
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 8) {
            Text(version)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            Image(loader)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .cornerRadius(6)
                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? theme.accentColor : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 0.5)
        )
        .scaleEffect(scale)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.punchySpring) { scale = 1.08 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { scale = 1.0 }
            }
        }
    }
}

struct GameGridCard: View {
    let title: String?
    let subtitle: String?
    let isSelected: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let scale: CGFloat
    let brightnessVal: Double
    let action: () -> Void

    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            ZStack {
                if title == nil && subtitle == nil {
                    emptyCardBase
                } else if title == "下载" {
                    emptyCardBase
                    VStack(spacing: 4) {
                        Text(title ?? "")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary)
                        Text(subtitle ?? "")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.12),
                                    theme.accentColor.opacity(0.03),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.06),
                                    Color.clear,
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer()
                        Text(title ?? "")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary)
                        Text(subtitle ?? "")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.accentColor.opacity(0.9))
                        Spacer()
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer()
                        Text(title ?? "")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary.opacity(0.6))
                        Text(subtitle ?? "")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.6))
                        Spacer()
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .brightness(brightnessVal - 1.0)
        .frame(width: cardWidth, height: cardHeight)
        .animation(.spring(response: 0.55, dampingFraction: 0.45), value: scale)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: brightnessVal)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: isSelected)
    }

    private var emptyCardBase: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            )
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
        if settings.availableJavaList.isEmpty {
            return "扫描中..."
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