//
//  MinecraftInstallerPostProcess.swift
//  PCL.Mac
//
//  Minecraft 原版安装的下载后处理（从 MinecraftInstaller.swift 逐字搬移，逻辑与文案未变）：
//  - unzipNatives / processLibs：解压本地库、按架构筛选可执行文件并清理冗余文件
//  - finalWork：拷贝 log4j2 配置、初始化实例、必要时调用 glfw-patcher
//  - modifyId：改写客户端清单中的 id 为实例目录名
//

import Foundation
import SwiftyJSON

extension MinecraftInstaller {

    // MARK: 解压本地库
    /// 访问级别为 internal：编排链与 ensureNatives（MinecraftInstaller.swift）调用。
    static func unzipNatives(_ task: MinecraftInstallTask) throws {
        let nativesURL: URL = task.versionURL.appendingPathComponent("natives")
        guard let manifest = task.manifest else {
            throw MyLocalizedError(reason: "客户端清单未就绪，无法解压本地库")
        }
        for (_, native) in manifest.getNeededNatives() {
            let jarPath = resolvedNativeJarPath(native, in: task)
            let jarURL: URL = task.minecraftDirectory.librariesURL.appendingPathComponent(jarPath)
            // 解压失败必须可见：`Util.unzip` 原先无返回值、失败仅记日志，调用方无从判断成败，
            // 安装（createTask / createCompleteTask）与启动前修复（ensureNatives）都会在
            // natives 缺失的情况下继续当作成功。现读取其成功标志并走既有错误通道——本方法本就是
            // `throws`，三处调用方均已用 `try`。
            guard Util.unzip(archiveURL: jarURL, destination: nativesURL, replace: true) else {
                throw MyLocalizedError(reason: "解压 natives 失败：\(jarPath)")
            }
            do {
                try processLibs(task, nativesURL)
            } catch {
                err("处理 natives 失败")
                throw error
            }
        }
    }

    /// 解析 natives 条目应解压的 jar 路径，**按目标架构选择**（缺陷：native 库架构错配）。
    ///
    /// 背景：清单通过 `natives: {"osx": "natives-macos"}` 选定的是 **x64** 分类器
    /// （`ClientManifestLibrary.swift` 的 `Library.init(json:)` 只认 `natives["osx"]`），
    /// arm64 修正唯一的来源是 `ArtifactVersionMapper.map(_:arch:.arm64)`。
    /// 而 `pclLaunchInternal` 的执行顺序是「先启动前补全（`LaunchFix.perform` → `ensureNatives`
    /// → 本函数）→ 后 `ArtifactVersionMapper.map`」，即解压时清单条目**尚未**被改成 arm64，
    /// 会去解压 x64 的 `-natives-macos.jar`；紧随其后的 `processLibs` 按 `task.architecture`
    /// 删掉全部架构不匹配的 dylib → natives 目录被清空 → `-Djava.library.path` 指向空目录
    /// （表现为进入游戏后 UnsatisfiedLinkError）。
    ///
    /// 修法（**不调整启动链路顺序**，只让「解压」这一步自身架构正确，从而与顺序无关）：
    /// 目标架构为 arm64、原路径是 macos 分类器、且盘上确实存在同坐标的
    /// `-natives-macos-arm64.jar` 时改用它；其余情况（x64 目标、1.18 及更早只有 x64 natives、
    /// 非 macos 分类器、清单已被映射过）一律回落原路径，行为与改动前完全一致。
    private static func resolvedNativeJarPath(_ native: ClientManifest.DownloadInfo, in task: MinecraftInstallTask) -> String {
        guard task.architecture == .arm64 else { return native.path }
        guard native.path.hasSuffix("-natives-macos.jar") else { return native.path }
        let arm64Path = native.path.replacingOccurrences(of: "-natives-macos.jar", with: "-natives-macos-arm64.jar")
        // 只有盘上真有 arm64 变体时才切换：否则保持原路径（老版本/第三方清单可能没有该分类器）
        guard FileManager.default.fileExists(
            atPath: task.minecraftDirectory.librariesURL.appendingPathComponent(arm64Path).path
        ) else { return native.path }
        log("natives 架构修正：目标架构 arm64，改用 arm64 分类器 \(arm64Path)（清单条目为 \(native.path)）")
        return arm64Path
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
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func finalWork(_ task: MinecraftInstallTask) {
        guard let manifest = task.manifest else {
            err("finalWork: 任务缺少 manifest，跳过收尾")
            return
        }
        let _1_12_2 = MinecraftVersion(displayName: "1.12.2")
        // 拷贝 log4j2.xml
        let targetURL: URL = task.versionURL.appendingPathComponent("log4j2.xml")
        try? FileManager.default.copyItem(
            at: SharedConstants.shared.applicationResourcesURL.appendingPathComponent(task.minecraftVersion >= _1_12_2 ? "log4j2.xml" : "log4j2-1.12-.xml"),
            to: targetURL
        )
        
        // 初始化实例
        let instance = MinecraftInstance.create(.init(rootURL: task.versionURL.deletingLastPathComponent().deletingLastPathComponent(), name: ""), task.versionURL, config: MinecraftConfig(version: task.minecraftVersion))
        
        instance?.saveConfig()
        
        // 修改 GLFW
        if let glfw = manifest.getNeededLibraries().first(where: { $0.name.contains("lwjgl-glfw") }) {
            guard let javaURL = JavaManager.resolveJavaExecutable() else {
                err("未找到可用的 Java 运行时，无法运行 glfw-patcher")
                return
            }
            let process = Process()
            process.executableURL = javaURL
            process.environment = ProcessInfo.processInfo.environment
            process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
            process.arguments = ["-jar", SharedConstants.shared.applicationResourcesURL.appendingPathComponent("glfw-patcher.jar").path, task.minecraftDirectory.librariesURL.appendingPathComponent(glfw.artifact!.path).path]
            do {
                try Util.runProcessWithTimeout(process, timeout: 30)
                log("已修改 lwjgl-glfw")
            } catch {
                err("无法修改 lwjgl-glfw: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: 修改客户端清单中的 id
    /// 访问级别为 internal：安装编排链（MinecraftInstaller.swift）调用。
    static func modifyId(_ task: MinecraftInstallTask) {
        do {
            let manifestURL = task.versionURL.appendingPathComponent("\(task.versionURL.lastPathComponent).json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
            let fh = try FileHandle(forReadingFrom: manifestURL)
            defer { try? fh.close() }
            guard let data = try? fh.readToEnd(),
                  var dict = try JSON(data: data).dictionaryObject else {
                return
            }
            
            dict["id"] = task.versionURL.lastPathComponent
            
            try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted).write(to: manifestURL, options: .atomic)
            log("已修改客户端清单中的 id")
        } catch {
            err("无法修改 id: \(error.localizedDescription)")
        }
    }
}
