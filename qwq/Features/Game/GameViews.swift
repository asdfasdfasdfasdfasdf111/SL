import SwiftUI
import AppKit
import Combine
import zlib

// ScrollBounceModifier → Core/ScrollBounceModifier.swift
// VersionButton → UI/VersionButton.swift
// JavaSelectionPopup, JavaPickerView, JavaPickerRow → UI/JavaPickerView.swift
// GameSubCategory, GameSidebarSection, ModrinthTagMap, DownloadedItem → Models/GameModels.swift
// 状态与业务决策（选中态/搜索/分页/取数）→ ViewModels/DownloadCategoryViewModel.swift

struct DownloadCategoryView: View {
    /// 主题来源由调用方注入（全局单例外部持有），本视图仅向下透传
    @ObservedObject var theme: ThemeManager

    /// 本视图的唯一状态与决策来源（对标 ContentView 的 NavigationState / DropInstallCoordinator）
    @StateObject private var viewModel = DownloadCategoryViewModel()

    // 以下均为纯视图状态：侧栏高亮位移、子项弹入透明度、内容淡入淡出
    @State private var subItemOpacity: [GameSubCategory: Double] = [
        .release: 0, .snapshot: 0, .ancient: 0
    ]
    @State private var sectionHighlightY: CGFloat = 12
    @State private var contentOpacity: Double = 1
    @State private var contentOffset: CGFloat = 0

    // 卡片副标题翻译状态与调度已下沉到 CardTranslationModel（与详情页共享同一套
    // 「内存→磁盘→网络」按需翻译流程；视图销毁后 model 不再写回，UAF 防护）。
    // 保留在视图层：状态对象由视图持有并订阅，视图模型只接收其引用以调度预取。
    @StateObject private var translationModel = CardTranslationModel()

    // 滚动锚点已随 resultsGrid 迁移到 CategoryResultsGrid（仅用于返回列表时恢复位置）

    // 下载详情页与圆按钮状态已提升到全局 DownloadDetailManager（ContentView 顶层渲染），
    // 本视图不再持有相关 @State，避免视图销毁后回调写 State 触发 UAF

    // 侧边栏高亮偏移表与 section→index 映射集中在 SidebarHighlight（与 GameSidebarView 共享）

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
                cardWidth: cardWidth
            )
        }
        .onAppear {
            viewModel.activate()
            translationModel.activate()
            ModrinthCategoryCache.loadFromDisk()
            LocalModCatalog.warmUp()
            LocalModCatalog.preTranslateAll()
            // ⚠️ onAppear 处于视图更新事务中：sectionHighlightY 是 @State、fetchItems()
            // 内部会同步写 isLoading/items/filteredResults 等状态，同步执行会触发
            // "Modifying state during view update"（UAF 前兆），整体延迟到渲染事务外执行
            DispatchQueue.main.async {
                let idx = SidebarHighlight.index(for: viewModel.selectedSection, sub: viewModel.selectedSubCategory)
                sectionHighlightY = SidebarHighlight.offsets[idx]
                viewModel.fetchItems(translation: translationModel)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    subItemOpacity[.release] = 1
                    subItemOpacity[.snapshot] = 1
                    subItemOpacity[.ancient] = 1
                }
            }
        }
        .onDisappear {
            viewModel.deactivate()
            translationModel.deactivate()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalModCatalog.readyNotification)) { _ in
            // 本地目录后台解析完成后，若正停在 mod/资源包/光影/整合包页，自动刷新为全量本地目录
            // ⚠️ fetchItems 内部同步写 isLoading/items/filteredResults 等状态，通知回调与
            // 渲染事务可能重叠，延迟到渲染事务外执行
            if viewModel.selectedSection != .game {
                DispatchQueue.main.async {
                    viewModel.fetchItems(translation: translationModel)
                }
            }
        }
        .onChange(of: viewModel.searchText) { _ in
            // ⚠️ onChange 处于视图更新事务中，而 applyFilter() 首行即同步写状态
            // searchDebounceTask（DownloadCategoryViewModel.swift），在视图更新期间写状态会触发
            // "Modifying state during view update"（UAF 前兆）。
            // 此处与下方 onChange(of:) 统一延迟到渲染事务外执行，避免两处写法不一致。
            // 注意：本工程部署目标为 macOS 13.0，onChange(of:initial:_:)（macOS 14.0+）不可用，
            // 必须沿用当前的旧签名 onChange(of: perform:)。
            DispatchQueue.main.async {
                viewModel.applyFilter(translation: translationModel)
            }
        }
        .onChange(of: viewModel.items) { newItems in
            // ⚠️ onChange 处于视图更新事务中，同步写 filteredResults/displayLimit 会触发
            // "Modifying state during view update"（UAF 前兆），延迟到渲染事务外执行
            // 本工程部署目标为 macOS 13.0，onChange(of:initial:_:)（macOS 14.0+）不可用，
            // 沿用旧签名 onChange(of: perform:)。
            // 「items 变更 → 重过滤」引发的重复联网在 handleItemsChanged 内按变更来源消除
            DispatchQueue.main.async {
                viewModel.handleItemsChanged(newItems, translation: translationModel)
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
        cardWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            GameSidebarView(
                theme: theme,
                selectedSection: $viewModel.selectedSection,
                selectedSubCategory: $viewModel.selectedSubCategory,
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

            // 分类切换淡出：selectSection 写入的 contentOpacity/contentOffset 在此读取。
            // 该淡出自初始提交起只有写入点、无读取点（收口提交亦记录为死状态），导致动画从未生效；
            // 读取点接在右侧内容区，与「侧栏高亮位移 + 内容淡入淡出」的分工一致。
            // 静止态为 opacity 1 / offset 0，不改变既有布局与视觉。
            if let item = viewModel.selectedModItem {
                ModDetailView(
                    item: item,
                    pageType: viewModel.currentDetailPageType,
                    onClose: { closeDetail() },
                    onNavigateToMod: { modItem in
                        // 进入前置加载器（Sodium/Iris）详情前记住当前分类，返回时恢复侧栏高亮
                        if viewModel.pendingReturnSection == nil {
                            viewModel.pendingReturnSection = viewModel.selectedSection
                        }
                        viewModel.selectedSection = .mod
                        viewModel.selectedSubCategory = nil
                        navigateTo(SidebarHighlight.index(for: .mod, sub: nil))
                    },
                    onNavigateBackFromMod: {
                        // 从前置加载器详情返回原分类（如光影），侧栏高亮同步跳回
                        if let restore = viewModel.pendingReturnSection {
                            viewModel.selectedSection = restore
                            viewModel.selectedSubCategory = nil
                            navigateTo(SidebarHighlight.index(for: restore, sub: nil))
                        }
                        viewModel.pendingReturnSection = nil
                    },
                    gameSubCategory: viewModel.selectedSubCategory,
                    theme: theme,
                    downloadDetail: DownloadDetailManager.shared
                )
                .frame(width: contentWidth)
                .frame(maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .trailing)
                ))
                .opacity(contentOpacity)
                .offset(y: contentOffset)
            } else {
                listContainer(
                    contentWidth: contentWidth,
                    cardPadding: cardPadding,
                    columns: columns,
                    cardWidth: cardWidth
                )
                .opacity(contentOpacity)
                .offset(y: contentOffset)
            }
        }
        .clipped()
    }

    private func listContainer(
        contentWidth: CGFloat,
        cardPadding: CGFloat,
        columns: Int,
        cardWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                CategorySearchBar(title: viewModel.displayTitle, searchText: $viewModel.searchText, cardPadding: cardPadding)
                contentBody(cardPadding: cardPadding, columns: columns, cardWidth: cardWidth)
            }
            .frame(width: contentWidth)
        }
        .frame(width: contentWidth + cardPadding * 2, alignment: .leading)
    }

    @ViewBuilder
    private func contentBody(cardPadding: CGFloat, columns: Int, cardWidth: CGFloat) -> some View {
        if viewModel.isLoading {
            Spacer()
            HStack {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Spacer()
            }
            Spacer()
        } else if viewModel.filteredResults.isEmpty && !viewModel.items.isEmpty {
            Spacer()
            Text("无匹配结果")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
        } else if viewModel.items.isEmpty {
            Spacer()
            Text("暂无内容")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Spacer()
        } else {
            CategoryResultsGrid(
                theme: theme,
                results: viewModel.filteredResults,
                translatedSubtitles: translationModel.translated,
                cardWidth: cardWidth,
                cardPadding: cardPadding,
                columns: columns,
                displayLimit: $viewModel.displayLimit,
                onOpen: { openDetail($0) },
                onRequestTranslation: { await translationModel.requestTranslation(for: $0, service: TranslationService.shared) },
                onReachEnd: { viewModel.loadMore() }
            )
        }
    }

    private func openDetail(_ item: DownloadedItem) {
        viewModel.selectedModItem = viewModel.displayItem(for: item, translatedSubtitle: translationModel.subtitle(for: item))
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            viewModel.showDetail = true
        }
    }

    private func closeDetail() {
        viewModel.pendingReturnSection = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.showDetail = false
            viewModel.selectedModItem = nil
        }
        // 详情页翻译过的条目立即回写列表卡片（缓存已在磁盘）
        translationModel.prefetch(viewModel.filteredResults, service: TranslationService.shared)
    }

    private func navigateTo(_ idx: Int) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            sectionHighlightY = SidebarHighlight.offsets[idx]
        }
    }

    /// 切换分类：状态重置由视图模型承担，本函数负责侧栏高亮位移、内容淡入淡出与请求发起。
    /// 语句顺序与收口前 selectSection 完全一致（重置 → 高亮位移 → 淡出 → fetchItems → 淡入）。
    private func selectSection(_ section: GameSidebarSection, sub: GameSubCategory?) {
        viewModel.selectSection(section, sub: sub)
        navigateTo(SidebarHighlight.index(for: section, sub: sub))
        withAnimation(.easeInOut(duration: 0.12)) {
            contentOpacity = 0.6
            contentOffset = 8
        }
        viewModel.fetchItems(translation: translationModel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.18)) {
                contentOpacity = 1
                contentOffset = 0
            }
        }
    }

    /// 清理静态缓存（内存警告时调用；由 AppContext 触发）
    static func clearStaticCaches() {
        ModrinthCategoryCache.clearAll()
        SearchTranslator.clearCache()
        GameVersionManifest.clearCache()
        LoaderSupportChecker.clearMemoryCache()
    }
}
