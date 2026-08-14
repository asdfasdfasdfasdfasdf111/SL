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

public class MinecraftInstaller {
    private init() {}
    
    // MARK: 下载客户端清单
    private static func downloadClientManifest(_ task: MinecraftInstallTask) async throws {
        task.updateStage(.clientJson)
        // 主源 + 镜像源双 URL：官方源失败自动切镜像（旧实现单 URL，失败即无源可用报错）
        let urls = DownloadSourceManager.shared.downloadURLs { $0.getClientManifestURL(task.minecraftVersion) }
        guard !urls.isEmpty else {
            throw MyLocalizedError(reason: "无法获取 \(task.minecraftVersion.displayName) 的 JSON 下载 URL。")
        }
        let destination = task.versionURL.appending(path: "\(task.name).json")
        
        try await SingleFileDownloader.download(task: task, urls: urls, destination: destination, replaceMethod: .replace)
        
        if let manifest: ClientManifest = try .parse(url: destination, minecraftDirectory: nil) {
            task.manifest = manifest
        } else {
            let content = try String(data: FileHandle(forReadingFrom: destination).readToEnd().unwrap(), encoding: .utf8).unwrap()
            err("无法解析客户端清单: \(content)")
            throw MyLocalizedError(reason: "无法解析客户端清单：\(content)")
        }
    }
    
    // MARK: 下载客户端本体
    private static func downloadClientJar(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientJar) }
        else { task.updateStage(.clientJar) }
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单为空，无法下载客户端本体。")
        }
        // 主源 + 镜像源双 URL（原版 jar 下载失败自动切换下载源——用户反馈的核心场景）
        let urls = DownloadSourceManager.shared.downloadURLs { $0.getClientJARURL(task.minecraftVersion, manifest) }
        guard !urls.isEmpty else {
            throw MyLocalizedError(reason: "无法获取 \(task.minecraftVersion.displayName) 的客户端下载 URL。")
        }
        
        try await SingleFileDownloader.download(
            task: task,
            urls: urls,
            destination: task.versionURL.appending(path: "\(task.name).jar"),
            expectedSHA1: manifest.clientDownload?.sha1,
            stage: parallel ? .clientJar : nil
        )
        if parallel { await task.finishParallelStage(.clientJar) }
    }
    
    // MARK: 下载资源索引
    private static func downloadAssetIndex(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientIndex) }
        guard let manifest = task.manifest else {
            err("任务客户端清单为空值，停止下载资源索引")
            task.assetIndex = .init(objects: [])
            return
        }
        
        task.updateStage(.clientIndex)
        
        // 主源 + 镜像源双 URL
        let urls = DownloadSourceManager.shared.downloadURLs { $0.getAssetIndexURL(task.minecraftVersion, manifest) }
        guard !urls.isEmpty else {
            throw MyLocalizedError(reason: "无法获取 \(task.minecraftVersion.displayName) 的 assetIndex 下载 URL。")
        }
        // 客户端清单可能缺少 assetIndex（旧版本如 1.5.2 及以下无独立资源索引）：
        // 此时不下载索引，置空 objects，后续散列资源阶段随之跳过，避免强解包崩溃。
        guard let assetIndex = manifest.assetIndex else {
            err("客户端清单缺少资源索引字段（该版本可能无独立资产索引），跳过资源索引阶段")
            task.assetIndex = .init(objects: [])
            return
        }
        let destination: URL = task.minecraftDirectory.assetsURL.appending(component: "indexes").appending(component: "\(assetIndex.id).json")
        try await SingleFileDownloader.download(task: task, urls: urls, destination: destination, expectedSHA1: assetIndex.sha1, stage: parallel ? .clientIndex : nil)
        do {
            let data = try Data(contentsOf: destination)
            task.assetIndex = try .parse(data)
        } catch {
            err("在解析 JSON 时发生错误: \(error.localizedDescription)")
        }
        if parallel { await task.finishParallelStage(.clientIndex) }
    }
    
    // MARK: 下载散列资源文件
    private static func downloadHashResourcesFiles(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientResources) }
        else { task.updateStage(.clientResources) }
        let objects = task.assetIndex!.objects
        
        // asset 以 hash 命名，直接用 hash 作为校验：已存在且匹配 → 引擎内跳过，损坏 → 重下
        var items: [DownloadItem] = []
        
        for object in objects {
            let dest = object.appendTo(task.minecraftDirectory.assetsURL.appending(path: "objects"))
            // 多源构造（主源 + 互补备用源）：官方失败自动切镜像，镜像失败自动切官方。
            // 旧实现硬编码官方 CDN（resources.download.minecraft.net），官方不可用时全部失败。
            // getAssetURL 仅在 hash 不足 2 字符时返回 nil，asset hash 恒为 40 位十六进制，! 安全
            items.append(.init(
                DownloadSourceManager.shared.getDownloadSource(),
                { $0.getAssetURL(hash: object.hash)! },
                destination: dest,
                sha1: object.hash
            ))
        }
        
        try await MultiFileDownloader(task: task, items: items, stage: parallel ? .clientResources : nil).start()
        if parallel { await task.finishParallelStage(.clientResources) }
    }
    
    // MARK: 下载依赖项
    private static func downloadLibraries(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.clientLibraries) }
        else { task.updateStage(.clientLibraries) }
        
        var libraryNames: [String] = []
        var items: [DownloadItem] = []
        
        for library in try task.manifest.unwrap().getNeededLibraries() {
            if let artifact = library.artifact {
                let dest = task.minecraftDirectory.librariesURL.appending(path: artifact.path)
                if CacheStorage.default.copy(name: library.name, to: dest) {
                    continue
                }
                
                // 缺失预分析（PCL2 McLibFix）：本地已存在且 sha1 匹配 → 不进下载列表，进度按缺失数计算
                if FileChecker(hash: artifact.sha1).check(dest) == nil {
                    continue
                }
                
                libraryNames.append(library.name)
                items.append(.init(DownloadSourceManager.shared.getDownloadSource(), { $0.getLibraryURL(library)! }, destination: dest, sha1: artifact.sha1))
            }
        }
        
        try await MultiFileDownloader(task: task, items: items, stage: parallel ? .clientLibraries : nil).start()
        
        for library in task.manifest!.getNeededLibraries() {
            if libraryNames.contains(library.name) {
                CacheStorage.default.add(name: library.name, path: task.minecraftDirectory.librariesURL.appending(path: library.artifact!.path))
            }
        }
        if parallel { await task.finishParallelStage(.clientLibraries) }
    }
    
    // MARK: 下载本地库
    private static func downloadNatives(_ task: MinecraftInstallTask, parallel: Bool = false) async throws {
        if parallel { await task.beginParallelStage(.natives) }
        else { task.updateStage(.natives) }
        
        var libraryNames: [String] = []
        var items: [DownloadItem] = []
        
        for (library, artifact) in try task.manifest.unwrap().getNeededNatives() {
            let dest = task.minecraftDirectory.librariesURL.appending(path: artifact.path)
            if CacheStorage.default.copy(name: library.name, to: dest) {
                continue
            }
            
            // 缺失预分析：已存在且 sha1 匹配 → 跳过
            if FileChecker(hash: artifact.sha1).check(dest) == nil {
                continue
            }
            
            libraryNames.append(library.name)
            items.append(.init(DownloadSourceManager.shared.getDownloadSource(), { $0.getLibraryURL(library)! }, destination: dest, sha1: artifact.sha1))
        }
        
        try? FileManager.default.createDirectory(at: task.versionURL.appending(path: "natives"), withIntermediateDirectories: true)
        try await MultiFileDownloader(task: task, items: items, stage: parallel ? .natives : nil).start()
        
        for (library, artifact) in task.manifest!.getNeededNatives() {
            if libraryNames.contains(library.name) {
                CacheStorage.default.add(name: library.name, path: task.minecraftDirectory.librariesURL.appending(path: artifact.path))
            }
        }
        if parallel { await task.finishParallelStage(.natives) }
    }
    
    // MARK: 解压本地库
    private static func unzipNatives(_ task: MinecraftInstallTask) throws {
        let nativesURL: URL = task.versionURL.appending(path: "natives")
        for (_, native) in task.manifest!.getNeededNatives() {
            let jarURL: URL = task.minecraftDirectory.librariesURL.appending(path: native.path)
            Util.unzip(archiveURL: jarURL, destination: nativesURL, replace: true)
            do {
                try processLibs(task, nativesURL)
            } catch {
                err("处理 natives 失败")
                throw error
            }
        }
    }
    
    // MARK: 处理解压结果
    private static func processLibs(_ task: MinecraftInstallTask, _ nativesURL: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: nativesURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "dylib" || fileURL.pathExtension == "jnilib",
                  let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  !resourceValues.isDirectory! else { continue }
            
            // 验证架构
            if fileURL.pathExtension == "dylib" {
                let arch = Architecture.getArchOfFile(fileURL)
                guard arch.isCompatiable(with: task.architecture) else {
                    try? fileManager.removeItem(at: fileURL)
                    log("已清除架构不匹配的可执行文件: \(fileURL.lastPathComponent)")
                    continue
                }
            }
            
            // 拷贝到 natives 根目录
            let destinationURL = nativesURL.appendingPathComponent(fileURL.lastPathComponent)
            if destinationURL == fileURL { continue }
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: fileURL, to: destinationURL)
        }
        
        // 清理非 dylib 文件
        let contents = try fileManager.contentsOfDirectory(at: nativesURL, includingPropertiesForKeys: nil)
        for fileURL in contents {
            if !fileURL.pathExtension.lowercased().hasSuffix("dylib") && !fileURL.pathExtension.lowercased().hasSuffix("jnilib") {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }
    
    // MARK: 收尾
    private static func finalWork(_ task: MinecraftInstallTask) {
        let _1_12_2 = MinecraftVersion(displayName: "1.12.2")
        // 拷贝 log4j2.xml
        let targetURL: URL = task.versionURL.appending(path: "log4j2.xml")
        try? FileManager.default.copyItem(
            at: SharedConstants.shared.applicationResourcesURL.appending(path: task.minecraftVersion >= _1_12_2 ? "log4j2.xml" : "log4j2-1.12-.xml"),
            to: targetURL
        )
        
        // 初始化实例
        let instance = MinecraftInstance.create(.init(rootURL: task.versionURL.parent().parent(), name: ""), task.versionURL, config: MinecraftConfig(version: task.minecraftVersion))
        
        instance?.saveConfig()
        
        // 修改 GLFW
        if let glfw = task.manifest!.getNeededLibraries().find({ $0.name.contains("lwjgl-glfw") }) {
            guard let javaURL = JavaManager.resolveJavaExecutable() else {
                err("未找到可用的 Java 运行时，无法运行 glfw-patcher")
                return
            }
            let process = Process()
            process.executableURL = javaURL
            process.environment = ProcessInfo.processInfo.environment
            process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
            process.arguments = ["-jar", SharedConstants.shared.applicationResourcesURL.appending(path: "glfw-patcher.jar").path, task.minecraftDirectory.librariesURL.appending(path: glfw.artifact!.path).path]
            do {
                try process.run()
                process.waitUntilExit()
                log("已修改 lwjgl-glfw")
            } catch {
                err("无法修改 lwjgl-glfw: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: 修改客户端清单中的 id
    private static func modifyId(_ task: MinecraftInstallTask) {
        do {
            let manifestURL = task.versionURL.appending(path: "\(task.versionURL.lastPathComponent).json")
            guard FileManager.default.fileExists(atPath: manifestURL.path),
                  let data = try FileHandle(forReadingFrom: manifestURL).readToEnd(),
                  var dict = try JSON(data: data).dictionaryObject else {
                return
            }
            
            dict["id"] = task.versionURL.lastPathComponent
            
            try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted).write(to: manifestURL)
            log("已修改客户端清单中的 id")
        } catch {
            err("无法修改 id: \(error.localizedDescription)")
        }
    }
    
    // MARK: 获取进度
    public static func updateProgress(_ task: MinecraftInstallTask) {
        DispatchQueue.main.async {
            let components = 3 + task.assetIndex!.objects.count
                + task.manifest!.getNeededLibraries().count + task.manifest!.getNeededNatives().count
            task.totalFiles = components
            log("总文件数: \(task.totalFiles)")
            // 前置阶段均已下载：clientJson 完成、clientIndex 完成、第二波开始前 jar 完成 = 3
            task.remainingFiles = components - 3
        }
    }
    
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
        let arch: Architecture
        if Architecture.system == .x64 { arch = .x64 }
        else { arch = instance.isUsingRosetta ? .x64 : .arm64 }
        let task = MinecraftInstallTask(
            minecraftVersion: instance.version!,
            minecraftDirectory: instance.minecraftDirectory,
            name: instance.name,
            architecture: arch
        ) { task in
            task.manifest = instance.manifest
            try await downloadAssetIndex(task)
            try await downloadClientJar(task)
            try await downloadHashResourcesFiles(task)
            try await downloadLibraries(task)
            try await downloadNatives(task)
            try unzipNatives(task)
            finalWork(task)
            task.complete()
            callback?()
        }
        return task
    }
    
    // MARK: 确保 natives 已解压（PCL2 McLaunchNatives 语义：启动前缺失则重解压）
    public static func ensureNatives(_ instance: MinecraftInstance) throws {
        let nativesURL = instance.runningDirectory.appending(path: "natives")
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
