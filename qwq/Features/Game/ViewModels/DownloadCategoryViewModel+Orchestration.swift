//
//  DownloadCategoryViewModel+Orchestration.swift
//  模块化收口（第二批）：`DownloadCategoryView` 视图入口编排决策的扩展文件。
//
//  为什么是扩展而不是并入主文件：`DownloadCategoryViewModel.swift` 已 510 行且职责饱满
//  （选中态 / 取数 / 搜索 / 分页），本批收口的三类决策与其主流程正交，故按项目既有做法
//  （见 REFACTOR_PLAN.md「并入既有 ViewModel 的扩展文件」）单列一文件，避免主文件继续膨胀。
//
//  收口范围：
//  - 数据源准备（视图 onAppear 的三步预热：磁盘分类缓存装载 → 本地全量目录解析 → 目录预翻译）；
//  - 本地目录就绪通知后的刷新决议（仅非游戏分类刷新，游戏版本页不刷新）；
//  - 详情页进出前后的分类归属决策（进入前置加载器详情前记住来源分类、返回时恢复、关闭时清理）
//    —— 与之对应的 `selectedModItem` / `showDetail` 写入仍由视图在既有 withAnimation
//    事务内完成（见 GameViews.swift 的 openDetail / closeDetail），本文件只提供决策与清理。
//
//  刻意留在视图层的部分：
//  - 侧栏高亮的位移动画（navigateTo）与内容淡入淡出（contentOpacity / contentOffset）；
//  - 详情页进出场的 withAnimation 调用与 transition；
//  - 渲染事务外延迟（DispatchQueue.main.async）的调用点本身：只在视图侧构造，本文件内的
//    延迟与收口前逐字一致（handleLocalCatalogReady 内的延迟随原 onReceive 实现一并搬入）。
//
//  隔离标注说明：`DownloadCategoryViewModel` 已标注 `@MainActor`（见主文件说明），
//  本扩展的方法随类型继承同一 actor 隔离，与收口前（View 内）一致。
//
//  依据条目：Swift《Extensions》——扩展可为已有类型（含类）添加计算属性与方法，但不添加存储属性；
//  本文件只新增方法，故不涉及存储属性跨文件问题。
//  官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/extensions/
//  依据条目：SwiftUI《View》——被全局 actor 标注的协议，其遵循类型推断为该 actor 隔离。
//  官方链接：https://developer.apple.com/documentation/swiftui/view
//

import Foundation

extension DownloadCategoryViewModel {

    // MARK: - 数据源准备

    /// 视图出现时的数据源预热（收口前位于 `DownloadCategoryView.onAppear`，三步调用逐字保留、顺序不变）：
    /// 1. 装载磁盘上的分类缓存；
    /// 2. 启动本地全量目录后台解析（解析完成后经 readyNotification 通知刷新）；
    /// 3. 启动目录预翻译。
    ///
    /// 三步均不写本类型的展示状态（第 2、3 步只是发起后台任务），故可在 onAppear 内同步调用。
    func prepareDataSources() {
        ModrinthCategoryCache.loadFromDisk()
        LocalModCatalog.warmUp()
        LocalModCatalog.preTranslateAll()
    }

    /// 本地全量目录解析完成后的刷新决议：仅非游戏分类才刷新
    /// （游戏版本页的数据来源是版本清单，与本地目录无关）。
    ///
    /// ⚠️ fetchItems 内部同步写 isLoading/items/filteredResults 等状态，通知回调与渲染事务
    /// 可能重叠，延迟到渲染事务外执行（与收口前 onReceive 内的写法逐字一致）。
    func handleLocalCatalogReady(translation: CardTranslationModel) {
        guard selectedSection != .game else { return }
        DispatchQueue.main.async {
            self.fetchItems(translation: translation)
        }
    }

    // MARK: - 详情页导航归属

    /// 进入前置加载器（Sodium/Iris）详情：首次进入时记住当前分类，随后切到模组分类。
    /// 返回时经 `restoreFromPrerequisiteDetail()` 恢复侧栏高亮（高亮位移由视图执行）。
    func enterPrerequisiteDetail() {
        if pendingReturnSection == nil {
            pendingReturnSection = selectedSection
        }
        selectedSection = .mod
        selectedSubCategory = nil
    }

    /// 从前置加载器详情返回原分类。
    /// - Returns: 需要恢复并高亮的分类；无待恢复分类时返回 nil（视图据此不做高亮位移，
    ///   与收口前「pendingReturnSection 为空则不跳转」的行为一致）。
    @discardableResult
    func restoreFromPrerequisiteDetail() -> GameSidebarSection? {
        var restored: GameSidebarSection?
        if let pending = pendingReturnSection {
            selectedSection = pending
            selectedSubCategory = nil
            restored = pending
        }
        pendingReturnSection = nil
        return restored
    }

    /// 关闭详情页前的归属清理（`showDetail` / `selectedModItem` 的写入由视图在既有
    /// withAnimation 事务内完成，与本方法分属两个事务点，故不合并）。
    func prepareDetailClose() {
        pendingReturnSection = nil
    }
}
