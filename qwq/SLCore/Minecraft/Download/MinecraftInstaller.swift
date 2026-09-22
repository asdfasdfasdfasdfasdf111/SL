//
//  MinecraftInstallerNew.swift
//  SL启动器
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
                // 失败必须让任务以失败收尾：原实现只 err() 记录后照常 task.complete()，
                // 任务对外表现为「安装成功」（详情页消失、无失败提示），实例缺少资源仍继续启动。
                // 抛出即走既有错误通道——MinecraftInstallTask.start() 的 catch：弹窗 +
                // currentState = .failed + failureReason（调用方如 GameVersionDownloadStarter.swift:81
                // 正是靠 failureReason 区分成功/失败），不需要新增错误类型。
                // 抛出前补发一次 callback：启动路径（MinecraftInstance.swift:161 的
                // withCheckedContinuation）用它恢复 continuation，而上述失败分支只回调
                // task.callback（本任务从未注册 onComplete）——不补发则「资源完整性检查」永久挂起。
                err("资源补全失败: \(error.localizedDescription)")
                callback?()
                throw error
            }
            task.complete()
            callback?()
        }
        // 资源补全作用于**已存在**的实例：失败时不得删除版本目录。
        // （全新安装路径 removesVersionOnFailure 保持 true，失败即清理半成品目录。）
        task.removesVersionOnFailure = false
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
        // 已有**与目标架构匹配**的 dylib/jnilib 则跳过。
        // 原判据只看「目录里有没有 .dylib」，架构错配时会被误判为「已就绪」：
        // 若目录里的 dylib 全是 x64（历史上曾被 x64 条目解压出来），在 arm64 机器上这里会直接跳过，
        // 于是最终 `-Djava.library.path` 指向的仍是 x64 dylib → 进游戏后 UnsatisfiedLinkError。
        // 现额外校验架构：只在存在「架构兼容」的可执行文件时才跳过；全部不匹配则重新解压
        // （重解压会按目标架构选择正确的 natives jar，见 unzipNatives 的 resolvedNativeJarPath）。
        // 目标架构取 `Architecture.system`，与下方创建任务时的默认架构（`.system`）一致。
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nativesURL.path) {
            let hasCompatibleExecutable = contents
                .filter { $0.hasSuffix(".dylib") || $0.hasSuffix(".jnilib") }
                .contains { name in
                    // .jnilib（LWJGL2 时代）不参与 Mach-O 架构判定：口径与 dylib 不同，
                    // 一律视为可用，避免对老版本每次启动都反复重解压
                    guard name.hasSuffix(".dylib") else { return true }
                    let arch = Architecture.getArchOfFile(nativesURL.appendingPathComponent(name))
                    return arch.isCompatiable(with: .system)
                }
            if hasCompatibleExecutable { return }
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
