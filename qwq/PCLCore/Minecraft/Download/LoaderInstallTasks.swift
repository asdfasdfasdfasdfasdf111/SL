//
//  LoaderInstallTasks.swift
//  PCL.Mac
//
//  加载器安装任务（从 InstallTask.swift 逐字搬移，逻辑与文案未变）：
//  - FabricInstallTask：Fabric 安装
//  - LoaderInstallTask：Forge / NeoForge 共用实现（差异仅 installer 工厂、stage、显示名）
//  - ForgeInstallTask / NeoforgeInstallTask：具体工厂绑定
//

import Foundation
import Combine

// MARK: - Fabric 安装任务定义
public class FabricInstallTask: InstallTask {
    @Published private var state: InstallState
    private let loaderVersion: String
    /// 安装失败原因（成功为 nil）；失败抛错让整条安装链终止并报错
    public private(set) var failureReason: String?
    
    init(loaderVersion: String) {
        self.state = .waiting
        self.loaderVersion = loaderVersion
    }
    
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
    
    public override func getInstallStates() -> [InstallStage : InstallState] { [.installFabric : state] }
    
    public override func getTitle() -> String {
        "Fabric \(loaderVersion) 安装"
    }
}

/// Forge / NeoForge 安装任务共用实现（差异仅 installer 工厂、stage、显示名）
public class LoaderInstallTask: InstallTask {
    @Published private var state: InstallState
    private let loaderVersion: String
    private let loaderStage: InstallStage
    private let displayName: String
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

    public override func getInstallStates() -> [InstallStage : InstallState] { [loaderStage : state] }
    public override func getTitle() -> String { "\(displayName) \(loaderVersion) 安装" }
}

public final class ForgeInstallTask: LoaderInstallTask {
    init(forgeVersion: String) {
        super.init(loaderVersion: forgeVersion, stage: .installForge, displayName: "Forge") { dir, url, manifest, cb in
            ForgeInstaller(dir, url, manifest) { cb($0) }
        }
    }
}

public final class NeoforgeInstallTask: LoaderInstallTask {
    init(neoforgeVersion: String) {
        super.init(loaderVersion: neoforgeVersion, stage: .installNeoforge, displayName: "NeoForge") { dir, url, manifest, cb in
            NeoforgeInstaller(dir, url, manifest) { cb($0) }
        }
    }
}
