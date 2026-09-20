//
//  DropInstallCoordinator.swift
//  模块化收口：把 ContentView 里「拖入文件 → 判定走模组还是整合包安装 → 匹配实例/挑目录
//  → 执行安装 → 提示结果」这一串业务决策搬到此文件。
//  View 只保留两件事：把拖拽事件转发进来、按协调器给出的状态渲染弹窗。
//  本类型不持有 SwiftUI 视图状态，可脱离界面单独测试。
//

import Foundation

/// 拖拽安装协调器：文件分流、实例匹配、安装执行与结果提示的唯一决策点。
///
/// 状态约定：弹窗开关与弹窗数据由本对象持有（`@Published`），修改一律发生在主线程
/// （拖拽回调经 `DragDropHandler` 回主队列，安装回调来自弹窗主线程动作）。
final class DropInstallCoordinator: ObservableObject {

    // MARK: - 弹窗状态（供 View 渲染）

    /// 模组安装目标选择弹窗是否展示
    @Published private(set) var showModInstallSheet = false
    /// 整合包安装位置选择弹窗是否展示
    @Published private(set) var showModpackInstallSheet = false
    /// 模组安装弹窗的可选实例（按模组版本需求过滤后的结果）
    @Published private(set) var modInstallInstances: [GameInstance] = []
    /// 模组安装弹窗展示名
    @Published private(set) var pendingModName = ""
    /// 模组安装弹窗所需游戏版本（版本范围原文）
    @Published private(set) var pendingModVersion = ""
    /// 整合包安装弹窗展示名
    @Published private(set) var pendingModpackName = ""

    // MARK: - 内部状态

    private var pendingModURL: URL?
    private var pendingModpackURL: URL?

    private let dropLoader = DragDropHandler()
    private let versionDetector = ModVersionDetector()
    private let settings = LauncherSettings.shared
    /// 结果提示统一走启动界面状态的投递入口，不直接操作设置字段
    private let launchPanel = LaunchPanelState.shared

    // MARK: - 拖拽入口

    /// View 的 `.onDrop` 入口。
    /// - Returns: 是否接受本次拖拽内容（沿用旧 `DragDropHandler.handleDrop` 的返回值语义）。
    func handle(providers: [NSItemProvider]) -> Bool {
        dropLoader.loadURLs(from: providers) { [weak self] urls in
            self?.handle(urls: urls)
        }
    }

    /// 已解析出的文件 URL 分流：「什么文件 → 走哪条安装路径」的唯一裁决点。
    func handle(urls: [URL]) {
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "jar":
                beginModInstall(url: url)
            case "zip", "mrpack":
                beginModpackInstall(url: url)
            default:
                break
            }
        }
    }

    // MARK: - 模组安装

    /// 模组安装前置决策：版本检测 → 匹配实例 → 打开选择弹窗；
    /// 任一前置条件不满足则直接提示并终止，不进入安装流程。
    private func beginModInstall(url: URL) {
        let modName = url.deletingPathExtension().lastPathComponent

        guard let versionInfo = versionDetector.detectVersion(from: url) else {
            launchPanel.presentError("无法检测模组「\(modName)」的 Minecraft 版本")
            return
        }

        let instances = ModDragInstaller.findInstances(for: versionInfo.versionRange,
                                                       savedRoot: settings.selectedGameRoot)
        guard !instances.isEmpty else {
            launchPanel.presentError("未找到与模组「\(modName)」（需要 \(versionInfo.versionRange)）匹配的游戏版本")
            return
        }

        pendingModURL = url
        pendingModName = modName
        pendingModVersion = versionInfo.versionRange
        modInstallInstances = instances
        showModInstallSheet = true
    }

    /// 用户在模组安装弹窗确认目标实例后执行安装。
    func confirmModInstall(instances: [GameInstance]) {
        if let modURL = pendingModURL {
            let count = ModDragInstaller.install(modURL: modURL, to: instances)
            launchPanel.presentMessage("模组已安装到 \(count) 个实例")
        }
        showModInstallSheet = false
    }

    /// 用户取消模组安装。
    func cancelModInstall() {
        showModInstallSheet = false
    }

    // MARK: - 整合包安装

    /// 整合包拖入即进入安装位置选择，无版本匹配前置条件。
    private func beginModpackInstall(url: URL) {
        pendingModpackURL = url
        pendingModpackName = url.deletingPathExtension().lastPathComponent
        showModpackInstallSheet = true
    }

    /// 用户在整合包弹窗确认目标文件夹后执行安装。
    func confirmModpackInstall(folderURL: URL) {
        installModpack(packURL: pendingModpackURL, to: folderURL)
        showModpackInstallSheet = false
    }

    /// 用户取消整合包安装。
    func cancelModpackInstall() {
        showModpackInstallSheet = false
    }

    private func installModpack(packURL: URL?, to folderURL: URL) {
        guard let packURL = packURL else { return }

        Task.detached(priority: .userInitiated) {
            do {
                try await ModpackInstaller().install(packURL: packURL, to: folderURL)
                await MainActor.run {
                    LaunchPanelState.shared.presentMessage("整合包安装完成")
                }
            } catch {
                await MainActor.run {
                    LaunchPanelState.shared.presentError("整合包安装失败: \(error.localizedDescription)")
                }
            }
        }
    }
}
