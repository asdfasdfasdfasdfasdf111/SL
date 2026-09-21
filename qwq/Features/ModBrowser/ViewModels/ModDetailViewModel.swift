//
//  ModDetailViewModel.swift
//  模块化收口：ModDetailView（模组/光影/资源包/整合包/游戏版本详情页）业务决策的唯一持有者。
//
//  收口范围（对标 ContentView → NavigationState / GameViews → DownloadCategoryViewModel）：
//  - 项目详情取数（DefaultModBrowserService.projectDetail）与「本地版本 ∩ 兼容版本」、
//    「跨版本内容列本地全量版本」两条版本列表规则；
//  - 版本列表来源决策（Mojang 清单 / 本地 versions 目录 / 内置兜底清单）与清单子分类过滤；
//  - 默认选中版本的两次决议（首次加载、清单就绪后）与本地加载器映射扫描时机；
//  - 加载器支持检测状态机：缓存定论初始化、流式逐项回写、请求归属校验、相邻版本预取、
//    错误映射（unavailable → 可重试提示）、可用加载器派生与选中回退；
//  - 整合包版本取数与唯一游戏版本分组缓存、跨版本自动匹配查找；
//  - 副标题翻译调度（逐条走共享 CardTranslationModel）与视图存活标记。
//
//  刻意留在视图层的部分：
//  - 全部布局（页面横向位移 offset、卡片与按钮间距、内容缩进）与所有 withAnimation 调用及动画参数；
//  - 页面滑动栈（prerequisiteStack / navSlideOffset / pageWidth）与返回延迟任务 backNavTask、
//    下载按钮弹跳 bounceTask：二者写的是视图坐标与动画状态，迁入 ViewModel 只会把手势/事务语义引入状态层；
//  - 下载触发 startDownload：仅做「页面类型 → 已下沉的 GameVersionDownloadStarter /
//    ModFileDownloadStarter」分支转发与动画调度，未含业务决策，故与启动器提示一并留在视图；
//  - 翻译状态对象 CardTranslationModel 的生命周期（视图以 @StateObject 持有，本类型按需接收其引用调度）。
//
//  线程约定：与收口前一致——所有异步回写经 MainActor.run，onAppear/onChange 内的状态写入
//  延迟到渲染事务外（DispatchQueue.main.async），避免 "Modifying state during view update"（UAF 前兆）。
//
//  依赖来源说明：调用方注入的 settings 即 LauncherSettings.shared（ContentView 注入点），
//  本类型内读取同一单例对象，取值语义与收口前一致。
//
//  隔离标注依据：SwiftUI《View》——被全局 actor 标注的协议，其遵循类型推断为该 actor 隔离。
//  收口前上述决策位于 ModDetailView（View）内，标注 @MainActor 后隔离语义与收口前相同。
//  官方链接：https://developer.apple.com/documentation/swiftui/view
//  官方链接：https://developer.apple.com/documentation/swiftui/state
//  官方链接：https://developer.apple.com/documentation/swiftui/onchange(of:perform:)
//  （项目部署基线 macOS 13.0，onChange 只能使用已废弃的单参数签名 onChange(of:perform:)）
//

import SwiftUI
import Combine

@MainActor
final class ModDetailViewModel: ObservableObject {

    /// 启动器设置：调用方注入的即为该单例，直接引用而非复制状态
    private let settings = LauncherSettings.shared

    // MARK: - 版本选择

    @Published var selectedVersion: String = ""
    @Published var selectedLoader: String = "fabric"
    @Published var sortedVersions: [String] = []
    @Published var manifestVersions: [String] = []
    @Published var localVersionLoaders: [String: ModLoader] = [:]
    @Published var hasScannedLocalVersions = false

    // MARK: - 光影目录检测

    @Published var hasShaderFolder: Bool = false
    @Published var shaderFolderChecked: Bool = false

    // MARK: - 项目详情

    @Published var projectGameVersions: [String] = []
    @Published var projectLoaders: [String] = []
    // isLoadingProject 已删除：项目详情取数期间无任何视图读取该标记
    // （版本列表本就以空数组起步、卡片自行显示占位），保留只会让赋值的视图失效成为空转。

    // MARK: - 加载器支持检测

    @Published var availableLoaders: [String] = []
    @Published var isLoadingLoaders = false
    /// 结果未知（网络失败/5xx/超时）与「明确不支持」区分展示，不再误报「没有加载器」
    @Published var loaderError: String?
    /// 逐加载器检测状态（流式：完成一个显示一个，不再等全部结束才出卡片）
    @Published var loaderStates: [String: LoaderState] = [:]
    /// 加载器检测完成顺序（先定论的在最前；只用于 supported 卡片排序）
    @Published var loaderCompletionOrder: [String] = []
    /// 加载器检测任务：持有引用以便切换版本/销毁视图时取消（UAF 防护）
    /// 仅用于 cancel()，无任何展示读取点，故不做 @Published；否则每次赋值都会触发
    /// 一次无对应的视图失效。
    private var loaderSupportTask: Task<Void, Never>?

    // MARK: - 整合包版本

    @Published var modpackVersions: [ModpackVersion] = []
    @Published var isLoadingModpackVersions = false
    @Published var selectedModpackVersionId: String = ""
    @Published var cachedUniqueVersions: [(gameVersion: String, version: ModpackVersion)]? = nil

    // MARK: - 视图存活标记

    /// 视图存活标记（onAppear/onDisappear 联动，异步回调据此判断是否继续写回）
    @Published var isViewActive = false

    // MARK: - 生命周期

    func activate() {
        isViewActive = true
    }

    /// 视图消失：先置存活标记再取消在途检测任务（与收口前顺序一致）
    func deactivate() {
        isViewActive = false
        loaderSupportTask?.cancel()
    }

    // MARK: - 版本下拉列表来源

    /// 版本下拉列表的版本来源（仅决定「有哪些版本可显示」，不做过滤）：
    /// - 游戏版本页（加载器选择器）：优先使用 Mojang manifest 获取的版本列表
    /// - 其他页面：显示本地 versions 文件夹里实际安装的版本
    /// - 本地没有任何版本时：回退到默认版本列表
    private func availableVersions(pageType: DetailPageType) -> [String] {
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

    private var baseVersions: [String] {
        ["1.21.4", "1.21.1", "1.18", "1.19.1"]
    }

    // MARK: - 首次加载

    /// 详情页首次加载：本地加载器扫描 + 版本列表就绪 + 默认选中版本决策
    func applyDefaultVersionSelection(pageType: DetailPageType, itemName: String) {
        if sortedVersions.isEmpty {
            if (pageType == .mod || pageType == .shader || pageType == .resourcePack), !hasScannedLocalVersions {
                hasScannedLocalVersions = true
                localVersionLoaders = GameDirectoryScanner.scanLocalLoaderMap(gameRoot: settings.selectedGameRoot)
            }
            sortedVersions = availableVersions(pageType: pageType)

            // 默认选中决策集中在 DetailVersionDecision（游戏版本页必须选用户点击的版本，
            // 其他页面优先当前实例版本；item.name 不在列表时不急着回退，等 manifest 就绪决议）
            if let selected = DetailVersionDecision.initialSelection(
                pageType: pageType,
                itemName: itemName,
                sortedVersions: sortedVersions,
                instanceVersion: settings.selectedMinecraftVersion.isEmpty ? nil : settings.selectedMinecraftVersion
            ) {
                selectedVersion = selected
            }
        }
    }

    /// 详情页条件数据加载（游戏版本清单 / 光影目录检测 / 整合包版本 / 项目详情与翻译）。
    /// 翻译调度对象由视图侧 @StateObject 持有，此处按需接收引用（与列表页 ViewModel 做法一致）。
    func triggerPageLoads(pageType: DetailPageType,
                          item: DownloadedItem,
                          gameSubCategory: GameSubCategory?,
                          pages: [DownloadedItem],
                          translation: CardTranslationModel) {
        // 游戏版本页：异步获取 Mojang 版本清单
        if pageType == .loaderSelector && manifestVersions.isEmpty {
            fetchManifestVersions(pageType: pageType, itemName: item.name, gameSubCategory: gameSubCategory)
        }
        if pageType == .shader, !shaderFolderChecked {
            shaderFolderChecked = true
            hasShaderFolder = GameDirectoryScanner.hasShaderFolder(gameRoot: settings.selectedGameRoot, versions: baseVersions)
        }
        if pageType == .modpack, modpackVersions.isEmpty {
            fetchModpackVersions(itemId: item.id)
        }
        if !item.id.isEmpty {
            translateDetailDescription(pages: pages, translation: translation)
            fetchProjectDetails(itemId: item.id, pageType: pageType)
        }
    }

    // MARK: - 项目详情

    func fetchProjectDetails(itemId: String, pageType: DetailPageType) {
        guard !itemId.isEmpty, projectGameVersions.isEmpty else { return }
        Task {
            do {
                // 项目详情经 ModBrowser 服务层读取：DefaultModBrowserService.projectDetail
                // 内部即委托 ModDownloader.getProject，且 gameVersions/loaders 已按 ?? [] 归一。
                // 此处不取版本列表（fetchVersions 会多发一次请求，属行为变化，故不接入）。
                let project = try await DefaultModBrowserService().projectDetail(id: itemId)
                await MainActor.run {
                    guard isViewActive else { return }
                    projectGameVersions = project.gameVersions
                    projectLoaders = project.loaders
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
                // 项目详情取数失败：静默保留本地版本列表，不提示错误
                // （原实现仅在此复位 isLoadingProject，该死状态已删除）
            }
        }
    }

    /// 支持版本区间文案（首个-末个；只有一个版本时显示该版本）
    var versionRangeText: String {
        guard !projectGameVersions.isEmpty else { return "" }
        let sorted = projectGameVersions.sorted { GameVersionHelper.compare($0, $1) < 0 }
        if let first = sorted.first, let last = sorted.last {
            return first == last ? first : "\(first)-\(last)"
        }
        return sorted.first ?? ""
    }

    // MARK: - 游戏版本清单

    func fetchManifestVersions(pageType: DetailPageType, itemName: String, gameSubCategory: GameSubCategory?) {
        Task {
            let versions = await GameVersionManifest.fetchMerged()
            guard !versions.isEmpty else { return }
            // 分类过滤逻辑在 GameVersionFilter（release/snapshot/远古，与分类列表共享同一规则）
            let filtered = GameVersionFilter.filteredIDs(versions, subCategory: gameSubCategory)
            await MainActor.run {
                manifestVersions = filtered
                sortedVersions = availableVersions(pageType: pageType)
                // 决议规则集中在 DetailVersionDecision：
                // 先保留现有选择（含用户手动选择），其次用户点击的 item.name，最后才回退。
                // （此前无条件改 sortedVersions.first 会把当前实例版本 26.2 提到首位，
                //   冲掉 onAppear 按 item.name 的设置，触发 onChange → 缓存命中 4 张卡）
                if let resolved = DetailVersionDecision.resolveAfterManifest(
                    pageType: pageType,
                    current: selectedVersion,
                    itemName: itemName,
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

    func fetchLoaderSupport(for version: String, pageType: DetailPageType) {
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
        // 完成顺序：缓存已定论项在前（按显示顺序），检测中新定论的按流式到达顺序追加
        loaderCompletionOrder = LoaderSupportChecker.loaderOrder.filter { initial[$0] == .supported || initial[$0] == .notSupported }
        applyLoaderStates(initial)
        // 3. 无论当前版本是否命中缓存，都预加载相邻版本；缓存全命中正是后台预取的最佳时机。
        prefetchNearbyLoaders(for: requested, pageType: pageType)
        // 4. 全部定论（无 missing）→ 直接结束，绝不联网当前版本
        if LoaderSupportChecker.isFullyResolved(initial, for: version) { return }
        // 5. 流式联网：每个加载器检测完成立即逐项写 UI（完成一个显示一个）；
        //    写回前做归属校验（任务未取消且版本未切换），迟到的旧结果一律丢弃
        loaderSupportTask = Task {
            let stream = LoaderSupportChecker.streamLoaderStates(for: requested)
            for await (loader, state) in stream {
                await MainActor.run {
                    guard !Task.isCancelled, selectedVersion == requested else { return }
                    var states = loaderStates
                    states[loader] = state
                    loaderStates = states
                    if !loaderCompletionOrder.contains(loader) {
                        loaderCompletionOrder.append(loader)
                    }
                    applyLoaderStates(states)
                }
            }
        }
    }

    /// 预取当前版本相邻的加载器状态（仅 1 个候选；详情页打开 / 切换版本时调用）
    private func prefetchNearbyLoaders(for version: String, pageType: DetailPageType) {
        guard pageType == .loaderSelector, sortedVersions.count > 1,
              let idx = sortedVersions.firstIndex(of: version) else { return }
        if idx > 0 { LoaderSupportChecker.prefetchForVersion(sortedVersions[idx - 1]) }
        if idx < sortedVersions.count - 1 { LoaderSupportChecker.prefetchForVersion(sortedVersions[idx + 1]) }
    }

    /// 应用逐加载器状态到 UI 派生状态（主线程调用）
    private func applyLoaderStates(_ states: [String: LoaderState]) {
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

    // MARK: - 整合包版本

    func fetchModpackVersions(itemId: String) {
        guard !itemId.isEmpty else { return }
        isLoadingModpackVersions = true
        Task {
            do {
                let downloader = ModpackDownloader()
                let versions = try await downloader.versions(packId: itemId)
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

    func uniqueGameVersions() -> [(gameVersion: String, version: ModpackVersion)] {
        if let cached = cachedUniqueVersions { return cached }
        let sorted = ModpackVersionGrouping.uniqueGameVersions(modpackVersions)
        cachedUniqueVersions = sorted
        return sorted
    }

    // MARK: - 跨版本匹配

    func findCrossVersionDownload(for targetVersion: String, pageType: DetailPageType) -> String? {
        CrossVersionFinder.find(
            in: sortedVersions,
            target: targetVersion,
            pageType: pageType,
            gameRoot: settings.selectedGameRoot
        )
    }

    // MARK: - 翻译调度

    /// 页签副标题按需翻译：逐条走共享 CardTranslationModel（内存→磁盘→网络，去重防抖）。
    /// 相比原简化实现，磁盘缓存命中的简介现在也能秒出（原实现只查内存 + 直接联网）
    func translateDetailDescription(pages: [DownloadedItem], translation: CardTranslationModel) {
        let service = TranslationService.shared
        for pageItem in pages {
            guard !pageItem.id.isEmpty else { continue }
            Task.detached(priority: .background) {
                await translation.requestTranslation(for: pageItem, service: service)
            }
        }
    }
}
