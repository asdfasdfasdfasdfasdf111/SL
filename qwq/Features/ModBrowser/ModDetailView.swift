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

struct ModDetailView: View {
    let item: DownloadedItem
    let pageType: DetailPageType
    let onClose: () -> Void
    var onNavigateToMod: ((DownloadedItem) -> Void)? = nil
    var onNavigateBackFromMod: (() -> Void)? = nil
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
    @State private var prerequisiteStack: [DownloadedItem] = []
    @State private var navSlideOffset: CGFloat = 0
    @State private var pageWidth: CGFloat = 0

    @State private var entryScale: CGFloat = 0.85
    @State private var entryOpacity: Double = 0

    @State private var bounceScale: CGFloat = 1.0
    // 延迟动画任务（下载按钮弹跳 / 返回滑动）：onDisappear 时 cancel，
    // 防止视图销毁后写已释放的 @State storage（UAF）
    @State private var bounceTask: Task<Void, Never>?
    @State private var backNavTask: Task<Void, Never>?

    // 页签副标题翻译状态与调度走共享 CardTranslationModel（与列表页同一套
    // 「内存→磁盘→网络」按需翻译流程；视图销毁后 model 不再写回，UAF 防护）
    @StateObject private var translationModel = CardTranslationModel()

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

    private var allPages: [DownloadedItem] {
        [item] + prerequisiteStack
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
            // 从前置加载器页返回原分类（光影/资源包）：通知宿主恢复侧栏高亮
            onNavigateBackFromMod?()
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
        
        // 游戏版本页：点下载 = 真正下载安装所选版本（+ 可选加载器），对标 PCL.Mac DownloadPage
        if pageType == .loaderSelector {
            GameVersionDownloadStarter.start(
                versionStr: viewModel.selectedVersion,
                loader: viewModel.selectedLoader.lowercased(),
                loaderSupported: viewModel.availableLoaders.contains { $0.lowercased() == viewModel.selectedLoader.lowercased() },
                settings: settings,
                manager: manager
            )
            return
        }

        // 真正的下载逻辑（mod/shader/resourcePack/modpack）：解析目标文件 → 创建下载任务 →
        // 打开详情页 → 启动任务。编排逻辑在 ModFileDownloadStarter，视图只传值，不持有闭包。
        ModFileDownloadStarter.start(
            pageType: pageType,
            item: item,
            selectedVersion: viewModel.selectedVersion,
            selectedLoader: viewModel.selectedLoader,
            selectedModpackVersionId: viewModel.selectedModpackVersionId,
            settings: settings,
            manager: manager
        )
    }

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
        .padding(.bottom, 90)
        }
        }
    }
}

