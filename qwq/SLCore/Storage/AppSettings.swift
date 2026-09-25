//
//  AppSettings.swift
//  应用级设置（**兼容层**）：下载源与版本清单源的选择，以及 Minecraft 目录兜底。
//
//  历史：本文件原属 `SLCore/Stubs.swift`。字段的引用情况已在下文逐个标明 ——
//  保留它的原因是**三个字段都有读取方**，而不是「看起来像桩就删掉」。
//
//  职责：`DownloadSourceOption` 枚举与持有它的 `AppSettings` 单例。
//  边界：**不是设置界面的数据源**。个性化页的偏好由 `Features/Settings/` 下的存储承担；
//        本类型只服务下载链（源选择）与启动链（目录兜底）。
//        读注释时注意 `currentMinecraftDirectory` 恒为默认值这一已核实事实（见下）。
//
//  注释引用约定：一律写「文件 + 符号/场景」，**不写行号**（行号会随任何一次编辑漂移）。
//

import Foundation
import Combine

// MARK: - AppSettings
/// 下载源选项。**有活跃引用**：作为 `AppSettings.fileDownloadSource` / `versionManifestSource` 的类型，
/// 三个 case 的读取点为 `SLCore/Download/DownloadSourceManager.swift`（源选择与测速切换）、
/// `Core/Download/Adapters/DefaultDownloadSourceResolver.swift`（`== .both` 时追加镜像源）、
/// `SLCore/Download/MultiFileDownloader.swift`（决定是否提供备用源）。
public enum DownloadSourceOption: Codable { case official, mirror, both }

/// 应用级设置（兼容层）。
///
/// 字段引用情况：
///  - `currentMinecraftDirectory`：**只读不改**。读取点为 `SLCore/SLLaunchBridge.swift`（未传 gameDir 时的兜底）、
///    `Features/Launch/LaunchCoordinator.swift`、`Features/Skin/OfflineSkinService.swift`、
///    `Features/ModBrowser/ViewModels/LaunchAvatarSkinViewModel.swift`、
///    `Core/Minecraft/Module/MinecraftRepository.swift`；
///    全库（含 `qwqTests`）无写入点，实际恒为 `.default`——详见 `SLCore/STUBS_AUDIT.md` §5.4。
///  - `fileDownloadSource`：`SLCore/Download/DownloadSourceManager.swift`（源选择与测速切换）、
///    `Core/Download/Adapters/DefaultDownloadSourceResolver.swift`（`== .both` 时追加镜像源）、
///    `SLCore/Download/MultiFileDownloader.swift`（备用源开关），
///    并有测试写入 `qwqTests/DownloadAdapterTests.swift`。
///  - `versionManifestSource`：`SLCore/Download/DownloadSourceManager.swift`。
public class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    public var currentMinecraftDirectory: MinecraftDirectory? = .default
    public var fileDownloadSource: DownloadSourceOption = .both
    public var versionManifestSource: DownloadSourceOption = .both
    private init() {}
}
