//
//  ForgeInstallerInstallFlow.swift
//  PCL.Mac
//
//  Forge / NeoForge 安装流程（从 ForgeInstaller.swift 逐字搬移，逻辑、常量与日志文案未变）：
//  - parseValue / parseValues：install_profile.json 中 data 段的值解析（含 installer.jar 内条目提取）
//  - replaceWithValue：执行参数中的 {PLACEHOLDER} 占位符替换
//  - executeProcessor / executeProcessors：安装器处理器的执行与循环
//  - loadInstallProfile：安装器内 install_profile.json 的加载与新旧格式分流
//  - copyManifest：客户端清单的落地与 inheritsFrom 基准清单补全
//
//  已切换到 DownloadEngine 的单文件下载与下载阶段编排仍留在 ForgeInstaller.swift，本次未作改动。
//

import Foundation
import ZIPFoundation
import SwiftyJSON

extension ForgeInstaller {

    // MARK: - 解析 data 中的值
    private func parseValue(_ value: String) -> String {
        let value = "\(value)"
        // 若被 [ ] 包裹，解析中间部分的 Maven 坐标并拼接到 libraries 后
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = String(value.dropFirst().dropLast())
            return minecraftDirectory.librariesURL.appendingPathComponent(Util.toPath(mavenCoordinate: inner)).path
        } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            // 若被 ' ' 包裹，去除 ' '
            return String(value.dropFirst().dropLast())
        }
        
        return value
    }
    
    // MARK: - 解析 data
    /// 访问级别为 internal：安装入口 `install`（ForgeInstaller.swift）调用。
    @MainActor func parseValues() throws {
        guard let installProfile else {
            return
        }
        
        // 创建默认键值对
        values["SIDE"] = "client"
        values["INSTALLER"] = temp.root.appendingPathComponent("installer.jar").path
        values["MINECRAFT_JAR"] = versionPath.appendingPathComponent("\(versionPath.lastPathComponent).jar").path
        values["MINECRAFT_VERSION"] = values["MINECRAFT_JAR"]!
        values["ROOT"] = minecraftDirectory.rootURL.path
        values["LIBRARY_DIR"] = minecraftDirectory.librariesURL.path
        
        let step: Double = 0.1 / Double(installProfile.data.count)
        
        for (key, value) in installProfile.data {
            log("正在解析 \(key) 的值")
            if value.starts(with: "/") {
                let archive = try Archive(url: temp.getURL(path: "installer.jar"), accessMode: .read)
                let data = try ArchiveUtil.getEntryOrThrow(archive: archive, name: String(value.dropFirst(1)))
                if let url = temp.createFile(path: value, data: data) {
                    values[key] = url.path
                }
            } else {
                let parsed = parseValue(value)
                values[key] = parsed
            }
            
            increaseProgress(step)
        }
    }
    
    // MARK: - 替换字符串中的占位符
    /// 访问级别为 internal：DOWNLOAD_MOJMAPS 任务改写（ForgeInstaller.swift）调用。
    func replaceWithValue(_ string: String) -> String {
        let string = parseValue(string)
        // 如果字符串中不存在 { }，直接返回来节省资源
        if !string.contains("{") || !string.contains("}") { return string }
        
        // 逐个替换所有占位符（同一参数中可能同时出现多个，如 {LIBRARY_DIR} 与 {MINECRAFT_JAR}）
        var result = string
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
    
    // MARK: - 执行处理器任务
    private func executeProcessor(_ processor: ForgeInstallProfile.Processor) throws {
        let processorPath = minecraftDirectory.librariesURL.appendingPathComponent(processor.jarPath)
        guard let mainClass = Util.getMainClass(processorPath) else {
            warn("\(processorPath.lastPathComponent) 没有主类")
            return
        }
        
        let process = Process()
        process.currentDirectoryURL = temp.root
        guard let javaURL = JavaManager.resolveJavaExecutable() else {
            throw MyLocalizedError(reason: "未找到可用的 Java 运行时，无法执行 Forge 处理器")
        }
        process.executableURL = javaURL
        process.arguments = [
            // processor 初始化逻辑中往 classpath 里添加了它本身的 jar，这里直接 map
            "-cp", processor.classpath.map { minecraftDirectory.librariesURL.appendingPathComponent($0).path }.joined(separator: ":"),
            mainClass
        ]
        process.arguments!.append(contentsOf: processor.args.map(replaceWithValue(_:)))
        try Util.runProcessWithTimeout(process, timeout: 120)
    }
    
    // MARK: - 执行所有处理器任务
    /// 访问级别为 internal：安装入口 `install`（ForgeInstaller.swift）调用。
    func executeProcessors() async throws {
        guard let installProfile else {
            throw MyLocalizedError(reason: "installProfile 为空")
        }
        
        let processors = installProfile.processors.filter { $0.isAvailableOnClient }
        let step = 0.4 / Double(processors.count)
        
        for processor in processors {
            if processor.args.contains("DOWNLOAD_MOJMAPS") {
                if try await patchMojangMappingsDownloadTask(processor) {
                    continue
                }
            }
            if let index = processor.args.firstIndex(of: "--task") {
                log("正在执行安装器 \(processor.args[index + 1])")
            }
            try executeProcessor(processor)
            await increaseProgress(step)
        }
    }
    
    // MARK: - 加载 install_profile.json
    private func loadInstallProfile() throws {
        let installerPath = temp.getURL(path: "installer.jar")
        let archive = try Archive(url: installerPath, accessMode: .read)
        let json = try JSON(data: try ArchiveUtil.getEntryOrThrow(archive: archive, name: "install_profile.json"))
        
        if json["install"].exists() {
            isOld = true
            log("该安装器为旧版格式")
            temp.createFile(path: "manifest.json", data: try json["versionInfo"].rawData())
            
            let forgePath = minecraftDirectory.librariesURL.appendingPathComponent(Util.toPath(mavenCoordinate: json["install"]["path"].stringValue))
            
            try? FileManager.default.createDirectory(at: forgePath.parent(), withIntermediateDirectories: true)
            try ArchiveUtil.getEntryOrThrow(archive: archive, name: json["install"]["filePath"].stringValue).write(to: forgePath, options: .atomic)
        } else {
            installProfile = ForgeInstallProfile(json: json)
            temp.createFile(path: "manifest.json", data: try ArchiveUtil.getEntryOrThrow(archive: archive, name: "version.json"))
        }
    }
    
    // MARK: - 拷贝客户端清单
    /// 访问级别为 internal：安装入口 `install`（ForgeInstaller.swift）调用。
    func copyManifest(version: MinecraftVersion) throws {
        try loadInstallProfile()
        let manifestURL = versionPath.appendingPathComponent("\(versionPath.lastPathComponent).json")
        
        // 若 inheritsFrom 对应的版本 JSON 不存在，复制
        let baseManifestURL = minecraftDirectory.versionsURL.appendingPathComponent(version.displayName).appendingPathComponent("\(version.displayName).json")
        if !FileManager.default.fileExists(atPath: baseManifestURL.path) {
            try? FileManager.default.createDirectory(at: baseManifestURL.parent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: manifestURL, to: baseManifestURL)
        }
        
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.copyItem(at: temp.getURL(path: "manifest.json"), to: manifestURL)
        log("客户端清单拷贝完成")
    }
}
