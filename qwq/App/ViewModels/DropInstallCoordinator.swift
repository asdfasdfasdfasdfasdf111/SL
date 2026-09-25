//
//  DropInstallCoordinator.swift
//  模块化收口：把 ContentView 里「拖入文件 → 判定走模组还是整合包安装 → 匹配实例/挑目录
//  → 执行安装 → 提示结果」这一串业务决策搬到此文件。
//  View 只保留两件事：把拖拽事件转发进来、按协调器给出的状态渲染弹窗。
//  本类型不持有 SwiftUI 视图状态，可脱离界面单独测试
//  （两个前置决策依赖 `detectVersion` / `findInstances` 可注入，见下方 init 的说明）。
//

import Combine
import Foundation

/// 拖拽安装协调器：文件分流、实例匹配、安装执行与结果提示的唯一决策点。
///
/// 状态约定：弹窗开关与弹窗数据由本对象持有（`@Published`），修改一律发生在主线程
/// （拖拽回调经 `DragDropHandler` 回主队列，安装回调来自弹窗主线程动作）。
///
/// ⚠️ `@MainActor` 是**显式**写上的，不是冗余标注。工程开了
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所以真实构建里它本来就被推断为主 actor 隔离；
/// 显式标注只是把这件事实说出来 —— 好处是「从非主 actor 上下文调用」会变成**编译错误**
/// （未显式标注的推断隔离调用点是**静默**的，见 `MEMORY.md` 硬规则 3）。
/// 它同时是下方注入点能成立的前提：闭包参数标 `@MainActor` 后，只有显式隔离的调用方
/// 才被允许同步调用它们（否则「默认隔离」口径下会报 `#ActorIsolatedCall`）。
@MainActor
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
    private let settings = LauncherSettings.shared
    /// 结果提示统一走启动界面状态的投递入口，不直接操作设置字段
    private let launchPanel = LaunchPanelState.shared

    // MARK: - 可注入的前置决策依赖

    /// 模组 jar → 版本需求区间（生产实现 = `ModVersionDetector`）
    private let detectVersion: @MainActor (URL) -> ModVersionDetector.ModVersionInfo?
    /// 版本需求区间 + 用户选定根目录 → 匹配实例（生产实现 = `ModDragInstaller`）
    private let findInstances: @MainActor (_ versionRange: String, _ savedRoot: String) -> [GameInstance]

    /// 两个前置决策依赖可注入，**默认值即生产接线**，因此 `DropInstallCoordinator()` 的
    /// 调用点（`ContentView` 的 `@StateObject`）该行的字节与行为都不变。
    ///
    /// 为什么必须能替换 `findInstances`：它除「用户选定根目录」外还会**全盘扫描本机游戏目录**
    /// （`MinecraftVersionManager.findGameRootDirectories`，含 3 次 `find` 子进程），
    /// 测试无法让它只返回一个受控的临时实例 —— 于是「拖入 jar → 确认安装 → 文件落盘」
    /// 这条成功路径此前完全没有用例。注入替身后即可用临时根目录驱动到落盘断言。
    ///
    /// 为什么**不**替换 `ModDragInstaller.install`：它把内容写到
    /// `instance.rootPath/versions/<版本>/mods`，实例指向临时目录时本身就完全受控，
    /// 保留真实实现才能让「文件真的写进了游戏会加载的那个目录」被真正验证。
    ///
    /// ⚠️ 闭包类型上的 `@MainActor` 是**必需**的，不是装饰：`ModVersionDetector` /
    /// `ModDragInstaller` 在 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下都是主 actor 隔离的，
    /// 闭包若被推断成非隔离，`init` 的默认实现里就会跨 actor 调用（实测：口径二报错）。
    /// ⚠️ `@MainActor` **不改变逃逸性**，故 `@escaping` 必须另写（这是上一轮踩过的坑：
    /// 快速类型检查对「逃逸闭包捕获非 `@escaping` 参数」完全静默，只有真实编译会报）。
    /// ⚠️ 反过来，标了 `@MainActor` 后调用方必须是显式主 actor 隔离的（实测：未给类加
    /// `@MainActor` 时，口径一报 `#ActorIsolatedCall`），两条要求合起来才得出上面那个
    /// 显式 `@MainActor` 的类标注。
    init(detectVersion: @escaping @MainActor (URL) -> ModVersionDetector.ModVersionInfo? = { ModVersionDetector().detectVersion(from: $0) },
         findInstances: @escaping @MainActor (_ versionRange: String, _ savedRoot: String) -> [GameInstance] = { ModDragInstaller.findInstances(for: $0, savedRoot: $1) }) {
        self.detectVersion = detectVersion
        self.findInstances = findInstances
    }

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

        guard let versionInfo = detectVersion(url) else {
            launchPanel.presentError("无法检测模组「\(modName)」的 Minecraft 版本")
            return
        }

        let instances = findInstances(versionInfo.versionRange, settings.selectedGameRoot)
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
            let result = ModDragInstaller.install(modURL: modURL, to: instances)
            let successCount = result.successCount
            if result.failures.isEmpty {
                launchPanel.presentMessage("模组已安装到 \(successCount) 个实例")
            } else if successCount == 0 {
                // 全部失败：此前只回传成功计数（0），用户既看不到失败也看不到原因
                let detail = result.failures.joined(separator: "\n")
                // 第一段（结论 + 补救路径）会被常显，其余（失败原因清单）折叠在「查看详情」里，
                // 见 NoticeOverlay.NoticeCard.splitMessage。补救路径只写真实可走的一步：
                // 工程里没有「下载源切换」界面，不写指向不存在功能的文案。
                NoticeCenter.shared.post(
                    Notice(level: .error,
                           title: "模组安装失败",
                           message: "未能安装到任何实例（共 \(result.failures.count) 个）。重试方法：关闭正在运行的游戏后，把同一个文件重新拖入窗口即可。\n失败原因：\n\(detail)")
                )
            } else {
                // 部分失败：告知成功数与失败原因，避免把失败伪装成“已安装 N 个”
                let detail = result.failures.joined(separator: "\n")
                NoticeCenter.shared.post(
                    Notice(level: .warning,
                           title: "部分实例安装失败",
                           message: "已安装到 \(successCount) 个实例，\(result.failures.count) 个失败。可在关闭对应实例的游戏后，把同一个文件重新拖入窗口重试。\n失败原因：\n\(detail)")
                )
            }
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
