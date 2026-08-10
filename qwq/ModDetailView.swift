//
//  ModDetailView.swift
//  模块化拆分：从 GameViews.swift 拆出（原文件 2776 行，拆分后职责单一、可读性提升）
//

import SwiftUI
import AppKit

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
            startGameVersionDownload()
            return
        }

        // 真正的下载逻辑：解析目标文件 → 创建下载任务 → 打开详情页 → 启动任务
        // 闭包只捕获值类型（pageType/item/selectedVersion/selectedLoader）与引用类型
        // （settings/manager），绝不捕获视图 struct：视图销毁后 @State 指针悬垂 = UAF。
        let pageType = self.pageType
        let item = self.item
        let selectedVersion = self.selectedVersion
        let selectedLoader = self.selectedLoader
        let selectedModpackVersionId = self.selectedModpackVersionId
        let settings = self.settings

        Task.detached(priority: .userInitiated) {
            do {
                let resolved = try await ModDetailView.resolveDownloadFile(
                    pageType: pageType,
                    item: item,
                    selectedVersion: selectedVersion,
                    selectedLoader: selectedLoader,
                    selectedModpackVersionId: selectedModpackVersionId,
                    settings: settings
                )
                // destination 必须是完整文件路径（目录 + 文件名），供 SingleFileDownloader 落盘
                let destFile = resolved.destination.appendingPathComponent(resolved.filename)
                let task = ModFileDownloadTask(
                    url: resolved.url,
                    destination: destFile,
                    title: resolved.title
                )
                task.onComplete { [pageType, settings, manager] in
                    Task { @MainActor in
                        if pageType == .modpack, task.failureReason == nil {
                            // 整合包：zip 下载完成后还需解压安装（含 Minecraft/加载器/模组下载）
                            settings.javaPopupMessage = "正在安装整合包…"
                            settings.showJavaPopup = true
                            Task.detached(priority: .userInitiated) {
                                do {
                                    try await ModpackInstaller().install(
                                        packURL: destFile,
                                        to: URL(fileURLWithPath: LauncherSettings.shared.selectedGameRoot)
                                    )
                                    await MainActor.run {
                                        // 回调只操作全局单例（DownloadDetailManager）与 settings，
                                        // 不写视图 @State：后台回调晚于视图销毁时写 State storage 会 UAF
                                        DownloadDetailManager.shared.dismiss()
                                        settings.javaPopupMessage = "下载完成"
                                        settings.showJavaPopup = true
                                    }
                                } catch {
                                    await MainActor.run {
                                        DownloadDetailManager.shared.dismiss()
                                        settings.launchErrorMessage = "整合包安装失败: \(error.localizedDescription)"
                                        settings.showLaunchAlert = true
                                    }
                                }
                            }
                        } else {
                            DownloadDetailManager.shared.dismiss()
                            if let reason = task.failureReason {
                                settings.launchErrorMessage = "下载失败: \(reason)"
                                settings.showLaunchAlert = true
                            } else {
                                settings.javaPopupMessage = "下载完成"
                                settings.showJavaPopup = true
                            }
                        }
                    }
                }
                await MainActor.run {
                    manager.start(task)
                }
                task.start()
            } catch {
                await MainActor.run {
                    // 只操作全局单例与 settings（引用类型，生命周期与视图解耦）
                    DownloadDetailManager.shared.dismiss()
                    settings.launchErrorMessage = "下载失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }

    /// 游戏版本页下载安装（对标 PCL.Mac DownloadPage「开始下载」）：
    /// 用 MinecraftInstaller.createTask 建 Minecraft 安装任务（客户端清单/资源索引/本体/依赖/natives），
    /// 若用户选了加载器则追加对应加载器任务（key = fabric/forge/neoforge），组合成 InstallTasks
    /// 进入下载详情页；createTask 内部会从 DataManager.inprogressInstallTasks 按 key 找到加载器任务，
    /// 在客户端 jar 下载完成后自动串联安装（与 PCL.Mac createTask 行为一致）。
    /// 闭包只捕获值类型（versionStr/loader/loaderSupported）与引用类型（settings/manager），
    /// 不捕获视图 struct：视图销毁后 @State 指针悬垂 = UAF。
    private func startGameVersionDownload() {
        let versionStr = selectedVersion
        // selectedLoader 非可选（默认 "fabric"），但加载器是否真的可装取决于 availableLoaders
        // （fetchLoaderSupport 实时检测结果）：无可用加载器的版本 → 装纯原版
        let loader = selectedLoader.lowercased()
        let loaderSupported = availableLoaders.contains { $0.lowercased() == loader }
        let settings = self.settings
        let manager = DownloadDetailManager.shared

        Task {
            do {
                let root = settings.selectedGameRoot
                guard !root.isEmpty else { throw MyLocalizedError(reason: "未设置游戏根目录") }

                let minecraftDirectory = MinecraftDirectory(rootURL: URL(fileURLWithPath: root), name: "默认文件夹")
                let minecraftVersion = MinecraftVersion(displayName: versionStr)

                // 实例名：原版 = 版本号；带加载器 = 版本号 + "-" + 加载器名（与本地实例命名约定一致，如 1.20.1-Fabric）
                var name = versionStr
                var loaderKey: String? = nil
                if loaderSupported {
                    let brand: ClientBrand
                    switch loader {
                    case "fabric": brand = .fabric
                    case "forge": brand = .forge
                    case "neoforge", "neoforged": brand = .neoforge
                    case "quilt":
                        throw MyLocalizedError(reason: "Quilt 暂不支持一键下载安装，请使用 Fabric 或 Forge")
                    default:
                        throw MyLocalizedError(reason: "不支持的加载器: \(loader)")
                    }
                    name += "-\(brand.getName())"
                    loaderKey = brand.rawValue
                }

                // 组装任务集合（key 必须在 InstallTasks.getTasks() 固定顺序表内）
                let tasks = InstallTasks.empty()
                let minecraftTask = MinecraftInstaller.createTask(minecraftVersion, name, minecraftDirectory)
                tasks.addTask(key: "minecraft", task: minecraftTask)

                if let loaderKey {
                    // 交互是「点加载器卡片选类型」，没有版本选择 UI → 自动取该加载器最新版本
                    let loaderVersion = try await LoaderVersionResolver.latestVersion(loader: loaderKey, mcVersion: versionStr)
                    switch loaderKey {
                    case "fabric":
                        tasks.addTask(key: "fabric", task: FabricInstallTask(loaderVersion: loaderVersion))
                    case "forge":
                        tasks.addTask(key: "forge", task: ForgeInstallTask(forgeVersion: loaderVersion))
                    case "neoforge":
                        tasks.addTask(key: "neoforge", task: NeoforgeInstallTask(neoforgeVersion: loaderVersion))
                    default: break
                    }
                }

                let completedName = name
                minecraftTask.onComplete { [settings, manager, completedName] in
                    Task { @MainActor in
                        // 回调只操作全局单例（DownloadDetailManager）与 settings，
                        // 不写视图 @State：后台回调晚于视图销毁时写 State storage 会 UAF
                        manager.dismiss()
                        settings.javaPopupMessage = "\(completedName) 下载完成"
                        settings.showJavaPopup = true
                    }
                }

                // 打开详情页 + 同步 DataManager（createTask 内部按 tasks[key] 找加载器任务）→ 启动
                await MainActor.run {
                    manager.start(tasks)
                }
                tasks.tasks["minecraft"]!.start()
            } catch {
                await MainActor.run {
                    // 只操作全局单例与 settings（引用类型，生命周期与视图解耦）
                    manager.dismiss()
                    settings.launchErrorMessage = "下载失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }

    /// 解析本次下载的目标文件信息（URL/文件名/目标目录/标题），供下载详情页任务使用。
    /// 返回后由 ModFileDownloadTask 负责带进度下载（SingleFileDownloader → NetManager）。
    /// 静态方法 + 显式参数：避免后台 Task 隐式捕获视图 struct（@State 指针悬垂 = UAF）。
    private static func resolveDownloadFile(
        pageType: DetailPageType,
        item: DownloadedItem,
        selectedVersion: String,
        selectedLoader: String,
        selectedModpackVersionId: String,
        settings: LauncherSettings
    ) async throws -> (url: URL, filename: String, destination: URL, title: String) {
        let gameVersion = selectedVersion
        let gameRoot = settings.selectedGameRoot

        guard !gameVersion.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择游戏版本"]) }
        guard !gameRoot.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未设置游戏根目录"]) }

        switch pageType {
        case .mod:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "模组 ID 为空"]) }
            // 游戏启动时 game_directory 指向 <gameRoot>/versions/<version>，
            // mods 必须放在版本文件夹内才会被游戏加载
            let modsDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(gameVersion)/mods")
            try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
            let loader: ModLoader
            switch selectedLoader.lowercased() {
            case "fabric": loader = .fabric
            case "forge": loader = .forge
            case "neoforge", "neoforged": loader = .neoforge
            case "quilt": loader = .quilt
            default: loader = .fabric
            }
            let (url, filename) = try await ModDownloader().resolveLatestFile(modId: item.id, gameVersion: gameVersion, loader: loader)
            return (url, filename, modsDir, item.name)

        case .shader:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "光影 ID 为空"]) }
            // 光影放在版本文件夹的 shaderpacks（游戏 gameDir = versions/<version>）
            let shaderDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(gameVersion)/shaderpacks")
            try FileManager.default.createDirectory(at: shaderDir, withIntermediateDirectories: true)
            // 光影项目版本的 loaders 字段通常是 ["minecraft"] 或空，不能按 fabric 模组过滤
            let (url, filename) = try await ModDownloader().resolveLatestFile(modId: item.id, gameVersion: gameVersion)
            return (url, filename, shaderDir, item.name)

        case .resourcePack:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "资源包 ID 为空"]) }
            // 资源包放在版本文件夹的 resourcepacks（游戏 gameDir = versions/<version>）
            let resourcePackDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(gameVersion)/resourcepacks")
            try FileManager.default.createDirectory(at: resourcePackDir, withIntermediateDirectories: true)
            // 资源包项目版本的 loaders 字段通常是 ["minecraft"] 或空，不能按 fabric 模组过滤
            let (url, filename) = try await ModDownloader().resolveLatestFile(modId: item.id, gameVersion: gameVersion)
            return (url, filename, resourcePackDir, item.name)

        case .modpack:
            guard !item.id.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "整合包 ID 为空"]) }
            guard !selectedModpackVersionId.isEmpty else { throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "未选择整合包版本"]) }
            // 整合包下载到版本目录
            let versionDir = URL(fileURLWithPath: gameRoot).appendingPathComponent("versions/\(selectedModpackVersionId)")
            try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
            let (url, filename) = try await ModpackDownloader().resolveFile(packId: item.id, versionId: selectedModpackVersionId)
            return (url, filename, versionDir, item.name)

        case .loaderSelector:
            // 兜底：正常流程已在 startDownload() 提前走 startGameVersionDownload()，不会走到这里
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "游戏版本下载请使用右下角下载按钮"])
        }
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
                                            // 再点已选中的卡片 = 取消选中（不装加载器，下载纯原版）
                                            selectedLoader = (selectedLoader == loader) ? "" : loader
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
        return selectedLoader.isEmpty ? "fabric" : selectedLoader
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

