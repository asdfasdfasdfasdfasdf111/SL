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


    @State private var translatedSubtitles: [String: String] = [:]
    @State private var projectGameVersions: [String] = []
    @State private var projectLoaders: [String] = []
    @State private var isLoadingProject = false

    @State private var availableLoaders: [String] = []
    @State private var isLoadingLoaders = false

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
                withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 240, damping: 14, initialVelocity: 8)) {
                    entryScale = 1.0
                    entryOpacity = 1.0
                    pageWidth = width
                }
                if sortedVersions.isEmpty {
                if (pageType == .mod || pageType == .shader || pageType == .resourcePack), !hasScannedLocalVersions {
                    hasScannedLocalVersions = true
                    localVersionLoaders = GameDirectoryScanner.scanLocalLoaderMap(gameRoot: settings.selectedGameRoot)
                }
                    sortedVersions = availableVersions

                    // 默认选中：
                    // - 游戏版本页（loaderSelector）：必须选中用户点击的版本（item.name），
                    //   否则会出现「标题是 1.7.2、加载器却显示当前实例版本 26.2 的 4 张卡片」的错乱
                    //   （根因：26.2 缓存命中 Fabric/Forge/NeoForged/Quilt，而 1.7.2 只有 Forge）
                    // - item.name 不在列表（manifest 未就绪时列表只有本地版本）：不急着回退，
                    //   避免误选当前实例版本 26.2（sortVersionsForDisplay 会把它提到列表首位）
                    //   命中缓存显示 4 张卡，等 fetchManifestVersions 完成回调按 item.name 重新决议
                    // - 其他页面：优先当前实例版本，其次第一个可用版本
                    if pageType == .loaderSelector {
                        if sortedVersions.contains(item.name) {
                            selectedVersion = item.name
                        }
                    } else {
                        if let defaultInstanceVersion = getDefaultInstanceVersion(),
                           sortedVersions.contains(defaultInstanceVersion) {
                            selectedVersion = defaultInstanceVersion
                        } else if let first = sortedVersions.first {
                            selectedVersion = first
                        }
                    }
                }
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
                .padding(.trailing, downloadDetail.showCircleButton ? 88 : 12)
                .padding(.bottom, 12)
                .animation(.interpolatingSpring(stiffness: 170, damping: 14), value: downloadDetail.showCircleButton)
            }
        }
        .onDisappear {
            // 视图销毁：取消延迟动画任务，防止其继续写已释放的 @State storage（UAF）
            bounceTask?.cancel()
            backNavTask?.cancel()
        }
        // 下载中状态跟随详情页开关：详情页打开/关闭时驱动下载按钮布局变化（圆按钮出现时左移）
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
                // 修复（d43cb4d 后 1.10 仍显示 4 卡的根因）：此回调此前无条件把
                // selectedVersion 改成 sortedVersions.first，而 sortVersionsForDisplay
                // 会把当前实例版本（26.2）提到列表首位——直接把 onAppear 按 item.name
                // 设的值冲掉，触发 onChange → fetchLoaderSupport("26.2") → 缓存命中 4 张卡。
                // 现改为：先保留现有选择（含用户手动选择），其次用户点击的 item.name，最后才回退。
                if pageType == .loaderSelector {
                    if !selectedVersion.isEmpty, sortedVersions.contains(selectedVersion) {
                        // 保留现有选择（onAppear 已按 item.name 设置，或用户手动选择）
                    } else if sortedVersions.contains(item.name) {
                        selectedVersion = item.name
                    } else if let first = sortedVersions.first {
                        selectedVersion = first
                    }
                } else if selectedVersion.isEmpty || !sortedVersions.contains(selectedVersion) {
                    if let first = sortedVersions.first {
                        selectedVersion = first
                    }
                }
            }
        }
    }

    // MARK: - 加载器支持检测（已下沉到 PCLCore 后端：LoaderSupportChecker）
    // UI 只消费结果，不直接联网、不直接读写缓存文件；内存/磁盘缓存、联网并发检测
    // 与失败回退均在核心层完成（三级策略：内存 → 磁盘 7 天 TTL → 联网，失败回退旧缓存）。

    private func fetchLoaderSupport(for version: String) {
        guard !version.isEmpty else { return }
        // 1. 同步查缓存命中：直接展示，不闪烁 loading（核心层 cachedLoaders）
        if let cached = LoaderSupportChecker.cachedLoaders(for: version) {
            applyLoaders(cached)
            return
        }
        // 2. 未命中：核心层异步联网检测（含磁盘写入与失败回退）
        isLoadingLoaders = true
        Task {
            let supported = await LoaderSupportChecker.supportedLoaders(for: version)
            await MainActor.run { applyLoaders(supported) }
        }
    }

    /// 应用加载器列表到 UI（主线程调用）
    private func applyLoaders(_ loaders: [String]) {
        availableLoaders = loaders
        isLoadingLoaders = false
        // 仅当用户未主动取消选择（非空）且当前选择不在可用列表时才自动选中第一个；
        // 空字符串 = 用户点了已选中卡片主动取消（下载纯原版），刷新后保持不选
        if !selectedLoader.isEmpty, !loaders.contains(selectedLoader), let first = loaders.first {
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
                subtitle: translatedSubtitles[pageItem.id] ?? pageItem.subtitle,
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

    /// 详情页翻译结果上限：页签条目有限但防极端场景无限增长；超限整体淘汰（重新浏览时再翻译）
    private static let maxTranslatedSubtitles = 2000

    private func setTranslated(_ id: String, _ value: String) {
        if translatedSubtitles[id] == nil, translatedSubtitles.count >= Self.maxTranslatedSubtitles {
            translatedSubtitles.removeAll(keepingCapacity: true)
        }
        translatedSubtitles[id] = value
    }

    private func translateDetailDescription() {
        let pages = allPages
        let service = TranslationService.shared
        for pageItem in pages {
            let id = pageItem.id
            guard !id.isEmpty else { continue }
            if let cached = service.cachedTranslation(for: id), !cached.isEmpty {
                setTranslated(id, cached)
                continue
            }
            Task.detached(priority: .background) {
                do {
                    let translated = try await service.translateText(text: pageItem.subtitle, projectId: id)
                    await MainActor.run {
                        self.setTranslated(id, translated)
                    }
                } catch {
                    _ = error
                }
            }
        }
    }
}

