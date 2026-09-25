//
//  DataManager.swift
//  全局共享状态容器（启动链与下载链共用的几份运行期状态）。
//
//  历史：本文件原属 `SLCore/Stubs.swift`。它的三个字段**都有活跃读写方**（见下），
//  不是桩，因此单独成文。
//
//  职责：持有 `javaVirtualMachines` / `versionManifest` / `inprogressInstallTasks` 三份状态。
//  边界：**只是一个容器** —— 不提供查询、不做派生计算、不负责写盘；写入方各自负责一致性。
//        字段的类型来自同模块的 `SLCore/Java`、`SLCore/Minecraft/Download`。
//
//  注释引用约定：一律写「文件 + 符号/场景」，**不写行号**（行号会随任何一次编辑漂移）。
//

import Foundation
import Combine

// MARK: - DataManager
/// 全局共享状态容器。
///
/// 使用方（节选，均为活跃引用）：
///  - `javaVirtualMachines`：`SLCore/SLLaunchBridge.swift`（启动前读取并等待扫描结果）、
///    `Features/Java/JavaManager.swift`（扫描结果写入）、
///    `SLCore/Minecraft/MinecraftInstanceJava.swift`（Java 探测、回写与筛选）；
///  - `versionManifest`：`SLCore/Minecraft/Download/VersionManifest.swift`、
///    `SLCore/Minecraft/MinecraftVersion.swift`、`SLCore/Download/DownloadSource.swift`；
///  - `inprogressInstallTasks`：`Features/Download/DownloadDetailManager.swift`（写入）、
///    `SLCore/Minecraft/Download/InstallTask.swift`（归属校验后清理）、
///    `SLCore/Minecraft/Download/MinecraftInstaller.swift`（按 key 取加载器子任务）。
public class DataManager: ObservableObject {
    public static let shared = DataManager()
    @Published public var javaVirtualMachines: [JavaVirtualMachine] = []
    @Published public var versionManifest: VersionManifest? = nil
    @Published public var inprogressInstallTasks: InstallTasks? = nil
    private init() {}
}
