//
//  LaunchAvatarSkinViewModel.swift
//  模块化收口：CategoryContentView「启动」分类头像皮肤数据管道与皮肤生命周期决策的唯一持有者。
//
//  收口范围（对标 ContentView → NavigationState / DownloadCategoryViewModel 的做法）：
//  - 皮肤数据获取优先级链：持久化皮肤原图 → 离线 UUID 皮肤磁盘缓存 → 内置 Steve（preloadedSkinData）；
//  - 游戏 JAR 皮肤提取编排：应用支持目录落盘、缓存命中判定、提取产物回退（loadSkinImageIfNeededAsync）；
//  - 皮肤文件变更后的后台重读与头/帽成品裁剪（reloadSkinDataFromFile / refreshSkinData）；
//  - 皮肤生命周期刷新决策：版本变更 / 版本选中通知 / 视图出现三处的「非启动中」守卫与渲染事务外延迟。
//
//  刻意留在视图层的部分：
//  - 启动面板全部布局（卡片尺寸、日志面板位移与透明度、材质与描边）、卡片弹跳与输入框缩放动画；
//  - 离线用户名提示文案的展示（校验规则本身已在 OfflineUsernameValidator）；
//  - 分类路由（category.name → 子页面）；启动触发不在本类型范围（先经 LaunchEntryViewModel
//    做版本前置校验与重复启动拦截，再由 LaunchCoordinator 承担启动编排）；
//  - 首帧焦点兜底 AppKit 占位视图（FirstResponderReset / FocusSinkView 不可脱离视图层）；
//  - 皮肤文件变更的订阅点（.onChange(of: settings.skinImageURL)）保留在视图，仅把处理转发到本类型。
//
//  线程约定：与收口前一致——重 IO 走 Task.detached(priority: .userInitiated)，回写经 MainActor.run；
//  视图出现路径上的状态写入仍延迟到渲染事务外（DispatchQueue.main.async），避免
//  "Modifying state during view update"（UAF 前兆）。
//
//  依赖来源说明：调用方注入的 settings / sessionManager 即 LauncherSettings.shared 与
//  LaunchSessionManager.shared（见 ContentView 注入点），故本类型内直接读取同一单例对象，
//  与收口前经 EnvironmentObject / ObservedObject 读取的是同一个引用，取值语义不变。
//
//  隔离标注依据：SwiftUI《View》——被全局 actor 标注的协议，其遵循类型推断为该 actor 隔离。
//  收口前上述决策位于 CategoryContentView（View）内，标注 @MainActor 后隔离语义与收口前相同。
//  官方链接：https://developer.apple.com/documentation/swiftui/view
//  官方链接：https://developer.apple.com/documentation/swiftui/state
//

import SwiftUI
import Combine

@MainActor
final class LaunchAvatarSkinViewModel: ObservableObject {

    // MARK: - 皮肤数据

    /// 皮肤原图数据：视图创建时同步预载（持久化皮肤 → UUID 皮肤磁盘缓存 → 内置 Steve），
    /// 双层渲染（头+帽）拿到数据后立即裁剪显示，首帧不再空白等待 JAR 提取
    @Published var avatarSkinData: Data? = LaunchAvatarSkinViewModel.preloadedSkinData()

    /// 头像成品（头+帽）预裁缓存：后台裁剪，主线程渲染路径零 CoreImage
    /// （否则每次布局重算同步 new CIContext + createCGImage 会卡住动画帧）
    @Published var headImage: NSImage?
    @Published var hatImage: NSImage?

    // MARK: - 依赖

    private var settings: LauncherSettings { LauncherSettings.shared }
    private var sessionManager: LaunchSessionManager { LaunchSessionManager.shared }

    // MARK: - 视图出现：首帧裁剪兜底 + 皮肤 URL 准备

    /// 头像出现时调用（原 avatarView.onAppear 的等效下沉）。
    /// 首帧若尚未裁剪（预载 Data 成功但成品未出），后台裁出头/帽；
    /// 皮肤 URL 读取与 JAR 提取经 DispatchQueue.main.async 延迟到渲染事务外启动。
    func handleAvatarAppear() {
        if avatarSkinData != nil && headImage == nil {
            refreshSkinData()
        }
        // 延迟到渲染事务外：onAppear 同步写 @Published 会触发
        // "Modifying state during view update"（UAF 崩溃前兆）
        DispatchQueue.main.async {
            let isLaunching = LaunchSessionManager.shared.isLaunching
            let mcVersion = LauncherSettings.shared.selectedMinecraftVersion
            let gameDirPath = LauncherSettings.shared.selectedGameRoot.isEmpty
                ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "")
                : LauncherSettings.shared.selectedGameRoot
            let offlineUUID = LauncherSettings.shared.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
            Task.detached(priority: .userInitiated) {
                let result = await Self.loadSkinImageIfNeededAsync(
                    isLaunching: isLaunching,
                    selectedMinecraftVersion: mcVersion,
                    gameDirPath: gameDirPath,
                    offlineUUID: offlineUUID
                )
                if let url = result {
                    await MainActor.run { LauncherSettings.shared.skinImageURL = url }
                }
            }
        }
    }

    // MARK: - 皮肤数据重载与裁剪

    /// 皮肤文件变更后后台重读（避免主线程 IO），data 变化触发 refreshSkinData 重裁
    func reloadSkinDataFromFile() {
        guard let url = settings.skinImageURL, FileManager.default.fileExists(atPath: url.path) else { return }
        Task.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: url) {
                await MainActor.run { self.avatarSkinData = data }
            }
        }
    }

    /// 后台裁剪头/帽成品，主线程只接收成品（渲染路径零 CoreImage）
    func refreshSkinData() {
        guard let data = avatarSkinData else { return }
        Task.detached(priority: .userInitiated) {
            let head = SkinLayerView.cropped(imageData: data, startX: 8, startY: 16)
            let hat = SkinLayerView.cropped(imageData: data, startX: 40, startY: 16)
            await MainActor.run {
                self.headImage = head
                self.hatImage = hat
            }
        }
    }

    // MARK: - 皮肤生命周期决策

    /// 当前实例版本变更：非启动中才刷新头像。
    /// 内层再次读取 isLaunching 与收口前一致（闭包内取执行时刻的值，而非触发时刻的捕获值）。
    func handleSelectedMinecraftVersionChange(isLaunching: Bool) {
        guard !isLaunching else { return }
        // 延迟到渲染事务外执行：onChange 处于视图更新事务中，同步写 @Published
        // 会触发 "Modifying state during view update" → 未定义行为 → UAF 崩溃（EXC_BAD_ACCESS 跳进位图区）
        DispatchQueue.main.async {
            OfflineSkinService.loadAvatarFromGameOrBundle(
                isLaunching: LaunchSessionManager.shared.isLaunching,
                settings: LauncherSettings.shared
            )
        }
    }

    /// 版本选中通知：非启动中才补默认皮肤
    func handleGameVersionSelected(isLaunching: Bool) {
        guard !isLaunching else { return }
        DispatchQueue.main.async {
            OfflineSkinService.loadDefaultIfNeeded(
                isLaunching: LaunchSessionManager.shared.isLaunching,
                settings: LauncherSettings.shared
            )
        }
    }

    /// 视图出现：同一渲染事务外时点依次准备头像与默认皮肤（与收口前语句顺序一致）。
    /// 收口前此处无外层守卫，isLaunching 由服务层内读取，故本方法同样不接收该参数。
    func handleViewAppear() {
        DispatchQueue.main.async {
            OfflineSkinService.loadAvatarFromGameOrBundle(
                isLaunching: LaunchSessionManager.shared.isLaunching,
                settings: LauncherSettings.shared
            )
            OfflineSkinService.loadDefaultIfNeeded(
                isLaunching: LaunchSessionManager.shared.isLaunching,
                settings: LauncherSettings.shared
            )
        }
    }

    /// 视图消失：停止暗色条动画（动画状态归 LaunchSessionManager 所有）
    func handleViewDisappear() {
        sessionManager.stopDarkBarAnimation()
    }

    // MARK: - 数据获取（原 CategoryContentView 静态实现，逻辑逐字保留）

    /// 视图创建时同步预载皮肤数据：持久化皮肤原图 → 离线 UUID 皮肤磁盘缓存 → 内置 Steve。
    /// 均为本地小文件（几 KB~几十 KB），个位数毫秒级，首帧双层裁剪立即有图
    private static func preloadedSkinData() -> Data? {
        let settings = LauncherSettings.shared
        if let url = settings.skinImageURL, FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
        // 皮肤读取经 Skin 服务层（DefaultSkinService 内部即委托 MinecraftSkinManager，返回语义不变）
        if let data = DefaultSkinService().skinData(forUUID: offlineUUID) {
            return data
        }
        if let builtin = Bundle.main.url(forResource: "stf", withExtension: "png") {
            return try? Data(contentsOf: builtin)
        }
        return nil
    }

    /// 后台异步加载皮肤 URL（JAR 提取等重 IO 在后台执行，返回 URL 由调用方在主线程写入）
    private static func loadSkinImageIfNeededAsync(
        isLaunching: Bool,
        selectedMinecraftVersion: String,
        gameDirPath: String,
        offlineUUID: String
    ) async -> URL? {
        guard !isLaunching else { return nil }
        let appSupport = URL.applicationSupportDirectory
        let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
        try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")

        if let cachedSkinData = DefaultSkinService().skinData(forUUID: offlineUUID) {
            try? cachedSkinData.write(to: skinDestURL, options: .atomic)
            return skinDestURL
        }

        if !selectedMinecraftVersion.isEmpty && !gameDirPath.isEmpty,
           let gameDirURL = Optional(URL(fileURLWithPath: gameDirPath)),
           let skinURL = SkinExtractor.extractFromGameJar(version: selectedMinecraftVersion, gameDir: gameDirURL) {
            if let skinData = try? Data(contentsOf: skinURL) {
                try? skinData.write(to: skinDestURL, options: .atomic)
                return skinDestURL
            }
            return skinURL
        }

        return Bundle.main.url(forResource: "stf", withExtension: "png")
    }
}
