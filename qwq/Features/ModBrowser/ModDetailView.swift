//
//  ModDetailView.swift
//  模块化拆分：从 GameViews.swift 拆出（原文件 2776 行，拆分后职责单一、可读性提升）
//  纯 UI 详情页 + 下载编排：DetailPageType（qwq/DetailPageType.swift）、版本工具（qwq/VersionUtils.swift）、
//  目录扫描（qwq/GameDirectoryScanner.swift）、下载解析（qwq/DownloadFileResolver.swift）、
//  版本选择区块（qwq/VersionSelectionSection.swift）、光影加载器过滤（qwq/ShaderLoaderFilter.swift）、
//  光影前置加载器提示（qwq/ShaderPrerequisiteSection.swift）均已拆至独立文件。
//

import SwiftUI
import AppKit

/// 项目详情页。**一个 ViewModel 支撑整条滑动栈**（基础页 + 若干前置依赖页），
/// 各页横向排布、靠 `navSlideOffset` 平移切换，栈内非首页一律按 `.mod` 渲染。
///
/// 业务决策（版本列表规则、默认选中、加载器检测状态机、取数、翻译调度）全部在
/// ViewModels/ModDetailViewModel.swift；本视图只管三件事：
/// 页面滑动栈、入出场动画、下载按钮的提示与弹跳。
///
/// ⚠️ 因为各页**共用一个 ViewModel**，来回滑动会覆盖彼此的展示状态 ——
/// 所以 `goBack` 时必须按 `basePageType` 重新取一次基础页的数据（见该方法注释）。
struct ModDetailView: View {
    /// 当前展示的项目。前置依赖页的数据不在这个字段里，而由 ViewModel 按页面取。
    let item: DownloadedItem
    /// 基础页（栈第 0 页）进入时的页面类型。
    /// ⚠️ 这只是**初值**：进入前置加载器页时宿主会把分类切成「模组」，
    /// 视图的 `pageType` 随之变成 `.mod`，此时要靠 `basePageType` 才能还原。
    let pageType: DetailPageType
    let onClose: () -> Void
    /// 点前置依赖时通知宿主（宿主要据此切换左侧分类高亮）。
    var onNavigateToMod: ((DownloadedItem) -> Void)? = nil
    var onNavigateBackFromMod: (() -> Void)? = nil
    /// 游戏分类下的子分类（release/snapshot/…），仅游戏页面用；其它页面为 nil。
    var gameSubCategory: GameSubCategory? = nil

    /// 主题与下载详情管理器属全局单例（外部持有），由调用方注入，本视图只订阅、不创建
    @ObservedObject var theme: ThemeManager
    @ObservedObject var downloadDetail: DownloadDetailManager
    /// 启动器设置已由根视图经环境注入，此处复用同一注入点，避免出现第二个来源
    @EnvironmentObject var settings: LauncherSettings

    // 业务决策（版本列表规则、默认选中决议、加载器检测状态机、整合包与项目取数、翻译调度）
    // 已整体下沉 ViewModels/ModDetailViewModel.swift，本视图只订阅展示状态并转发意图
    @StateObject private var viewModel = ModDetailViewModel()

    // 以下为纯视图状态：页面滑动栈、横向位移、入出场动画与可取消延迟任务
    /// 前置依赖的页面栈（不含基础页本身）。数组内容 = 栈上第 1..n 页。
    @State private var prerequisiteStack: [DownloadedItem] = []
    /// 整条滑动栈的横向位移。每次进/出前置页 ± `pageWidth`，动画由 withAnimation 驱动。
    @State private var navSlideOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0

    /// 整页入场动画的两个中间量（从 0.85 放大到 1、从全透明到不透明）。
    @State private var entryScale: CGFloat = 0.85
    @State private var entryOpacity: Double = 0

    @State private var bounceScale: CGFloat = 1.0
    // 延迟动画任务（下载按钮弹跳 / 返回滑动）：onDisappear 时 cancel，
    // 防止视图销毁后写已释放的 @State storage（UAF）
    @State private var bounceTask: Task<Void, Never>?
    @State private var backNavTask: Task<Void, Never>?

    /// 基础页（滑页栈第 0 页）进入时的页面类型。
    /// 进入前置加载器页时宿主会把分类切到「模组」，本视图的 `pageType` 随之变为 `.mod`，
    /// 返回时需按这里记住的原类型重建基础页数据（滑页各页共用同一个 ViewModel，细节见 goBack）。
    /// 基础页进入时的页面类型。⚠️ 必须记住它：进前置页时宿主会把 `pageType` 改成 `.mod`，
    /// 返回时只有靠这个原值才能把基础页的数据重新取回来（滑页共用一个 ViewModel）。
    @State private var basePageType: DetailPageType?

    // 页签副标题翻译状态与调度走共享 CardTranslationModel（与列表页同一套
    // 「内存→磁盘→网络」按需翻译流程；视图销毁后 model 不再写回，UAF 防护）
    @StateObject private var translationModel = CardTranslationModel()

    // 外层：几何测量 + 整页缩放/透明度入场 + 指定边距（左边缘贴紧分类栏，仅内容层内缩）。
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                // 用**下标**做 identity 是有意的：页面栈只增删尾部，下标稳定，
                // 且每页的 item 可能被重复（同一前置项被点多次），用 item.id 会撞键。
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
                // ⚠️ onAppear 处于视图更新事务中：withAnimation 内写 pageWidth，以及
                // applyDefaultVersionSelection / triggerPageLoads 对 ViewModel 展示状态的写，
                // 会触发 "Modifying state during view update"（UAF 前兆），整体延迟到渲染事务外执行
                DispatchQueue.main.async {
                    withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 240, damping: 14, initialVelocity: 8)) {
                        entryScale = 1.0
                        entryOpacity = 1.0
                        pageWidth = width
                    }
                    translationModel.activate()
                    viewModel.activate()
                    basePageType = pageType
                    viewModel.applyDefaultVersionSelection(pageType: pageType, itemName: item.name)
                    viewModel.triggerPageLoads(pageType: pageType,
                                               item: item,
                                               gameSubCategory: gameSubCategory,
                                               pages: allPages,
                                               translation: translationModel)
                }
            }
            .onChange(of: geometry.size.width) { newWidth in
                // 布局事务中写 @State 会触发 "Modifying state during view update"（UAF 前兆）
                DispatchQueue.main.async { pageWidth = newWidth }
            }
            .onChange(of: viewModel.selectedVersion) { newValue in
                if pageType == .loaderSelector {
                    viewModel.fetchLoaderSupport(for: newValue, pageType: pageType)
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
            if !viewModel.selectedVersion.isEmpty {
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
                .padding(.trailing, downloadDetail.showCircleButton ? 88 : 12)
                .padding(.bottom, 20)
                .animation(.interpolatingSpring(stiffness: 170, damping: 14), value: downloadDetail.showCircleButton)
            }
        }
        .onDisappear {
            // 先置存活标记并取消在途检测任务（在 ViewModel 内），再取消视图侧动画任务
            viewModel.deactivate()
            bounceTask?.cancel()
            backNavTask?.cancel()
            translationModel.deactivate()
        }
        // 下载中状态跟随详情页开关：详情页打开/关闭时驱动下载按钮布局变化（圆按钮出现时左移）
    }

    /// 全部页面：基础页在最前，其后依次是前置依赖栈。
    /// ⚠️ 顺序必须与 `navigateToPrerequisite` 的位移方向一致（越靠后 → 越向右偏移）。
    private var allPages: [DownloadedItem] {
        [item] + prerequisiteStack
    }

    /// 进入一个前置依赖页：入栈 → 显式触发该前置项的取数 → 向左滑一屏。
    private func navigateToPrerequisite(_ prereq: DownloadedItem) {
        onNavigateToMod?(prereq)
        prerequisiteStack.append(prereq)
        // 前置内容页与基础页共用同一个 ViewModel（同一实例，按 index 横向排布），
        // 而它没有自己的 onAppear —— 此前只有基础页在 onAppear 取过数，前置页因此显示
        // 基础项的版本 / 加载器，自身详情永不拉取。故在此显式触发该前置项的取数。
        // 页面类型与 detailPageContent 的渲染口径一致：栈内非首页按 .mod 渲染。
        viewModel.triggerPageLoads(pageType: .mod,
                                   item: prereq,
                                   gameSubCategory: gameSubCategory,
                                   pages: [prereq],
                                   translation: translationModel)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            navSlideOffset -= pageWidth
        }
    }

    /// 返回上一页。栈空则关闭整个详情页。
    ///
    /// ⚠️ 栈非空时必须按 `basePageType` **重新取一次基础页数据** ——
    /// 因为滑页共用一个 ViewModel，基础页的展示状态已被前置页的取数覆盖，
    /// 不重取的话版本下拉与「支持版本 / 加载器」会停留在前置项的值上。
    private func goBack() {
        if !prerequisiteStack.isEmpty {
            // 从前置加载器页返回原分类（光影/资源包）：通知宿主恢复侧栏高亮
            onNavigateBackFromMod?()
            // 基础页数据已被前置页的取数覆盖（滑页共用一个 ViewModel），按其进入前的页面类型
            // 重新取数，否则版本下拉与「支持版本 / 加载器」会停留在前置项的取值上。
            if let basePageType {
                viewModel.triggerPageLoads(pageType: basePageType,
                                           item: item,
                                           gameSubCategory: gameSubCategory,
                                           pages: [item],
                                           translation: translationModel)
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                navSlideOffset += pageWidth
            }
            backNavTask?.cancel()
            backNavTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                if !prerequisiteStack.isEmpty {
                    prerequisiteStack.removeLast()
                }
            }
        } else {
            onClose()
        }
    }

    /// 下载按钮弹跳动画（放大→回弹→复位）：改为可取消的 Task，视图销毁后不再写 bounceScale
    private func playDownloadBounce() {
        bounceTask?.cancel()
        withAnimation(.interpolatingSpring(stiffness: 220, damping: 14)) {
            bounceScale = 1.25
        }
        bounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.interpolatingSpring(stiffness: 200, damping: 16)) {
                bounceScale = 0.92
            }
            try? await Task.sleep(nanoseconds: 170_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.interpolatingSpring(stiffness: 220, damping: 18)) {
                bounceScale = 1.0
            }
        }
    }

    /// 点下载：先给「下载开始」提示与按钮弹跳，再转交 ViewModel 做路径决策与实际下载。
    /// 顺序不能换 —— 提示要在耗时操作之前出现，否则用户点完会先愣一下。
    private func startDownload() {
        guard !viewModel.selectedVersion.isEmpty else { return }

        // 点击即提示「下载开始」（此前仅下载完成后才提示「下载完成」）
        LaunchPanelState.shared.presentMessage("下载开始")
        
        // 下载按钮弹动画（放大 → 缩小回弹，不消失；可取消 Task，视图销毁后不再写 @State）
        playDownloadBounce()

        // 圆按钮弹入动画状态：先提取局部引用（闭包绝不隐式捕获 self 的 @State 指针）
        let manager = downloadDetail
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            manager.showCircleButton = true
            withAnimation(.interpolatingSpring(stiffness: 170, damping: 14)) {
                manager.circleScale = 1.0
                manager.circleOpacity = 1.0
            }
        }
        
        // 下载路径决策（游戏版本页 → 版本安装；其余页面 → 文件下载）与加载器支持判定在 ViewModel；
        // 本视图只保留上述提示与动画调度，调用时点与收口前逐字一致
        viewModel.performDownload(pageType: pageType, item: item, manager: downloadDetail)
    }

    /// 单页内容（滑动栈里的一页）。
    /// - Parameter pageTypeForIndex: 该页按什么类型渲染（栈内非首页恒为 `.mod`）。
    /// - Parameter isBasePage: 是否为基础页 —— 只有基础页才展示「跨版本自动匹配」提示与
    ///   光影前置依赖区块，避免在前置页里再套一层同样的提示。
    @ViewBuilder
    private func detailPageContent(item pageItem: DownloadedItem, pageTypeForIndex: DetailPageType, isBasePage: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
            DetailPageHeader(
                theme: theme,
                title: pageItem.name,
                subtitle: translationModel.subtitle(for: pageItem),
                tags: pageItem.tags,
                onBack: { goBack() }
            )

            VStack(alignment: .leading, spacing: 14) {
                VersionSelectionSection(
                    theme: theme,
                    pageType: pageTypeForIndex,
                    sortedVersions: viewModel.sortedVersions,
                    availableLoaders: viewModel.availableLoaders,
                    uniqueVersions: viewModel.uniqueGameVersions(),
                    projectLoaders: viewModel.projectLoaders,
                    localVersionLoaders: viewModel.localVersionLoaders,
                    isLoadingModpackVersions: viewModel.isLoadingModpackVersions,
                    isLoadingLoaders: viewModel.isLoadingLoaders,
                    loaderStates: viewModel.loaderStates,
                    loaderCompletionOrder: viewModel.loaderCompletionOrder,
                    loaderError: (pageTypeForIndex == .loaderSelector && isBasePage) ? viewModel.loaderError : nil,
                    onRetryLoaders: { viewModel.fetchLoaderSupport(for: viewModel.selectedVersion, pageType: pageType) },
                    selectedVersion: $viewModel.selectedVersion,
                    selectedLoader: $viewModel.selectedLoader,
                    selectedModpackVersionId: $viewModel.selectedModpackVersionId
                )

                if pageTypeForIndex == .shader, !viewModel.hasShaderFolder, viewModel.shaderFolderChecked, isBasePage {
                    ShaderPrerequisiteSection(onSelect: { navigateToPrerequisite($0) })
                }

                if pageTypeForIndex != .loaderSelector && pageTypeForIndex != .modpack {
                    // 光影页面：加载器只显示 Iris/OptiFine 等光影加载器，过滤模组加载器
                    let filteredLoaders = ShaderLoaderFilter.filtered(projectLoaders: viewModel.projectLoaders, pageType: pageTypeForIndex)
                    SupportedMetaSection(
                        title: pageTypeForIndex.supportedVersionTitle,
                        rangeText: viewModel.versionRangeText,
                        filteredLoaders: filteredLoaders
                    )
                }

                if let crossVersion = viewModel.findCrossVersionDownload(for: viewModel.selectedVersion, pageType: pageType),
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
            // 版本标题/返回箭头与下方加载器卡片统一内容起点，避免标题贴分类栏过左。
            .padding(.leading, 56)
            .padding(.vertical, 8)
        }
        // 底部留 90pt：给悬浮在右下角的下载按钮让位，避免滚动到底时内容被按钮压住。
        .padding(.bottom, 90)
        }
        }
    }
}

