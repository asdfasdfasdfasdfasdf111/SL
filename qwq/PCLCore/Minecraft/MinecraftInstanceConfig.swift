//
//  MinecraftInstanceConfig.swift
//  PCL.Mac
//
//  实例配置的读写与类型定义（从 MinecraftInstance.swift 逐字搬移，逻辑与文案未变）：
//  - MinecraftInstance.loadConfig / saveConfig：.PCL_Mac.json 的读写
//  - MinecraftConfig：配置模型与 CodingKeys（javaURLString 沿用旧字段名 javaURL）
//  - ClientBrand：加载器品牌枚举与显示名
//  - QualityOfService 的 Codable 追溯一致性（供 MinecraftConfig 编解码）
//

import Foundation
import SwiftyJSON

extension MinecraftInstance {
    public func loadConfig() throws {
        // readToEnd 可能返回 nil（空/损坏配置文件），强解包会崩；失败时抛错让调用方用默认配置
        let fh = try FileHandle(forReadingFrom: configPath)
        defer { try? fh.close() }
        guard let data = try fh.readToEnd() else {
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
}

public struct MinecraftConfig: Codable {
    /// 死代码标注：全库无引用，待清理（勿删，保留以兼容既有 .PCL_Mac.json 字段）。
    ///
    /// 现状：只有写入方——本类型的 CodingKeys 与 `init(_ json:)` 自编解码，读取方为零，
    /// 即外部配置实际无法追加支持库，功能未接线。
    ///
    /// 标注形式说明：该属性在本文件内仍有活引用（解码赋值处），改为
    /// `@available(*, deprecated, message:)` 会在该处引入一条弃用告警，且「已弃用」与
    /// 其真实状态（有写入、无读取）不符，故以本注释作为等价标注。
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
}

extension QualityOfService: @retroactive Codable { }
