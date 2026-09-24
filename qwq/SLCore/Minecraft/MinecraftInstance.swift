//
//  MinecraftInstance.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/20.
//
//
//  实例装配与启动准备。本文件只保留实例装配与缓存相关职责（逐字保留，未改逻辑与文案）：
//  - 存储属性、private init、setup()、create / clearCache（实例工厂与缓存）
//  启动主流程（登录参数、架构映射、资源完整性检查、进程拉起与退出码处理）已迁至用例层
//  `LaunchService`；原流程 A（MinecraftInstance.launch(_:)）已删除。
//  其余按职责拆分在同目录，逻辑、常量与文案均与原实现逐字一致（仅物理搬移）：
//  - MinecraftInstanceJava.swift     Java 最低版本解析、候选筛选与 DataManager 同步
//  - MinecraftInstanceVersion.swift  品牌判定、清单加载、版本探测与图标名
//  - MinecraftInstanceConfig.swift   配置读写与 MinecraftConfig、ClientBrand 类型定义
//
//  跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
//  与 .../extensions/）：扩展不能声明存储属性，且 `private` 仅对同一封闭声明及其同文件成员可见。
//  存储属性不能由扩展声明，故 version / manifest 的 setter 由 private(set) 放宽为 internal(set)
//  （对外读权限与类型均未变）。对外接口零变化。
//

import Foundation
import SwiftyJSON
import ZIPFoundation
import Cocoa
import Combine
import UniformTypeIdentifiers

public class MinecraftInstance: Identifiable, Equatable, Hashable {
    private static var cache: [URL : MinecraftInstance] = [:]
    
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
        self.configPath = runningDirectory.appendingPathComponent(".SL.json")
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
}
