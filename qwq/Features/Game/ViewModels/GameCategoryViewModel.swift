//
//  GameCategoryViewModel.swift
//  模块化收口：「我的世界」分类页（GameCategoryView）扫描状态与业务决策的唯一持有者。
//
//  收口范围（对标 GameViews → DownloadCategoryViewModel、ModDetailView → ModDetailViewModel）：
//  - 游戏根目录扫描编排（已保存根目录优先 → 全盘兜底，规则在 GameScanService）；
//  - 10 秒超时判定与超时退化决议（是否仍应退化、退化后的展示状态）；
//  - 扫描结果决议：版本清单落库、游戏根目录切换、默认版本选择与「GameVersionSelected」通知投递；
//  - 全盘查找游戏（数量提示 + 首个有效游戏落库；无结果时不改动任何状态）；
//  - 手动选择目录的校验决策（versions 子目录是否存在 / 版本列表是否为空 / 对应错误文案）；
//  - Java 选择器标签派生与卡片底部按钮显隐派生。
//
//  刻意留在视图层的部分：
//  - NSOpenPanel 的构造与回调接线（AppKit 模态面板不可脱离视图层；视图只把选中路径交给本类型校验）；
//  - 「游戏检索中...」省略号逐帧计时器（loadingText / dotCount / Timer）与全部布局；
//  - 三处 withAnimation 调用及其参数（超时退化 0.8s、卡片出现 0.8s、载入结束 0.4s）与
//    `.animation(_:value:)` 曲线：动画事务留在视图，本类型只提供判定条件与「该事务内要写入的展示状态」；
//  - `.onChange(of: isLoading)` 的省略号计时器联动点（旧签名，macOS 13.0 可用，不改写为新签名）。
//
//  线程约定：与收口前一致——磁盘扫描走 `Task.detached(priority: .userInitiated)`，
//  回写经 `MainActor.run`；视图出现路径上的入口仍在渲染事务外（DispatchQueue.main.async）调起。
//
//  隔离标注说明：本类型标注 `@MainActor`，与 `NavigationState`（App/ViewModels）一致。
//  收口前这些决策位于 `GameCategoryView`（View），而 `View` 协议带全局 actor 标注，
//  遵循类型会被推断为同一 actor 隔离，故标注后隔离语义与收口前相同。
//
//  依赖来源说明：调用方注入的 settings 即 `LauncherSettings.shared`（ContentView 注入点），
//  本类型内读取同一单例对象，取值语义与收口前一致；提示统一经 `LaunchPanelState` 投递。
//
//  依据条目：SwiftUI《View》/ Swift《Attributes》——被全局 actor 标注的协议，
//  其遵循类型推断为该 actor 隔离。
//  官方链接：https://developer.apple.com/documentation/swiftui/view
//  官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/
//

import Foundation
import Combine

@MainActor
final class GameCategoryViewModel: ObservableObject {

    // MARK: - 依赖

    private let settings = LauncherSettings.shared
    /// 结果提示统一走启动界面状态的投递入口（与 DropInstallCoordinator 做法一致）
    private let launchPanel = LaunchPanelState.shared

    // MARK: - 展示状态

    /// 检索中（驱动「游戏检索中...」与卡片显隐；视图 onChange 据此启停省略号计时器）
    @Published private(set) var isLoading = true
    /// 版本卡片是否展示（超时退化与扫描结果两条路径都会置真）
    @Published private(set) var showCard = false
    /// 扫描得到的版本列表
    @Published private(set) var versions: [String] = []
    /// 是否已有可用版本（无结果与超时退化都会置假）
    @Published private(set) var hasVersions = false
    /// 10 秒超时是否已生效（迟到的扫描结果据此丢弃）
    @Published private(set) var scanTimedOut = false

    // MARK: - 派生展示值

    /// 卡片底部按钮显隐：有版本，或不处于检索中且版本为空（沿用收口前条件，逐字一致）
    var showBottomButtons: Bool {
        hasVersions || (versions.isEmpty && !isLoading)
    }

    /// Java 选择器标签：已选路径 → 对应 Java 大版本号；列表中查不到 → 「Java 自定义」；
    /// 未选且在扫描 → 「扫描中...」；否则 → 「自动选择 Java」
    var javaPickerLabel: String {
        if let path = settings.selectedJavaPath {
            let list = settings.availableJavaList
            if let info = list.first(where: { $0.path == path }) {
                return "Java \(info.majorVersion)"
            }
            return "Java 自定义"
        }
        if settings.isJavaScanning {
            return "扫描中..."
        }
        return "自动选择 Java"
    }

    // MARK: - 扫描编排

    /// 扫描前状态重置（收口前 startScanning 开头的四个写，逐字一致）
    func resetScanState() {
        isLoading = true
        showCard = false
        hasVersions = false
        scanTimedOut = false
    }

    /// 启动根目录扫描：已保存根目录优先、全盘兜底（取数规则在 GameScanService）。
    ///
    /// 返回扫描任务供视图等待结果：等待与「动画事务先后」属于视图时序，故留在视图编排；
    /// 本方法只承担取数入口与初始状态读取（与收口前 detached 任务内的读取方式一致）。
    func beginScan() -> Task<(root: String, versions: [String])?, Never> {
        Task.detached(priority: .userInitiated) { () -> (root: String, versions: [String])? in
            let savedRoot = await MainActor.run { LauncherSettings.shared.selectedGameRoot }
            return await GameScanService.resolveGameRoot(savedRoot: savedRoot)
        }
    }

    /// 超时判定：仅在「仍在检索且尚未超时」时成立；成立时置超时标记并返回 true。
    /// 返回 true 时，视图在既有 0.8 秒动画事务内调用 `applyScanTimeoutPresentation()`。
    func shouldApplyScanTimeout() -> Bool {
        guard isLoading, !scanTimedOut else { return false }
        scanTimedOut = true
        return true
    }

    /// 超时退化后的展示状态（视图在既有 0.8 秒动画事务内调用）：显示卡片、标记无版本、结束检索
    func applyScanTimeoutPresentation() {
        showCard = true
        hasVersions = false
        isLoading = false
    }

    /// 扫描结果决议（业务规则，顺序逐字沿用收口前）：
    /// 有结果 → 版本清单落库、根目录变化时切换、当前版本缺失或不在清单内时选中首个并投递
    /// 「GameVersionSelected」通知；无结果 → 仅标记无版本（不改动其它状态）。
    func applyScanResult(_ result: (root: String, versions: [String])?) {
        if let (root, versionList) = result, !versionList.isEmpty {
            versions = versionList
            if settings.selectedGameRoot.isEmpty || settings.selectedGameRoot != root {
                settings.selectedGameRoot = root
            }
            if settings.selectedMinecraftVersion.isEmpty || !versionList.contains(settings.selectedMinecraftVersion) {
                settings.selectedMinecraftVersion = versions.first ?? ""
                // 通知在渲染事务外投递（收口前同样包在 DispatchQueue.main.async 内）
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("GameVersionSelected"), object: nil)
                }
            }
            hasVersions = true
        } else {
            hasVersions = false
        }
    }

    /// 卡片出现（视图在既有 0.8 秒动画事务内调用）
    func presentScanCard() {
        showCard = true
    }

    /// 检索结束（视图在既有 0.4 秒动画事务内调用）
    func finishScanLoading() {
        isLoading = false
    }

    // MARK: - 全盘查找游戏

    /// 全盘查找：无论是否命中都先结束检索并显示卡片，再投递「找到 N 个游戏」提示；
    /// 命中首个有效游戏时落库根目录与选中版本（无命中则除提示外不改动任何状态）。
    func fullDiskScan() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = await GameScanService.fullDiskScanGames()
            await MainActor.run {
                self.isLoading = false
                self.showCard = true
                self.launchPanel.presentMessage("已找到 \(result.count) 个游戏")
                if let first = result.first {
                    self.versions = first.versions
                    self.settings.selectedGameRoot = first.root
                    self.settings.selectedMinecraftVersion = first.versions.first ?? ""
                    self.hasVersions = true
                }
            }
        }
    }

    // MARK: - 手动选择目录

    /// 校验用户选定的游戏根目录并落库（校验决策与错误文案在本类型）：
    /// 1. 不含 versions 子目录 → 提示后终止，不改动任何状态；
    /// 2. versions 下没有任何版本 → 提示后终止，不改动任何状态；
    /// 3. 通过 → 写入版本列表、根目录与选中版本，并标记有版本。
    /// 视图只负责弹出 NSOpenPanel 并把选中项的 `path` 交给本方法。
    func applyChosenGameRoot(path chosenPath: String) {
        let versionsPath = chosenPath + "/versions"
        guard FileManager.default.fileExists(atPath: versionsPath) else {
            launchPanel.presentError("所选文件夹不包含 versions 子目录")
            return
        }
        let versionList = MinecraftVersionManager.getVersions(from: chosenPath)
        guard !versionList.isEmpty else {
            launchPanel.presentError("所选文件夹的 versions 目录下没有找到任何版本")
            return
        }
        versions = versionList
        settings.selectedGameRoot = chosenPath
        settings.selectedMinecraftVersion = versions.first ?? ""
        hasVersions = true
    }
}
