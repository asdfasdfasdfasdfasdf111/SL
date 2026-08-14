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

private final class LaunchCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return false }
        didComplete = true
        return true
    }
}

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
        // 正常 terminationHandler、轮询兜底和 run() 抛错共享一次性门控，避免重复复位 UI。
        let terminationSemaphore = DispatchSemaphore(value: 0)
        let completionGate = LaunchCompletionGate()
        let reportCompletion: (Int32) -> Void = { status in
            guard completionGate.claim() else { return }
            DispatchQueue.main.async { callback(status) }
        }
        do {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let logHandle = try FileHandle(forWritingTo: logURL)
            // 管道字节可能含非法 UTF-8（Java/模组输出非 UTF-8 编码时不崩溃）；解码失败行丢弃。
            // readabilityHandler 在 FileHandle 专用串行队列回调，缓冲区无需加锁；
            // 跨回调保留尾部字节，避免多字节 UTF-8 字符/长日志行被 availableData 边界截断产生乱码或拆行。
            var logBuffer = Data()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                logBuffer.append(data)
                while let nl = logBuffer.firstIndex(of: 0x0A) {
                    let lineData = logBuffer.prefix(upTo: nl)
                    logBuffer.removeSubrange(0...nl)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    raw(line.replacing("\t", with: "    "))
                    try? logHandle.write(contentsOf: (line + "\n").data(using: .utf8)!)
                    logHandle.seekToEndOfFile()
                }
            }

            // terminationHandler 在 run() 之前设置（消除竞态）：若进程启动后立刻退出
            // （秒退/崩溃/手动关闭恰好在 run 之后），后置的 handler 可能永远不触发，
            // 导致启动器识别不到「游戏已关闭」。前置设置保证任何退出都能回调；
            // 回调经一次性门控（与下方轮询兜底互斥），只落一次到 UI。
            process.terminationHandler = { proc in
                terminationSemaphore.signal()
                reportCompletion(proc.terminationStatus)
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

            // 等待进程退出（替代 process.waitUntilExit()，后者在 Java 死锁时可能无限阻塞）。
            // 带超时轮询兜底：terminationHandler 因任何原因未触发时，检测到进程不再运行
            // 就主动回调，确保「手动关闭/异常退出」的进程必然被识别并复位 UI。
            while terminationSemaphore.wait(timeout: .now() + 1) == .timedOut {
                if !process.isRunning {
                    log("兜底检测到进程已退出（terminationHandler 未触发）")
                    reportCompletion(process.terminationStatus)
                    break
                }
            }
            log("\(instance.name) 进程已退出, 退出代码 \(process.terminationStatus)")
            if process.terminationStatus == 0 {
                debug("检测到退出代码为 0，已删除日志")
                try? FileManager.default.removeItem(at: self.logURL)
            }
            // 归属校验：回调已异步提交主队列，旧 launch 线程可能晚于「回调内快速重启新游戏」执行到这里，
            // 无条件置 nil 会清掉新启动进程的引用。仅当引用仍是本进程时才清理（崩溃 #4 教训）。
            if instance.process === process {
                instance.process = nil
            }
        } catch {
            err(error.localizedDescription)
            // 启动失败也走一次性门控回调（exitCode 非 0），UI 才能复位「启动中」状态；
            // terminationHandler 在 run() 前已设置，若 run 抛错则其绝不会触发。
            if instance.process === process {
                instance.process = nil
            }
            if self.currentProcess === process {
                self.currentProcess = nil
            }
            reportCompletion(Int32(1))
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

        // -Xmx 内存：manifest 一般不含；用户已显式指定（自定义 JVM 参数/高级设置）则不覆盖
        if !args.contains(where: { $0.contains("-Xmx") }) {
            args.append("-Xmx\(instance.config.maxMemory)m")
        }

        // -Xms 堆初始大小：与 -Xmx 同级避免堆扩张时的 GC 停顿（参考 Swift Craft Launcher）。
        // 默认取 maxMemory 的一半，下限 256m；用户/清单已显式指定则不覆盖
        if !args.contains(where: { $0.contains("-Xms") }) {
            let xms = max(256, instance.config.maxMemory / 2)
            args.append("-Xms\(xms)m")
        }

        // Log4Shell 漏洞防御（对照 PCL2 ModLaunch.vb：老版本 1.18.1 及以下官方 JSON
        // 不携带 -Dlog4j2.formatMsgNoLookups=true，需启动器强制补上，否则日志注入可执行代码）
        if !args.contains(where: { $0.contains("log4j2.formatMsgNoLookups") }) {
            args.append("-Dlog4j2.formatMsgNoLookups=true")
        }

        // -Djava.library.path：LWJGL 加载 native 库必需。官方 1.13+ JSON 自带，
        // 第三方/自定义 JSON 丢失时补齐（对照 PCL2 McLaunchArgumentsJvmOld 强制注入）
        if !args.contains(where: { $0.contains("java.library.path") }) {
            args.append("-Djava.library.path=${natives_directory}")
        }

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

        // Java 9+（默认 G1）：无显式 GC 选择时注入低风险 G1 停顿调优
        // （-XX:+ParallelRefProcEnabled / -XX:MaxGCPauseMillis=200，参考 Swift Craft Launcher balanced 预设），
        // 用户若显式指定了 ZGC/Shenandoah 等其他收集器则整组跳过
        if let javaPath = options.javaPath,
           let javaMajor = MinecraftInstance.readJavaMajorVersion(at: javaPath),
           javaMajor >= 9 {
            let explicitGC = ["UseG1GC", "UseZGC", "UseShenandoahGC", "UseParallelGC", "UseSerialGC", "UseEpsilonGC"]
                .contains { gc in args.contains { $0.contains(gc) } }
            if !explicitGC {
                if !args.contains(where: { $0.contains("ParallelRefProcEnabled") }) {
                    args.append("-XX:+ParallelRefProcEnabled")
                }
                if !args.contains(where: { $0.contains("MaxGCPauseMillis") }) {
                    args.append("-XX:MaxGCPauseMillis=200")
                }
            }
        }

        // 异常热路径优化：重复抛同一异常只保留首次堆栈（-XX:+OmitStackTraceInFastThrow），
        // 字符串拼接改为 StringBuilder 式优化（-XX:+OptimizeStringConcat）；均为零风险参数
        if !args.contains(where: { $0.contains("OmitStackTraceInFastThrow") }) {
            args.append("-XX:+OmitStackTraceInFastThrow")
        }
        if !args.contains(where: { $0.contains("OptimizeStringConcat") }) {
            args.append("-XX:+OptimizeStringConcat")
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
        // 用户类型：PCL2 强制所有账号（含离线）传 "msa"（ModLaunch.vb 第 1546 行，issue #1221）。
        // 离线账号若按旧逻辑传 "legacy"，部分 1.20.5+ 服务端/插件按非正版身份处理导致进服异常；
        // 与 PCL2 保持一致即对所有账号统一 "msa"。
        // （注意：离线模式 16 字符用户名校验由 hello 包编码端做，见 buildGameArguments 下方
        //   "auth_player_name" —— 超过 16 字符会抛 EncoderException "String too big"）
        let userType = "msa"
        let values: [String: String] = [
            "auth_player_name": options.playerName,
            "version_name": instance.version!.displayName,
            "game_directory": instance.runningDirectory.path,
            "assets_root": instance.minecraftDirectory.assetsURL.path,
            "assets_index_name": instance.manifest.assetIndex?.id ?? "",
            "auth_uuid": options.uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "auth_access_token": options.accessToken,
            "auth_session": options.accessToken,
            "user_type": userType,
            // version_type：对照 PCL2 ModLaunch.vb（${version_type} = 版本类型，如 release/snapshot）。
            // 旧实现硬编码 "PCL.Mac x" 会污染 F3 调试面板的版本类型显示，改用 manifest.type。
            "version_type": instance.manifest.type.isEmpty ? "release" : instance.manifest.type,
            // user_properties：与 PCL2 一致传 {} （不带引号——Process.arguments 不走 shell，
            // 模板值会原样成为单个参数，带引号反而让 Java 收到字面 "{}"）
            "user_properties": "{}"
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
