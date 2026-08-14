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

    @ObservedObject var theme = ThemeManager.shared
    @ObservedObject var settings = LauncherSettings.shared
    @ObservedObject private var downloadDetail = DownloadDetailManager.shared

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

    @State private var bounceScale: CGFloat = 1.0
    // 延迟动画任务（下载按钮弹跳 / 返回滑动）：onDisappear 时 cancel，
    // 防止视图销毁后写已释放的 @State storage（UAF）
    @State private var bounceTask: Task<Void, Never>?
    @State private var backNavTask: Task<Void, Never>?

    @State private var modpackVersions: [ModpackVersion] = []
    @State private var isLoadingModpackVersions = false
    @State private var selectedModpackVersionId: String = ""
    @State private var cachedUniqueVersions: [(gameVersion: String, version: ModpackVersion)]? = nil

    @State private var localVersionLoaders: [String: ModLoader] = [:]
    @State private var hasScannedLocalVersions = false


    // 页签副标题翻译状态与调度走共享 CardTranslationModel（与列表页同一套
    // 「内存→磁盘→网络」按需翻译流程；视图销毁后 model 不再写回，UAF 防护）
    @StateObject private var translationModel = CardTranslationModel()
    @State private var projectGameVersions: [String] = []
    @State private var projectLoaders: [String] = []
    @State private var isLoadingProject = false

    @State private var availableLoaders: [String] = []
    @State private var isLoadingLoaders = false
    // 加载器检测任务与错误态：任务持有引用以便切换版本/销毁视图时取消（UAF 防护），
    // 错误态（结果未知：网络失败/5xx/超时）与「明确不支持」区分展示，不再误报「没有加载器」
    @State private var loaderSupportTask: Task<Void, Never>?
    @State private var loaderError: String?
    // 逐加载器检测状态（流式：完成一个显示一个，不再等全部结束才出卡片）
    @State private var loaderStates: [String: LoaderState] = [:]

    private func assetName(for loader: String) -> String {
        LoaderNameResolver.assetName(for: loader)
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
                            let ownedSet = Set(GameDirectoryScanner.localOwnedVersions(gameRoot: settings.selectedGameRoot))
                            // 交集：本地拥有且该模组兼容的版本
                            let compatible = projectGameVersions.filter { ownedSet.contains($0) }
                            if !compatible.isEmpty {
                                // 只显示本地拥有且模组兼容的版本，全部列出
                                sortedVersions = GameVersionHelper.sortForDisplay(compatible, selected: settings.selectedMinecraftVersion)
                                if let first = sortedVersions.first {
                                    selectedVersion = first
                                }
                            }
                            // 如果本地没有任何兼容版本，保留本地版本列表（不覆盖），
                            // 方便用户看到本地拥有的全部版本。
                        }
                    } else if pageType == .shader || pageType == .resourcePack {
                        // 跨版本内容：本地拥有的全部版本都列出来，默认选最近的版本
                        let owned = GameDirectoryScanner.localOwnedVersions(gameRoot: settings.selectedGameRoot)
                        if !owned.isEmpty {
                            sortedVersions = GameVersionHelper.sortForDisplay(owned, selected: settings.selectedMinecraftVersion)
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
        let sorted = projectGameVersions.sorted { GameVersionHelper.compare($0, $1) < 0 }
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
                // ⚠️ onAppear 处于视图更新事务中：withAnimation 内写 pageWidth、applyDefaultVersionSelection
                // （写 hasScannedLocalVersions/sortedVersions/selectedVersion）、triggerPageLoads
                // （写 shaderFolderChecked/hasShaderFolder）均为同步 @State 写，会触发
                // "Modifying state during view update"（UAF 前兆），整体延迟到渲染事务外执行
                DispatchQueue.main.async {
                    withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 240, damping: 14, initialVelocity: 8)) {
                        entryScale = 1.0
                        entryOpacity = 1.0
                        pageWidth = width
                    }
                    translationModel.activate()
                    applyDefaultVersionSelection()
                    triggerPageLoads()
                }
            }
            .onChange(of: geometry.size.width) { newWidth in
                // 布局事务中写 @State 会触发 "Modifying state during view update"（UAF 前兆）
                DispatchQueue.main.async { pageWidth = newWidth }
            }
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
                .padding(.trailing, downloadDetail.showCircleButton ? 88 : 12)
                .padding(.bottom, 12)
                .animation(.interpolatingSpring(stiffness: 170, damping: 14), value: downloadDetail.showCircleButton)
            }
        }
        .onDisappear {
            // 视图销毁：取消延迟动画任务与加载器检测任务，防止其继续写已释放的 @State storage（UAF）；
            // 翻译 model 同步 deactivate，异步翻译回调不再写回
            bounceTask?.cancel()
            backNavTask?.cancel()
            loaderSupportTask?.cancel()
            translationModel.deactivate()
        }
        // 下载中状态跟随详情页开关：详情页打开/关闭时驱动下载按钮布局变化（圆按钮出现时左移）
    }

    /// 详情页首次加载：本地加载器扫描 + 版本列表就绪 + 默认选中版本决策
    private func applyDefaultVersionSelection() {
        if sortedVersions.isEmpty {
            if (pageType == .mod || pageType == .shader || pageType == .resourcePack), !hasScannedLocalVersions {
                hasScannedLocalVersions = true
                localVersionLoaders = GameDirectoryScanner.scanLocalLoaderMap(gameRoot: settings.selectedGameRoot)
            }
            sortedVersions = availableVersions

            // 默认选中决策集中在 DetailVersionDecision（游戏版本页必须选用户点击的版本，
            // 其他页面优先当前实例版本；item.name 不在列表时不急着回退，等 manifest 就绪决议）
            if let selected = DetailVersionDecision.initialSelection(
                pageType: pageType,
                itemName: item.name,
                sortedVersions: sortedVersions,
                instanceVersion: settings.selectedMinecraftVersion.isEmpty ? nil : settings.selectedMinecraftVersion
            ) {
                selectedVersion = selected
            }
        }
    }

    /// 详情页条件数据加载（游戏版本清单 / 光影目录检测 / 整合包版本 / 项目详情与翻译）
    private func triggerPageLoads() {
        // 游戏版本页：异步获取 Mojang 版本清单
        if pageType == .loaderSelector && manifestVersions.isEmpty {
            fetchManifestVersions()
        }
        if pageType == .shader, !shaderFolderChecked {
            shaderFolderChecked = true
            hasShaderFolder = GameDirectoryScanner.hasShaderFolder(gameRoot: settings.selectedGameRoot, versions: baseVersions)
        }
        if pageType == .modpack, modpackVersions.isEmpty {
            fetchModpackVersions()
        }
        if !item.id.isEmpty {
            translateDetailDescription()
            fetchProjectDetails()
        }
    }

    private var allPages: [DownloadedItem] {
        [item] + prerequisiteStack
    }

    private var baseVersions: [String] {
        ["1.21.4", "1.21.1", "1.18", "1.19.1"]
    }

    private func fetchManifestVersions() {
        Task {
            let versions = await GameVersionManifest.fetchMerged()
            guard !versions.isEmpty else { return }
            // 分类过滤逻辑在 GameVersionFilter（release/snapshot/远古，与分类列表共享同一规则）
            let filtered = GameVersionFilter.filteredIDs(versions, subCategory: gameSubCategory)
            await MainActor.run {
                manifestVersions = filtered
                sortedVersions = availableVersions
                // 决议规则集中在 DetailVersionDecision：
                // 先保留现有选择（含用户手动选择），其次用户点击的 item.name，最后才回退。
                // （此前无条件改 sortedVersions.first 会把当前实例版本 26.2 提到首位，
                //   冲掉 onAppear 按 item.name 的设置，触发 onChange → 缓存命中 4 张卡）
                if let resolved = DetailVersionDecision.resolveAfterManifest(
                    pageType: pageType,
                    current: selectedVersion,
                    itemName: item.name,
                    sortedVersions: sortedVersions
                ) {
                    selectedVersion = resolved
                }
            }
        }
    }

    // MARK: - 加载器支持检测（已下沉到 PCLCore 后端：LoaderSupportChecker）
    // UI 只消费结果，不直接联网、不直接读写缓存文件；内存/磁盘缓存、联网并发检测
    // 与失败回退均在核心层完成（三级策略：内存 → 磁盘 7 天 TTL → 联网，失败回退旧缓存）。

    private func fetchLoaderSupport(for version: String) {
        guard !version.isEmpty else { return }
        // 1. 取消上一次检测任务（防止旧版本结果覆盖新版本 —— 「鬼畜」根因之一；归属校验详见下方）
        loaderSupportTask?.cancel()
        loaderError = nil
        let requested = version
        // 2. 立即以「缓存已定论项 + 未定论项 checking」初始化：首帧直接出已定论卡片，
        //    未缓存项显示转圈，不闪烁、不空白等待
        var initial = LoaderSupportChecker.cachedLoaderStates(for: version) ?? [:]
        for name in LoaderSupportChecker.candidateDisplayNames(for: version) where initial[name] == nil {
            initial[name] = .checking
        }
        loaderStates = initial
        applyLoaderStates(initial, version: version)
        // 3. 全部定论（无 missing）→ 直接结束，绝不联网
        if LoaderSupportChecker.isFullyResolved(initial, for: version) { return }
        // 4. 流式联网：每个加载器检测完成立即逐项写 UI（完成一个显示一个）；
        //    写回前做归属校验（任务未取消且版本未切换），迟到的旧结果一律丢弃
        loaderSupportTask = Task {
            let stream = LoaderSupportChecker.streamLoaderStates(for: requested)
            for await (loader, state) in stream {
                await MainActor.run {
                    guard !Task.isCancelled, selectedVersion == requested else { return }
                    var states = loaderStates
                    states[loader] = state
                    loaderStates = states
                    applyLoaderStates(states, version: requested)
                }
            }
        }
        // 5. 预加载：顺带静默预取相邻版本（切版本最常看相邻；in-flight 合并保证不重复联网）
        prefetchNearbyLoaders(for: requested)
    }

    /// 预取当前版本相邻的加载器状态（仅 1 个候选；详情页打开 / 切换版本时调用）
    private func prefetchNearbyLoaders(for version: String) {
        guard pageType == .loaderSelector, sortedVersions.count > 1,
              let idx = sortedVersions.firstIndex(of: version) else { return }
        if idx > 0 { LoaderSupportChecker.prefetchForVersion(sortedVersions[idx - 1]) }
        if idx < sortedVersions.count - 1 { LoaderSupportChecker.prefetchForVersion(sortedVersions[idx + 1]) }
    }

    /// 应用逐加载器状态到 UI 派生状态（主线程调用）
    private func applyLoaderStates(_ states: [String: LoaderState], version: String) {
        availableLoaders = LoaderSupportChecker.loaderOrder.filter { states[$0] == .supported }
        isLoadingLoaders = states.values.contains { $0 == .checking }
        let hasUnknown = states.values.contains { $0 == .unavailable }
        loaderError = hasUnknown ? "部分加载器信息暂时无法获取，点击卡片可重试" : nil
        // 仅当用户未主动取消选择（非空）且当前选择不在可用列表时才自动选中第一个；
        // 空字符串 = 用户点了已选中卡片主动取消（下载纯原版），刷新后保持不选
        if !selectedLoader.isEmpty, !availableLoaders.contains(selectedLoader), let first = availableLoaders.first {
            selectedLoader = first
        }
    }

    /// 版本下拉列表的版本来源（仅决定「有哪些版本可显示」，不做过滤）：
    /// - 游戏版本页（加载器选择器）：优先使用 Mojang manifest 获取的版本列表
    /// - 其他页面：显示本地 versions 文件夹里实际安装的版本
    /// - 本地没有任何版本时：回退到默认版本列表
    private var availableVersions: [String] {
        // 游戏版本页：优先使用 Mojang manifest 获取的版本列表
        if pageType == .loaderSelector && !manifestVersions.isEmpty {
            return GameVersionHelper.sortForDisplay(manifestVersions, selected: settings.selectedMinecraftVersion)
        }
        // 本地实际安装的版本
        let owned = GameDirectoryScanner.localOwnedVersions(gameRoot: settings.selectedGameRoot)
        if !owned.isEmpty {
            return GameVersionHelper.sortForDisplay(owned, selected: settings.selectedMinecraftVersion)
        }
        return GameVersionHelper.sortForDisplay(baseVersions, selected: settings.selectedMinecraftVersion)
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
        let sorted = ModpackVersionGrouping.uniqueGameVersions(modpackVersions)
        cachedUniqueVersions = sorted
        return sorted
    }

    private func findCrossVersionDownload(for targetVersion: String) -> String? {
        CrossVersionFinder.find(
            in: sortedVersions,
            target: targetVersion,
            pageType: pageType,
            gameRoot: settings.selectedGameRoot
        )
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
        guard !selectedVersion.isEmpty else { return }

        // 点击即提示「下载开始」（此前仅下载完成后才提示「下载完成」）
        settings.javaPopupMessage = "下载开始"
        settings.showJavaPopup = true
        
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
                versionStr: selectedVersion,
                loader: selectedLoader.lowercased(),
                loaderSupported: availableLoaders.contains { $0.lowercased() == selectedLoader.lowercased() },
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
            selectedVersion: selectedVersion,
            selectedLoader: selectedLoader,
            selectedModpackVersionId: selectedModpackVersionId,
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
                title: pageItem.name,
                subtitle: translationModel.subtitle(for: pageItem),
                tags: pageItem.tags,
                onBack: { goBack() }
            )

            VStack(alignment: .leading, spacing: 14) {
                VersionSelectionSection(
                    pageType: pageTypeForIndex,
                    sortedVersions: sortedVersions,
                    availableLoaders: availableLoaders,
                    uniqueVersions: uniqueGameVersions(),
                    projectLoaders: projectLoaders,
                    localVersionLoaders: localVersionLoaders,
                    isLoadingModpackVersions: isLoadingModpackVersions,
                    isLoadingLoaders: isLoadingLoaders,
                    loaderStates: loaderStates,
                    loaderError: (pageTypeForIndex == .loaderSelector && isBasePage) ? loaderError : nil,
                    onRetryLoaders: { fetchLoaderSupport(for: selectedVersion) },
                    selectedVersion: $selectedVersion,
                    selectedLoader: $selectedLoader,
                    selectedModpackVersionId: $selectedModpackVersionId
                )

                if pageTypeForIndex == .shader, !hasShaderFolder, shaderFolderChecked, isBasePage {
                    ShaderPrerequisiteSection(onSelect: { navigateToPrerequisite($0) })
                }

                if pageTypeForIndex != .loaderSelector && pageTypeForIndex != .modpack {
                    // 光影页面：加载器只显示 Iris/OptiFine 等光影加载器，过滤模组加载器
                    let filteredLoaders = ShaderLoaderFilter.filtered(projectLoaders: projectLoaders, pageType: pageTypeForIndex)
                    SupportedMetaSection(
                        title: pageTypeForIndex.supportedVersionTitle,
                        rangeText: versionRangeText,
                        filteredLoaders: filteredLoaders
                    )
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

    /// 页签副标题按需翻译：逐条走共享 CardTranslationModel（内存→磁盘→网络，去重防抖）。
    /// 相比原简化实现，磁盘缓存命中的简介现在也能秒出（原实现只查内存 + 直接联网）
    private func translateDetailDescription() {
        let pages = allPages
        let service = TranslationService.shared
        for pageItem in pages {
            guard !pageItem.id.isEmpty else { continue }
            Task.detached(priority: .background) {
                await translationModel.requestTranslation(for: pageItem, service: service)
            }
        }
    }
}

