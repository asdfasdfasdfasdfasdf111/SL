//
//  MinecraftVersion.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation
import SwiftyJSON
import ZIPFoundation
import Cocoa
import Combine
import UniformTypeIdentifiers

public class MinecraftInstance: Identifiable, Equatable, Hashable {
    private static var cache: [URL : MinecraftInstance] = [:]
    
    private static let RequiredJava16: MinecraftVersion = MinecraftVersion(displayName: "21w19a", type: .snapshot)
    private static let RequiredJava17: MinecraftVersion = MinecraftVersion(displayName: "1.18-pre2", type: .snapshot)
    private static let RequiredJava21: MinecraftVersion = MinecraftVersion(displayName: "24w14a", type: .snapshot)
    
    public let runningDirectory: URL
    public let minecraftDirectory: MinecraftDirectory
    public let configPath: URL
    public private(set) var version: MinecraftVersion! = nil
    public var process: Process?
    public private(set) var manifest: ClientManifest!
    public var config: MinecraftConfig!
    public var clientBrand: ClientBrand!
    public var isUsingRosetta: Bool = false
    public var name: String { runningDirectory.lastPathComponent }
    
    public let id: UUID = UUID()
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: MinecraftInstance, rhs: MinecraftInstance) -> Bool {
        lhs.id == rhs.id
    }
    
    public static func create(_ minecraftDirectory: MinecraftDirectory, _ name: String, config: MinecraftConfig? = nil) -> MinecraftInstance? {
        create(minecraftDirectory, minecraftDirectory.versionsURL.appending(path: name), config: config)
    }
    
    public static func create(_ minecraftDirectory: MinecraftDirectory, _ runningDirectory: URL, config: MinecraftConfig? = nil) -> MinecraftInstance? {
        if let cached = cache[runningDirectory] {
            return cached
        }
        
        let instance: MinecraftInstance = .init(minecraftDirectory: minecraftDirectory, runningDirectory: runningDirectory, config: config)
        if instance.setup() {
            cache[runningDirectory] = instance
            return instance
        } else {
            err("实例初始化失败")
            return nil
        }
    }
    
    public static func clearCache(for runningDirectory: URL) {
        cache.removeValue(forKey: runningDirectory)
        log("已清理实例缓存: \(runningDirectory.lastPathComponent)")
    }
    

    
    private init(minecraftDirectory: MinecraftDirectory, runningDirectory: URL, config: MinecraftConfig? = nil) {
        self.runningDirectory = runningDirectory
        self.minecraftDirectory = minecraftDirectory
        self.configPath = runningDirectory.appending(path: ".PCL_Mac.json")
        self.config = config
    }
    
    private func setup() -> Bool {
        // 若配置文件存在，从文件加载配置
        if FileManager.default.fileExists(atPath: configPath.path) {
            do {
                try loadConfig()
            } catch {
                err("无法加载配置: \(error.localizedDescription)")
                debug(configPath.path)
            }
        }
        self.config = config ?? MinecraftConfig(version: nil)
        
        if !loadManifest() { return false }
        if let version = config.minecraftVersion {
            self.version = .init(displayName: version)
        } else {
            detectVersion()
            config.minecraftVersion = version.displayName
        }
        
        // 寻找可用 Java（优先使用 manifest.javaVersion，其次版本推断）
        resolveAndApplyJava()
        self.saveConfig()
        return true
    }

    /// 根据当前 manifest/version 解析所需最低 Java 版本并自动选择最合适的 JVM
    @discardableResult
    public func resolveAndApplyJava() -> JavaVirtualMachine? {
        let minJavaVersion = Self.resolveMinJavaVersion(manifest: manifest, version: version)

        // 若用户缓存的 Java 仍满足版本要求，且可执行文件实际存在，保留之
        if let currentURL = config.javaURL {
            if FileManager.default.isExecutableFile(atPath: currentURL.path),
               let currentMajor = Self.readJavaMajorVersion(at: currentURL),
               currentMajor >= minJavaVersion {
                debug("沿用缓存 Java: \(currentURL.path) (major=\(currentMajor), 需要>=\(minJavaVersion))")
                // 确保同步到 DataManager，以便其他 UI 组件能看到
                Self.ensureDataManagerHasJava(currentURL)
                return Self.findJVM(at: currentURL)
            } else {
                warn("缓存的 Java 不满足当前版本 (需要>=\(minJavaVersion)) 或已失效，重新选择")
                config.javaURL = nil
            }
        }

        guard let jvm = Self.findSuitableJava(version, minJavaVersion: minJavaVersion, manifest: manifest) else {
            return nil
        }
        config.javaURL = jvm.executableURL
        debug("自动选择 Java: \(jvm.executableURL.path) (major=\(jvm.version), 需要>=\(minJavaVersion))")
        return jvm
    }

    /// 解析最低 Java 版本：优先 manifest.javaVersion，无则根据 MC 版本推断
    public static func resolveMinJavaVersion(manifest: ClientManifest?, version: MinecraftVersion?) -> Int {
        if let manifestJava = manifest?.javaVersion, manifestJava > 0 {
            return manifestJava
        }
        guard let version else { return 8 }
        return getMinJavaVersion(version)
    }

    /// 读取指定 java 可执行文件的主版本号（读 release 文件，不启动进程）
    public static func readJavaMajorVersion(at javaURL: URL) -> Int? {
        let base = javaURL.deletingLastPathComponent().deletingLastPathComponent()
        let candidates: [URL] = [
            base.appending(path: "release"),
            base.deletingLastPathComponent().appending(path: "release"),
        ]
        for releaseURL in candidates {
            guard let content = try? String(contentsOf: releaseURL, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                if line.hasPrefix("JAVA_VERSION=") {
                    let values = line.replacingOccurrences(of: "JAVA_VERSION=", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                        .split(separator: ".")
                        .compactMap { Int($0) }
                    if let first = values.first {
                        return first == 1 ? (values.count > 1 ? values[1] : 8) : first
                    }
                }
            }
        }
        return nil
    }

    private static func findJVM(at url: URL) -> JavaVirtualMachine? {
        DataManager.shared.javaVirtualMachines.first(where: { $0.executableURL.path == url.path })
    }

    private static func ensureDataManagerHasJava(_ url: URL) {
        guard findJVM(at: url) == nil else { return }
        let arch = Architecture.getArchOfFile(url)
        let callMethod: CallMethod = arch == Architecture.system ? .direct : (Architecture.system == .arm64 ? .transition : .incompatible)
        let major = readJavaMajorVersion(at: url) ?? 0
        let jvm = JavaVirtualMachine(
            arch: arch,
            version: major,
            displayVersion: "\(major)",
            implementor: nil,
            executableURL: url,
            callMethod: callMethod,
            isJdk: nil
        )
        DataManager.shared.javaVirtualMachines.append(jvm)
    }

    private static func archName(_ arch: Architecture) -> String {
        switch arch {
        case .arm64: return "arm64"
        case .x64: return "x64"
        case .fatFile: return "fat"
        case .unknown: return "unknown"
        }
    }
    
    public func loadConfig() throws {
        // readToEnd 可能返回 nil（空/损坏配置文件），强解包会崩；失败时抛错让调用方用默认配置
        guard let data = try FileHandle(forReadingFrom: configPath).readToEnd() else {
            throw MyLocalizedError(reason: "配置文件为空: \(configPath.path)")
        }
        self.config = .init(try .init(data: data))
    }
    
    public func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            try FileManager.default.createDirectory(
                at: runningDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try encoder.encode(config).write(to: configPath, options: .atomic)
        } catch {
            err("无法保存配置: \(error.localizedDescription)")
        }
    }
    
    private static func getClientBrand(_ manifestString: String) -> ClientBrand {
        if manifestString.contains("neoforged") {
            return .neoforge
        } else if manifestString.contains("fabric") {
            return .fabric
        } else if manifestString.contains("forge") {
            return .forge
        } else {
            return .vanilla
        }
    }
    
    public static func getMinJavaVersion(_ version: MinecraftVersion) -> Int {
        if version >= RequiredJava21 {
            return 21
        } else if version >= RequiredJava17 {
            return 17
        } else if version >= RequiredJava16 {
            return 16
        } else {
            return 8
        }
    }
    
    public static func findSuitableJava(_ version: MinecraftVersion, minJavaVersion: Int? = nil, manifest: ClientManifest? = nil) -> JavaVirtualMachine? {
        let resolvedMin = minJavaVersion ?? resolveMinJavaVersion(manifest: manifest, version: version)
        let validJVMs = DataManager.shared.javaVirtualMachines.filter { $0.version > 0 && $0.callMethod != .incompatible }

        debug("寻找 Java: 版本=\(version.displayName), 最低 Java=\(resolvedMin), 候选 JVM=\(validJVMs.count)")
        for jvm in validJVMs {
            debug("  候选: \(jvm.executableURL.path) (major=\(jvm.version), arch=\(archName(jvm.arch)), callMethod=\(jvm.callMethod))")
        }

        // 优先选择：callMethod == .direct 且 version >= min
        // 次选：callMethod == .transition（Rosetta）且 version >= min
        var directCandidate: JavaVirtualMachine?
        var transitionCandidate: JavaVirtualMachine?
        for jvm in validJVMs.sorted(by: { $0.version < $1.version }) {
            if jvm.version < resolvedMin { continue }
            if jvm.callMethod == .direct {
                directCandidate = jvm
                break
            }
            if transitionCandidate == nil && jvm.callMethod == .transition {
                transitionCandidate = jvm
            }
        }

        let result = directCandidate ?? transitionCandidate
        if let result {
            debug("选定 Java: \(result.executableURL.path) (major=\(result.version), callMethod=\(result.callMethod))")
        } else {
            warn("未找到可用 Java")
            warn("  版本: \(version.displayName)")
            warn("  最低 Java 版本: \(resolvedMin)")
            warn("  可用 JVM 数量: \(validJVMs.count)")
        }
        return result
    }
    
    public func launch(_ launchOptions: LaunchOptions) async {
        if let account = launchOptions.account {
            // 防御性校验（PCL2 风格）：非法用户名直接终止启动，
            // 否则 1.20.5+ 会因 hello 包 writeUtf(name,16) 抛 EncoderException 而进服失败
            let nameError = validateOfflineUsername(account.name)
            guard nameError.isEmpty else {
                log("离线登录参数无效：\(nameError)")
                return
            }
            launchOptions.playerName = account.name
            launchOptions.uuid = account.uuid
            log("正在登录")
            await account.putAccessToken(options: launchOptions)
            if case .yggdrasil = account {
                try? await MinecraftLauncher.downloadAuthlibInjector() // 后面改成可抛出 + 多阶段
            }
        }
        launchOptions.javaPath = config.javaURL
        
        loadManifest()
        if Architecture.getArchOfFile(launchOptions.javaPath).isCompatiableWithSystem() {
            ArtifactVersionMapper.map(manifest)
            isUsingRosetta = false
        } else {
            ArtifactVersionMapper.map(manifest, arch: .x64)
            isUsingRosetta = true
            warn("正在使用 Rosetta 运行 Minecraft")
        }
        
        if !config.skipResourcesCheck && !launchOptions.skipResourceCheck {
            log("正在进行资源完整性检查")
            await withCheckedContinuation { continuation in
                let task = MinecraftInstaller.createCompleteTask(self, continuation.resume)
                task.start()
            }
            log("资源完整性检查完成")
        }
        
        let launcher = MinecraftLauncher(self)!
        launcher.launch(launchOptions) { exitCode in
            if exitCode != 0 {
                log("检测到非 0 退出代码")
                hint("检测到 Minecraft 出现错误，错误分析已开始……")
                Task {
                    if await PopupManager.shared.showAsync(
                        .init(.error, "Minecraft 出现错误", "很抱歉，PCL.Mac 暂时没有分析功能。\n如果要寻求帮助，请把错误报告文件发给对方，而不是发送这个窗口的照片或者截图。\n不要截图！不要截图！！不要截图！！！", [.ok, .init(label: "导出错误报告", style: .accent)])
                    ) == 1 {
                        let savePanel = NSSavePanel()
                        savePanel.title = "选择导出位置"
                        savePanel.prompt = "导出"
                        savePanel.allowedContentTypes = [.zip]
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-M-d_HH.mm.ss"
                        savePanel.nameFieldStringValue = "错误报告-\(formatter.string(from: .init()))"
                        // 窗口列表可能为空（极端时序），强解包会崩；失败回退到 keyWindow
                        let sheetHost = NSApplication.shared.windows.first ?? NSApplication.shared.keyWindow
                        guard let sheetHost else {
                            err("无法找到窗口以显示错误报告导出面板")
                            return
                        }
                        savePanel.beginSheetModal(for: sheetHost) { [unowned self] result in
                            if result == .OK {
                                if let url = savePanel.url {
                                    MinecraftCrashHandler.exportErrorReport(self, launcher, to: url)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    @discardableResult
    private func loadManifest() -> Bool {
        do {
            let manifestPath = runningDirectory.appending(path: runningDirectory.lastPathComponent + ".json")
            
            // readToEnd 可能返回 nil（空/损坏清单文件），强解包会崩；失败按读取失败处理
            guard let data = try FileHandle(forReadingFrom: manifestPath).readToEnd() else {
                err("无法读取 \(manifestPath.lastPathComponent): 文件为空")
                return false
            }
            self.clientBrand = MinecraftInstance.getClientBrand(String(data: data, encoding: .utf8) ?? "")
            
            guard let manifest = try ClientManifest.parse(
                url: manifestPath, minecraftDirectory: minecraftDirectory
            ) else { return false }
            self.manifest = manifest
        } catch {
            err("无法加载客户端清单: \(error.localizedDescription)")
            return false
        }
        
        return true
    }
    
    private func detectVersion() {
        guard version == nil else {
            return
        }
        do {
            let archive = try Archive(url: runningDirectory.appending(path: "\(name).jar"), accessMode: .read)
            guard let entry = archive["version.json"] else {
                throw MyLocalizedError(reason: "version.json 不存在")
            }
            
            var data = Data()
            _ = try archive.extract(entry, consumer: { (chunk) in
                data.append(chunk)
            })
            
            let version = MinecraftVersion(displayName: try JSON(data: data)["id"].stringValue)
            self.version = version
        } catch {
            err("无法检测版本: \(error.localizedDescription)，正在使用清单版本")
            self.version = .init(displayName: manifest.id)
        }
    }
    
    public func getIconName() -> String {
        if self.clientBrand == .vanilla {
            return self.version.getIconName()
        }
        return "\(self.clientBrand.rawValue.capitalized)Icon"
    }
}

public struct MinecraftConfig: Codable {
    public var additionalLibraries: Set<String> = []
    public var javaURL: URL! {
        get {
            return javaURLString == "" ? nil : URL(fileURLWithPath: javaURLString)
        }
        set (value) {
            javaURLString = value.path
        }
    }
    public var skipResourcesCheck: Bool = false
    public var maxMemory: Int32 = 4096
    public var qualityOfService: QualityOfService = .default
    public var minecraftVersion: String!
    
    private var javaURLString: String
    
    enum CodingKeys: String, CodingKey {
        case additionalLibraries
        case javaURLString = "javaURL"
        case skipResourcesCheck
        case maxMemory
        case qualityOfService
        case minecraftVersion
    }
    
    public init(_ json: JSON) {
        self.additionalLibraries = .init(json["additionalLibraries"].array?.map { $0.stringValue } ?? [])
        self.javaURLString = json["javaURL"].stringValue // 旧版本字段
        self.skipResourcesCheck = json["skipResourcesCheck"].boolValue
        self.maxMemory = json["maxMemory"].int32 ?? 4096
        self.qualityOfService = .init(rawValue: json["qualityOfService"].intValue) ?? .default
        self.minecraftVersion = json["minecraftVersion"].stringValue
        if qualityOfService.rawValue == 0 {
            qualityOfService = .default
        }
    }
    
    public init(version: MinecraftVersion?) {
        self.minecraftVersion = version?.displayName
        self.javaURLString = ""
    }
}

public enum ClientBrand: String, Codable, Hashable {
    case vanilla = "vanilla"
    case fabric = "fabric"
    case quilt = "quilt"
    case forge = "forge"
    case neoforge = "neoforge"
    
    public func getName() -> String {
        if self == .neoforge {
            return "NeoForge"
        } else {
            return self.rawValue.capitalized
        }
    }
    
    public var index: Int {
        switch self {
        case .vanilla: 0
        case .fabric: 1
        case .quilt: 2
        case .forge: 3
        case .neoforge: 4
        }
    }
}

extension QualityOfService: Codable { }
