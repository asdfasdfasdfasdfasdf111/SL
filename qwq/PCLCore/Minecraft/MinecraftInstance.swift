//
//  MinecraftInstance.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//
//
//  实例装配与启动主流程。本文件只保留与启动直接相关的职责（逐字保留，未改逻辑与文案）：
//  - 存储属性、private init、setup()、create / clearCache（实例工厂与缓存）
//  - launch(_:)：登录参数、架构映射、资源完整性检查、进程拉起与退出码处理
//  其余按职责拆分在同目录，逻辑、常量与文案均与原实现逐字一致（仅物理搬移）：
//  - MinecraftInstanceJava.swift     Java 最低版本解析、候选筛选与 DataManager 同步
//  - MinecraftInstanceVersion.swift  品牌判定、清单加载、版本探测与图标名
//  - MinecraftInstanceConfig.swift   配置读写与 MinecraftConfig、ClientBrand 类型定义
//
//  跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
//  与 .../extensions/）：扩展不能声明存储属性，且 `private` 仅对同一封闭声明及其同文件成员可见。
//  存储属性不能由扩展声明，故 version / manifest 的 setter 由 private(set) 放宽为 internal(set)
//  （对外读权限与类型均未变），RequiredJava16/17/21 由 private static 放宽为 internal static。
//  对外接口零变化。
//

import Foundation
import SwiftyJSON
import ZIPFoundation
import Cocoa
import Combine
import UniformTypeIdentifiers

public class MinecraftInstance: Identifiable, Equatable, Hashable {
    private static var cache: [URL : MinecraftInstance] = [:]
    
    static let RequiredJava16: MinecraftVersion = MinecraftVersion(displayName: "21w19a", type: .snapshot)
    static let RequiredJava17: MinecraftVersion = MinecraftVersion(displayName: "1.18-pre2", type: .snapshot)
    static let RequiredJava21: MinecraftVersion = MinecraftVersion(displayName: "24w14a", type: .snapshot)
    
    public let runningDirectory: URL
    public let minecraftDirectory: MinecraftDirectory
    public let configPath: URL
    public internal(set) var version: MinecraftVersion! = nil
    public var process: Process?
    public internal(set) var manifest: ClientManifest!
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
        create(minecraftDirectory, minecraftDirectory.versionsURL.appendingPathComponent(name), config: config)
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
        self.configPath = runningDirectory.appendingPathComponent(".PCL_Mac.json")
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

    /// 流程 A（PCL.Mac 原始启动流程）入口。
    ///
    /// 全库无引用，待清理（含 `qwqTests`）：UI 侧启动已统一改走用例层
    /// `MinecraftInstanceLaunchService.launch(_:)` → 桥接层 `pclLaunch`（见
    /// `Features/Launch/Adapters/DUAL_FLOW.md`），全库不存在任何 `launch(_:)` 调用点，
    /// 因此本方法与其中的资源完整性检查、崩溃弹窗分支（`launcher.launch` 调用点）均不会执行。
    /// 保留原因：两套流程的差异分析（资源检查、崩溃弹窗、账号告警）依赖本文件原样存在。
    @available(*, deprecated, message: "全库无引用，待清理")
    public func launch(_ launchOptions: LaunchOptions) async {
        guard version != nil else {
            log("版本未设置，无法启动")
            return
        }
        if let account = launchOptions.account {
            // 显式暴露未实现能力（治理约定）：microsoft / yggdrasil 登录流程尚未实现，
            // 运行期只会退化为离线账号。此处输出明确告警，避免用户误以为已完成联网登录。
            if let unimplemented = account.unimplementedError {
                warn("\(account.accountKindDescription)：\(unimplemented.errorDescription ?? "该功能尚未实现")")
            }
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
                // 注意：Yggdrasil 认证尚未实现，此处仅预置 authlib-injector，
                // 不代表已完成外置登录（不产生认证会话，游戏按离线模式进入）。
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
        // 本调用点属「全库无引用」的流程 A（见 launch(_:) 的标注）：`launch(_:)` 自身无调用方，
        // 故这里的进程拉起与崩溃弹窗分支在运行期不会执行。**只标注不删除**。
        launcher.launch(launchOptions) { outcome in
            let exitCode: Int32
            switch outcome {
            case .launchFailed(let error):
                // 进程未拉起（无退出码）：不能套用「游戏崩溃退出」的错误分析流程，
                // 否则用户看到的是「Minecraft 出现错误」，无法判断真正原因。
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("启动失败：\(reason)")
                hint("启动失败：\(reason)", .critical)
                return
            case .exited(let status):
                exitCode = status
            }
            if exitCode != 0 {
                log("检测到非 0 退出代码")
                hint("检测到 Minecraft 出现错误，错误分析已开始……")
                Task { [weak self] in
                    guard let self else { return }
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
                        savePanel.beginSheetModal(for: sheetHost) { [weak self] result in
                            guard let self else { return }
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
}
