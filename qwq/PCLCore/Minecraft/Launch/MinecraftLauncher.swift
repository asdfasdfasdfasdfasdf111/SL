//
//  MinecraftLauncher.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation
import Cocoa
import Combine
import SwiftyJSON

public class MinecraftLauncher {
    public let instance: MinecraftInstance
    private let id = UUID()
    public let logURL: URL
    /// 本 launcher 自己启动的进程引用。不依赖 instance.process（后者会被同版本的其它 launcher 覆盖）。
    public private(set) var currentProcess: Process?
    
    public init?(_ instance: MinecraftInstance) {
        self.instance = instance
        self.logURL = SharedConstants.shared.applicationSupportURL.appending(path: "GameLogs").appending(path: id.uuidString + ".log")
        try? FileManager.default.createDirectory(at: logURL.parent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
    }
    
    public func launch(_ options: LaunchOptions, _ callback: @MainActor @escaping (Int32) -> Void = { _ in }) {
        let process = Process()
        process.executableURL = options.javaPath
        process.environment = ProcessInfo.processInfo.environment
        process.arguments = []
        process.arguments!.append(contentsOf: buildJvmArguments(options))
        process.arguments!.append(instance.manifest.mainClass)
        process.arguments!.append(contentsOf: buildGameArguments(options))
        let command = process.executableURL!.path + " " + process.arguments!.joined(separator: " ")
            .replacingOccurrences(of: #"--accessToken\s+\S+"#, with: "--accessToken 🎉", options: .regularExpression)
        debug(command)
        MinecraftCrashHandler.lastLaunchCommand = command
        process.currentDirectoryURL = instance.runningDirectory
        
        if instance.config.qualityOfService.rawValue == 0 {
            instance.config.qualityOfService = .default
        }
        process.qualityOfService = instance.config.qualityOfService
        
        instance.process = process
        self.currentProcess = process
        do {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            let logHandle = try FileHandle(forWritingTo: logURL)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                for line in String(data: handle.availableData, encoding: .utf8)!.split(separator: "\n") {
                    raw(line.replacing("\t", with: "    "))
                    try? logHandle.write(contentsOf: (line + "\n").data(using: .utf8)!)
                    logHandle.seekToEndOfFile()
                }
            }
            
            try process.run()
            
            Task { // 轮询判断窗口是否出现
                while process.isRunning {
                    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
                    guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                        throw NSError()
                    }
                    
                    for info in windowInfoList {
                        if let windowPID = info["kCGWindowOwnerPID"] as? Int32,
                           windowPID == process.processIdentifier {
                            log("窗口已出现")
                            return
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            }
            
            process.waitUntilExit()
            log("\(instance.name) 进程已退出, 退出代码 \(process.terminationStatus)")
            if process.terminationStatus == 0 {
                debug("检测到退出代码为 0，已删除日志")
                try? FileManager.default.removeItem(at: self.logURL)
            }
            DispatchQueue.main.async {
                callback(process.terminationStatus)
            }
            instance.process = nil
        } catch {
            err(error.localizedDescription)
        }
    }
    
    public func buildJvmArguments(_ options: LaunchOptions) -> [String] {
        let values: [String: String] = [
            "natives_directory": instance.runningDirectory.appending(path: "natives").path,
            "launcher_name": "PCL.Mac",
            "launcher_version": SharedConstants.shared.version,
            "classpath": buildClasspath(),
            "classpath_separator": ":",
            "library_directory": instance.minecraftDirectory.librariesURL.path,
            "version_name": instance.name,
            "authlib_injector_path": SharedConstants.shared.authlibInjectorURL.path
        ]

        // 1) 先放 yggdrasil 认证参数（离线账号时为空）
        var args: [String] = Array(options.yggdrasilArguments)

        // 2) 动态读取 manifest 中的 JVM 参数（含 Forge/Fabric/NeoForge 清单合并后的结果）
        let manifestJVM = instance.manifest.getArguments().getAllowedJVMArguments()
        args.append(contentsOf: manifestJVM)

        // 3) 动态补齐缺失的关键参数（仅当 manifest 未提供时才追加，避免重复）

        // -Xmx 内存：manifest 一般不含，始终追加
        args.append("-Xmx\(instance.config.maxMemory)m")

        // -Djna.tmpdir：若 manifest 未提供则补齐
        let hasJnaTmp = manifestJVM.contains { $0.contains("jna.tmpdir") }
        if !hasJnaTmp {
            args.append("-Djna.tmpdir=${natives_directory}")
        }

        // -cp ${classpath}：若 manifest 未提供则补齐
        let hasClasspath = manifestJVM.contains { $0 == "-cp" } || manifestJVM.contains { $0 == "-classpath" } || manifestJVM.contains { $0.contains("${classpath}") }
        if !hasClasspath {
            args.append(contentsOf: ["-cp", "${classpath}"])
        }

        // 4) 平台/版本适配参数补齐（均先查重，manifest 已有则不重复）
        // macOS LWJGL3 必需：令启动线程成为 AWT 主线程（官方 1.13+ JSON 自带；第三方/自定义 JSON 丢失时补齐）
        let hasStartOnFirstThread = args.contains { $0.contains("XstartOnFirstThread") }
        if !hasStartOnFirstThread {
            args.append("-XstartOnFirstThread")
        }

        // Java 8 及以下默认 GC 为 CMS/Serial，显式启用 G1 改善长卡顿（Java 9+ 默认已是 G1，无需）
        if let javaPath = options.javaPath,
           let javaMajor = MinecraftInstance.readJavaMajorVersion(at: javaPath),
           javaMajor <= 8,
           !args.contains(where: { $0.contains("UseG1GC") }) {
            args.append("-XX:+UseG1GC")
        }

        // 诊断：OOM 时留下堆转储现场（零运行开销，仅在崩溃时写文件）
        if !args.contains(where: { $0.contains("HeapDumpOnOutOfMemoryError") }) {
            args.append("-XX:+HeapDumpOnOutOfMemoryError")
        }

        // 字符编码一致性：显式声明 UTF-8，避免环境差异导致的乱码
        if !args.contains(where: { $0.contains("file.encoding") }) {
            args.append("-Dfile.encoding=UTF-8")
        }

        return Util.replaceTemplateStrings(args, with: values)
    }
    
    private func buildClasspath() -> String {
        // 去重
        ClientManifest.deduplicateLibraries(instance.manifest)
        
        var urls: [URL] = []
        for library in instance.manifest.getNeededLibraries() {
            if let artifact = library.artifact {
                urls.append(instance.minecraftDirectory.librariesURL.appending(path: artifact.path))
            }
        }
        urls.append(instance.runningDirectory.appending(path: "\(instance.name).jar"))

        return urls.map { $0.path }.joined(separator: ":")
    }
    
    private func buildGameArguments(_ options: LaunchOptions) -> [String] {
        let values: [String: String] = [
            "auth_player_name": options.playerName,
            "version_name": instance.version!.displayName,
            "game_directory": instance.runningDirectory.path,
            "assets_root": instance.minecraftDirectory.assetsURL.path,
            "assets_index_name": instance.manifest.assetIndex?.id ?? "",
            "auth_uuid": options.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "auth_access_token": options.accessToken,
            "user_type": "msa",
            "version_type": "PCL.Mac \(SharedConstants.shared.version)",
            "user_properties": "\"{}\""
        ]
        
        var args: [String] = []
        if options.isDemo {
            args.append("--demo")
        }
        
        return Util.replaceTemplateStrings(instance.manifest.getArguments().getAllowedGameArguments(), with: values).union(args)
    }
    
    public static func downloadAuthlibInjector() async throws {
        if FileManager.default.fileExists(atPath: SharedConstants.shared.authlibInjectorURL.path) { return }
        let json = try await Requests.get("https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json").getJSONOrThrow()
        guard let downloadURL = json["download_url"].url else {
            throw MyLocalizedError(reason: "无效的 authlib-injector 下载 URL")
        }
        try await SingleFileDownloader.download(url: downloadURL, destination: SharedConstants.shared.authlibInjectorURL)
        log("authlib-injector 下载完成")
    }
}

public class LaunchState: ObservableObject {
    @Published public var isLaunched: Bool = false
}
