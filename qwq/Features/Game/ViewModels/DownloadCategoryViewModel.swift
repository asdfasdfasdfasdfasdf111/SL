//
//  DownloadCategoryViewModel.swift
//  下载分类页（DownloadCategoryView）的状态与业务决策唯一持有者。
//
//  职责边界：持有侧边栏选中态、列表数据、搜索分页、详情页选中态；承担数据来源决策
//  （本地全量目录 / 游戏版本清单 / Modrinth 检索）、搜索过滤决策树、请求归属校验与
//  游戏版本清单 → 列表项转换；版本清单取数与分类规则委托 Game 模块的
//  `VersionCatalogService` / `VersionFilterUseCase`。
//
//  刻意留在视图层的部分：布局计算、滚动网格、动画调用、侧栏高亮偏移、翻译状态
//  `CardTranslationModel` 的持有与调度（生命周期归视图层）。
//
//  线程约定：所有异步回写经 `MainActor.run`，派生状态刷新延迟到渲染事务外执行；
//  本类型标注 `@MainActor`（View 协议带全局 actor 标注，与收口前隔离语义一致，
//  并满足对 `CardTranslationModel` 同步调用 `prefetch` 的要求）。
//

import SwiftUI
import Combine

@MainActor
final class DownloadCategoryViewModel: ObservableObject {

    // MARK: - 依赖

    /// 版本清单取数（默认接默认实现：模块未接线，与 ModBrowserModule 未接线前做法一致）
    let versionCatalog: VersionCatalogService

    /// 版本分类过滤
    let versionFilter: VersionFilterUseCase

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

    @Published var items: [DownloadedItem] = []
    @Published var filteredResults: [DownloadedItem] = []
    @Published var isLoading = false

    /// 列表分页展示上限（CategoryResultsGrid 双向绑定）
    @Published var displayLimit = 120

    // MARK: - 搜索

    @Published var searchText = ""

    /// 与收口前一致：仅写入、无读取点（历史遗留字段，保持原状不删除）
    /// 本次死状态清理判定：保留。该字段为 `private var`，删除虽不影响行为，
    /// 但属收口时明确记录「保持原状」的历史字段，与搜索防抖逻辑同一事务块内写入，
    /// 清理收益为零，故不做无谓改动。
    var debouncedSearchText = ""
    var searchDebounceTask: Task<Void, Never>?

    /// 搜索结果弹入的 id 集合（已接线的数据来源）。
    ///
    /// 填充点（2 处，均在 `applyFilter` 内，填入**该批结果的全部 id**）：
    /// 1. 本地全量目录检索结果写回（`LocalModCatalog` 命中分支）；
    /// 2. 联网检索结果写回（Modrinth 分支）。
    /// 两处都是「用户输入非空关键词 → 新结果集写回 filteredResults」，即「搜索结果出现」语义；
    /// 只填联网分支不够：目录随包分发且在 `warmUp()` 中预解析，实际运行时 `LocalModCatalog.isReady`
    /// 恒为真，联网分支被本地分支提前 return 掉，动画在正式构建中永不播放。
    ///
    /// 下列路径保持空集合，保证弹入**只在搜索结果出现时**触发：
    /// 空串回填（清空搜索词，属结果集复位）、游戏版本页本地过滤（过滤对象是本地版本号列表，
    /// 基线提交 5d5769d 中该分支即赋空）、本地全量目录加载（`fetchItems`，非搜索路径）。
    /// 分页 `loadMore` 不做任何写入：追加条目的 id 不在集合内，走常规入场动画；原设计意图是
    /// 「搜索结果出现」时弹入，加载更多是同一结果集的延续，首批之后的卡片不重复弹入。
    ///
    /// 逐卡透传：`GameViews.swift` → `CategoryResultsGrid.popInIds` → `ContentCard.isSearchPopIn`，
    /// 判定点位于 `CategoryResultsGrid.swift:41` 的 `ContentCard(...)` 构造处。
    ///
    /// 刻意不标注 `@Published`：本集合与 items/filteredResults 在同一批 `MainActor.run` 内写入，
    /// 视图只重渲染一次并在该次渲染中取到最新值，本集合自身不构成独立的重渲染触发源，
    /// 标注 `@Published` 只会多一次无谓刷新（可见性按「同模块只读」放宽为 `private(set)`）。
    ///
    /// 回退记录（勿用）：曾以本集合作为结果网格 `.id()` 的身份键，借「identity 变化 → 网格子树重建
    /// → 卡片重新 onAppear」间接播放弹入。该接法已回退，原因是副作用不可接受且动画归属错误：
    /// 1. 官方 `View.id(_:)` 说明——When the proxy value specified by the `id` parameter
    ///    changes, the identity of the view — for example, its state — is reset.
    ///    网格子树重建会重置其内全部 `@State`（含 `CategoryResultsGrid` 的滚动锚点
    ///    `lastAnchorItemID` 写入链路），并使 `CategoryResultsGrid.swift:74` 的
    ///    `.task(id: item.id)` 随 identity 变化被取消重建（见官方 task 页的取消语义），
    ///    即每张卡片重新发起一次翻译请求与图片加载。
    /// 2. 官方 `StateObject` / `withAnimation` 说明——视图 identity 变化时 SwiftUI
    ///    不会为视图内部的变化自动加动画；即该接法得到的是「重建 + 卡片自身 onAppear
    ///    动画」的观感，而非原设计的卡片级弹簧弹入，动画归属从卡片漂移到了网格身份。
    /// 官方链接：https://developer.apple.com/documentation/swiftui/view/id(_:)
    /// 官方链接：https://developer.apple.com/documentation/swiftui/stateobject
    /// 官方链接：https://developer.apple.com/documentation/swiftui/view/task(priority:_:)
    /// 官方链接：https://developer.apple.com/documentation/swiftui/withanimation(_:_:)
    var searchPopInIds: Set<String> = []

    // MARK: - 分页

    var currentOffset = 0
    var hasMore = true
    var isLoadingMore = false
    var activeSearchQuery = ""

    // MARK: - 请求归属

    var fetchTask: Task<Void, Never>?

    /// 请求归属令牌：每次 fetchItems 递增，迟到任务写回前校验 token 不一致即丢弃。
    /// 仅靠 cancel()+isCancelled 存在竞态窗口（旧任务已通过 isCancelled 检查、新任务已启动），
    /// 归属校验保证旧结果绝不覆盖新列表（崩溃 #4 教训的通用化）
    var fetchToken = 0

    /// 视图存活标记（onAppear/onDisappear 联动，异步回调据此判断是否继续写回）
    var isViewActive = false

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
    /// 本次死状态清理判定：保留。写入点位于 openDetail/closeDetail 的 withAnimation 闭包内，
    /// 与详情页进出场 transition 共用同一事务；删除将使 openDetail 退化为空动画闭包，
    /// 而事务归属无法在不运行 App 的前提下依据官方文档判定，为守住「不改变交互行为」约束不动。
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

    /// 最近一次由 `applyFilter` 联网写回 items 的批次快照。
    ///
    /// 该路径同时写回 items 与 filteredResults，因此视图 `onChange(of: items)` 再调用
    /// `handleItemsChanged` 时，过滤结果其实已经就位；若仍按「items 变更即重过滤」处理，
    /// 每次联网搜索都会多发一轮 Modrinth 请求（旧签名 onChange 的既有冗余）。
    /// 以快照比对识别变更来源：批次长度不同时比较在首步即失败，无遍历开销。
    var itemsFromSearch: [DownloadedItem]?

    /// items 变更后的派生刷新。
    ///
    /// 由视图在 `onChange(of: items)` 内延迟到渲染事务外调用（与收口前一致：
    /// onChange 处于视图更新事务中，同步写 filteredResults/displayLimit 会触发
    /// "Modifying state during view update"，是 UAF 前兆）。
    ///
    /// 变更来源为 `applyFilter` 自身（快照命中）时直接返回：此时 filteredResults 已是
    /// 该批次搜索结果，再走一次 applyFilter 只会在 400ms 防抖后重复同一轮联网请求。
    /// 其余来源（本地目录加载完成、缓存命中、分页合并等）保持原行为，仍按搜索词重过滤。
    func handleItemsChanged(_ newItems: [DownloadedItem], translation: CardTranslationModel) {
        filteredResults = newItems
        displayLimit = 120
        if let searchBatch = itemsFromSearch, searchBatch == newItems {
            itemsFromSearch = nil
            return
        }
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            applyFilter(translation: translation)
        }
    }

}
