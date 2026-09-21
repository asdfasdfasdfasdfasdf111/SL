//
//  MinecraftInstallerNew.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/31.
//

/**
 *                             _ooOoo_
 *                            o8888888o
 *                            88" . "88
 *                            (| -_- |)
 *                            O\  =  /O
 *                         ____/`---'\____
 *                       .'  \\|     |//  `.
 *                      /  \\|||  :  |||//  \
 *                     /  _||||| -:- |||||-  \
 *                     |   | \\\  -  /// |   |
 *                     | \_|  ''\---/''  |   |
 *                     \  .-\__  `-`  ___/-. /
 *                   ___`. .'  /--.--\  `. . __
 *                ."" '<  `.___\_<|>_/___.'  >'"".
 *               | | :  `- \`.;`\ _ /`;.`/ - ` : | |
 *               \  \ `-.   \_ __\ /__ _/   .-` /  /
 *          ======`-.____`-.___\_____/___.-`____.-'======
 *                             `=---='
 *          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
*/

import Foundation
import SwiftyJSON

/// Minecraft 原版安装编排。本文件只保留任务构造、阶段编排与进度口径：
/// - createTask / createCompleteTask：完整安装与资源补全两条编排链
/// - updateProgress：总文件数 / 剩余文件数的进度口径
/// - ensureNatives：启动前 natives 缺失时的重解压入口
/// 其余实现按职责拆分在同目录，逻辑、阶段调用顺序与日志文案均与原实现逐字一致（仅物理搬移）：
/// - MinecraftInstallerDownloads.swift    各阶段下载（单文件 / 清单 / 本体 / 资源索引 / 散列资源 / 依赖 / natives）
/// - MinecraftInstallerPostProcess.swift  安装后处理（解压 natives、架构筛选、收尾、清单 id 改写）
///
/// 跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
/// 官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
/// 与 .../extensions/）：`private` 仅对「同一封闭声明及其同文件扩展」可见，且扩展不能声明存储属性，
/// 故拆分后编排链所调用的下载与后处理成员访问级别由 private static 提升为 internal static，
/// 其余成员（downloadSingleFile、processLibs）保持 private static。对外接口零变化。
public class MinecraftInstaller {
    private init() {}
    
    // MARK: 创建任务
    public static func createTask(_ minecraftVersion: MinecraftVersion, _ name: String, _ minecraftDirectory: MinecraftDirectory, _ callback: (() -> Void)? = nil) -> InstallTask {
        let task = MinecraftInstallTask(minecraftVersion: minecraftVersion, minecraftDirectory: minecraftDirectory, name: name) { task in
            try await downloadClientManifest(task)
            try await downloadAssetIndex(task)
            updateProgress(task)

            // PCL2 风格并发下载：各文件组提交给 NetManager 的全局 16 分片调度器。
            // 第一波原版 jar 与散列资源并发；每个文件仍支持分片/断点续传/多源切换，
            // 全局上限统一限流，不会因多阶段并发而无限创建连接。
            task.updateStage(.clientJar) // 结束「资源索引」阶段，之后由 parallelStageStates 独立显示
            async let clientJar: Void = downloadClientJar(task, parallel: true)
            async let resources: Void = downloadHashResourcesFiles(task, parallel: true)

            // Loader 安装依赖原版 jar；只等待 jar，散列资源继续后台下载。
            try await clientJar
            if let fabricTask = DataManager.shared.inprogressInstallTasks?.tasks["fabric"] as? FabricInstallTask {
                try await fabricTask.install(task)
            } else if let forgeTask = DataManager.shared.inprogressInstallTasks?.tasks["forge"] as? ForgeInstallTask {
                try await forgeTask.install(task)
            } else if let neoforgeTask = DataManager.shared.inprogressInstallTasks?.tasks["neoforge"] as? NeoforgeInstallTask {
                try await neoforgeTask.install(task)
            }

            // Loader 会改写 task.manifest 并加入自己的依赖；必须在它完成后再解析依赖列表。
            // 第二波依赖库与 natives 并发，同时第一波的散列资源可能仍在继续。
            modifyId(task)
            async let libraries: Void = downloadLibraries(task, parallel: true)
            async let natives: Void = downloadNatives(task, parallel: true)
            _ = try await (resources, libraries, natives)
            try unzipNatives(task)
            finalWork(task)
            callback?()
        }
        return task
    }
    
    // MARK: 创建补全资源任务
    public static func createCompleteTask(_ instance: MinecraftInstance, _ callback: (() -> Void)? = nil) -> InstallTask {
        guard let version = instance.version else {
            err("实例版本未设置，无法创建补全任务")
            let task = MinecraftInstallTask(minecraftVersion: .init(displayName: "unknown"), minecraftDirectory: instance.minecraftDirectory, name: instance.name) { _ in }
            task.complete()
            callback?()
            return task
        }
        let arch: Architecture
        if Architecture.system == .x64 { arch = .x64 }
        else { arch = instance.isUsingRosetta ? .x64 : .arm64 }
        let task = MinecraftInstallTask(
            minecraftVersion: version,
            minecraftDirectory: instance.minecraftDirectory,
            name: instance.name,
            architecture: arch
        ) { task in
            task.manifest = instance.manifest
            do {
                try await downloadAssetIndex(task)
                try await downloadClientJar(task)
                try await downloadHashResourcesFiles(task)
                try await downloadLibraries(task)
                try await downloadNatives(task)
                try unzipNatives(task)
                finalWork(task)
            } catch {
                err("资源补全失败: \(error.localizedDescription)")
            }
            task.complete()
            callback?()
        }
        return task
    }
    
    // MARK: 获取进度
    public static func updateProgress(_ task: MinecraftInstallTask) {
        guard let assetIndex = task.assetIndex,
              let manifest = task.manifest else {
            log("updateProgress: 任务数据未就绪，跳过进度计算")
            return
        }
        DispatchQueue.main.async {
            let components = 3 + assetIndex.objects.count
                + manifest.getNeededLibraries().count + manifest.getNeededNatives().count
            task.totalFiles = components
            log("总文件数: \(task.totalFiles)")
            // 前置阶段均已下载：clientJson 完成、clientIndex 完成、第二波开始前 jar 完成 = 3
            task.remainingFiles = components - 3
        }
    }
    
    // MARK: 确保 natives 已解压（PCL2 McLaunchNatives 语义：启动前缺失则重解压）
    public static func ensureNatives(_ instance: MinecraftInstance) throws {
        let nativesURL = instance.runningDirectory.appendingPathComponent("natives")
        // 已有可用的 dylib/jnilib 则跳过
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nativesURL.path),
           contents.contains(where: { $0.hasSuffix(".dylib") || $0.hasSuffix(".jnilib") }) {
            return
        }
        guard let manifest = instance.manifest, !manifest.getNeededNatives().isEmpty else { return }
        let task = MinecraftInstallTask(
            minecraftVersion: instance.version ?? .init(displayName: "1.0"),
            minecraftDirectory: instance.minecraftDirectory,
            name: instance.name
        ) { _ in }
        task.manifest = manifest
        try unzipNatives(task)
        log("已重新解压 natives: \(instance.name)")
    }
}
