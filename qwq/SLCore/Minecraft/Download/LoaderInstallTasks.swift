//
//  LoaderInstallTasks.swift
//  SL启动器
//
//  加载器安装任务（从 InstallTask.swift 逐字搬移，逻辑与文案未变）：
//  - FabricInstallTask：Fabric 安装
//  - LoaderInstallTask：Forge / NeoForge 共用实现（差异仅 installer 工厂、stage、显示名）
//  - ForgeInstallTask / NeoforgeInstallTask：具体工厂绑定
//
//  ── 这三个类在安装链里的位置 ────────────────────────────────
//  它们都是 `InstallTask` 的子类，由 `MinecraftInstallTask` 按顺序串起来执行；
//  每个任务只需回答两个问题：「我对应哪个阶段/显示名」（`getInstallStates` /
//  `getTitle`，给下载详情页渲染用）与「怎么装」（`install`）。
//
//  ── 一条必须保持的约定：**失败必须向上抛** ───────────────────
//  两个 `install` 的 catch 分支都是「弹错误窗 → 打日志 → 置 state = .failed →
//  设 failureReason → **throw error**」。最后那步不能省：
//  旧实现把错误吞掉后仍然走到 `state = .finished`，于是加载器装失败、后续步骤照跑，
//  最终弹出「下载完成」—— 用户以为装好了，进游戏才发现加载器不存在。
//  抛出去才能让整条安装链在 `MinecraftInstallTask` 那层中断并报错。
//
//  ── Fabric 与 Forge/NeoForge 的一处行为差异 ──────────────────
//  `FabricInstallTask` 装完后会**重新解析清单**写回 `task.manifest`
//  （因为 Fabric 的安装是「改 json」，装完必须让内存里的清单跟上）；
//  而 `LoaderInstallTask` 不刷新 `task.manifest` —— 它拿 `task.manifest` 当**输入**
//  （Forge installer 需要原始清单来生成新的），输出由 installer 自己落到磁盘。
//

import Foundation
import Combine

// MARK: - Fabric 安装任务定义
/// Fabric 安装任务。
public class FabricInstallTask: InstallTask {
    /// 本任务的进度状态。`@Published` + 私有 setter：只有 `install` 能改，界面靠订阅刷新。
    @Published private var state: InstallState
    /// 要安装的 Fabric loader 版本号。
    private let loaderVersion: String
    /// 安装失败原因（成功为 nil）；失败抛错让整条安装链终止并报错
    public private(set) var failureReason: String?
    
    init(loaderVersion: String) {
        self.state = .waiting
        self.loaderVersion = loaderVersion
    }
    
    /// 执行 Fabric 安装。**失败会向上抛**（见文件头约定）。
    ///
    /// 步骤：置 `.inprogress` → 调 `FabricInstaller.installFabric` → 重新解析清单。
    ///
    /// 清单路径是 `task.versionURL/<task.name>.json` —— 与 `MinecraftDirectory`
    /// 「版本目录名即版本名」的约定一致。
    ///
    /// 两处细节：
    /// - 状态改写都包在 `MainActor.run` 里（本方法是 async，可能不在主线程）；
    /// - 错误弹窗的文案里带了「设置 > 其它 > 打开日志」的指引 —— 这是给用户的自救路径，
    ///   属于产品文案，改动前想清楚。
    public func install(_ task: MinecraftInstallTask) async throws {
        await MainActor.run {
            state = .inprogress
        }
        do {
            let manifestURL = task.versionURL.appendingPathComponent("\(task.name).json")
            try await FabricInstaller.installFabric(version: task.minecraftVersion, minecraftDirectory: task.minecraftDirectory, runningDirectory: task.versionURL, self.loaderVersion)
            task.manifest = try ClientManifest.parse(url: manifestURL, minecraftDirectory: task.minecraftDirectory)
        } catch {
            await PopupManager.shared.show(.init(.error, "无法安装 Fabric", "\(error.localizedDescription)\n若要反馈此问题，你可以进入设置 > 其它 > 打开日志，将选中的文件发给别人。", [.ok]))
            err("无法安装 Fabric: \(error.localizedDescription)")
            await MainActor.run {
                state = .failed
                failureReason = error.localizedDescription
            }
            // 失败向上抛 → Minecraft 安装链中断 → 整体终止并报错（旧实现吞掉错误后
            // state = .finished 且继续走后续步骤，最终弹「下载完成」——加载器失败被误报成功）
            throw error
        }
        await MainActor.run {
            state = .finished
        }
    }
    
    /// 本任务在下载详情页里只占一个阶段：`.installFabric`。
    public override func getInstallStates() -> [InstallStage : InstallState] { [.installFabric : state] }
    
    /// 下载详情页里显示的任务名，形如「Fabric 0.15.11 安装」。
    public override func getTitle() -> String {
        "Fabric \(loaderVersion) 安装"
    }
}

/// Forge / NeoForge 安装任务共用实现（差异仅 installer 工厂、stage、显示名）
///
/// 为什么合成一个类：Forge 与 NeoForge 的安装流程、错误处理、状态机**逐字相同**，
/// 唯一差别是「造哪个 installer 对象」和「叫什么、属于哪个 stage」。
/// 所以把差异收敛成一个**闭包工厂** `makeInstaller`，两个子类只负责在初始化时绑定它
/// （见文件末尾的 `ForgeInstallTask` / `NeoforgeInstallTask`）。
/// —— 新增第三个同族加载器时，照抄那两行即可，不要复制整个 `install`。
public class LoaderInstallTask: InstallTask {
    /// 同 `FabricInstallTask.state`。
    @Published private var state: InstallState
    /// 加载器版本号（Forge 或 NeoForge，取决于子类）。
    private let loaderVersion: String
    /// 本任务对应的阶段（`.installForge` / `.installNeoforge`）。
    /// 由子类注入 —— 它是决定「下载详情页里这行排在哪儿」的依据
    /// （页面按 `InstallStage.rawValue` 排序，见 `InstallProgress.swift` 文件头）。
    private let loaderStage: InstallStage
    /// 显示名（"Forge" / "NeoForge"），用于 `getTitle` 与错误弹窗文案。
    private let displayName: String
    /// installer 工厂：把「构造哪一个 installer」这件事从流程里抽出来。
    /// 参数依次是实例目录、版本目录、原始清单、进度回调。
    private let makeInstaller: (MinecraftDirectory, URL, ClientManifest, @escaping (Double) -> Void) -> ForgeInstaller
    /// 安装失败原因（成功为 nil）；失败抛错让整条安装链终止并报错
    public private(set) var failureReason: String?

    init(loaderVersion: String, stage: InstallStage, displayName: String, makeInstaller: @escaping (MinecraftDirectory, URL, ClientManifest, @escaping (Double) -> Void) -> ForgeInstaller) {
        self.state = .waiting
        self.loaderVersion = loaderVersion
        self.loaderStage = stage
        self.displayName = displayName
        self.makeInstaller = makeInstaller
    }

    /// 执行安装。**失败会向上抛**（同 Fabric，见文件头约定）。
    ///
    /// 进度回调直接写 `currentStagePercentage`（父类 `InstallTask` 的属性），
    /// 下载详情页读的就是它 —— 所以这里不需要额外状态。
    ///
    /// `try task.manifest.unwrap()`：`task.manifest` 是可选的，
    /// **如果前序步骤（下载原版清单）没成功，这里会抛错**，
    /// 也就是加载器不会在缺清单的情况下硬装 —— 这是有意的前置依赖检查。
    public func install(_ task: MinecraftInstallTask) async throws {
        await MainActor.run {
            state = .inprogress
        }
        do {
            let installer = makeInstaller(task.minecraftDirectory, task.versionURL, try task.manifest.unwrap()) { progress in
                self.currentStagePercentage = progress
            }
            try await installer.install(minecraftVersion: task.minecraftVersion, forgeVersion: loaderVersion)
            log("\(displayName) 安装完成")
        } catch {
            await PopupManager.shared.show(.init(.error, "无法安装 \(displayName)", "\(error.localizedDescription)\n若要反馈此问题，你可以进入设置 > 其它 > 打开日志，将选中的文件发给别人。", [.ok]))
            err("无法安装 \(displayName): \(error.localizedDescription)")
            await MainActor.run {
                state = .failed
                failureReason = error.localizedDescription
            }
            throw error
        }
        await MainActor.run {
            state = .finished
        }
    }

    /// 阶段由子类注入（`.installForge` / `.installNeoforge`）。
    public override func getInstallStates() -> [InstallStage : InstallState] { [loaderStage : state] }
    /// 显示名由子类注入，形如「Forge 47.2.0 安装」。
    public override func getTitle() -> String { "\(displayName) \(loaderVersion) 安装" }
}

/// Forge 安装任务：只做一件事 —— 绑定 Forge 的 installer 工厂与阶段/显示名。
public final class ForgeInstallTask: LoaderInstallTask {
    init(forgeVersion: String) {
        super.init(loaderVersion: forgeVersion, stage: .installForge, displayName: "Forge") { dir, url, manifest, cb in
            ForgeInstaller(dir, url, manifest) { cb($0) }
        }
    }
}

/// NeoForge 安装任务：与 `ForgeInstallTask` 同构，只是换成 `NeoforgeInstaller`。
public final class NeoforgeInstallTask: LoaderInstallTask {
    init(neoforgeVersion: String) {
        super.init(loaderVersion: neoforgeVersion, stage: .installNeoforge, displayName: "NeoForge") { dir, url, manifest, cb in
            NeoforgeInstaller(dir, url, manifest) { cb($0) }
        }
    }
}
