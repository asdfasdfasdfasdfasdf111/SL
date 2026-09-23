//
//  MinecraftInstanceConfig.swift
//  SL启动器
//
//  实例配置的读写与类型定义（从 MinecraftInstance.swift 逐字搬移，逻辑与文案未变）：
//  - MinecraftInstance.loadConfig / saveConfig：.SL.json 的读写
//  - MinecraftConfig：配置模型与 CodingKeys（javaURLString 沿用旧字段名 javaURL）
//  - ClientBrand：加载器品牌枚举与显示名
//  - QualityOfService 的 Codable 追溯一致性（供 MinecraftConfig 编解码）
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  每个版本实例在自己的目录下有一份 `.SL.json`，记录「这个实例该用哪个 Java、
//  给多少内存、跳不跳过资源校验」。本文件就是这份文件的模型与读写。
//
//  ── 两处非对称，改动时必须同时照顾 ───────────────────────────
//  **① 读用 SwiftyJSON、写用 JSONEncoder。** `loadConfig` 走 `MinecraftConfig.init(_ json:)`
//    （字段缺失/类型不符时各自给默认值，容错性强）；`saveConfig` 走 `Codable` + `CodingKeys`。
//    两边的键名必须靠 `CodingKeys` 保持一致 —— 特别是 `javaURLString` 映射到旧字段名
//    `"javaURL"`，改这里会让老配置文件读不出来（用户表现为「Java 选择被重置」）。
//  **② `javaURL` 是计算属性 + 存储字段的组合。** 对外是 `URL!`，落盘的是 `javaURLString`。
//    空串代表「未设置」。这样设计的原因是 `Codable` 不能直接编码 `URL` 的可选缺省语义，
//    用字符串更好控制。副作用是**赋值 nil 必须显式处理**（见 `javaURL` 的注释）。
//
//  ── 兼容性红线 ─────────────────────────────────────────────
//  `.SL.json` 是**用户磁盘上的既有数据**，字段只能加不能改语义。
//  例如 `additionalLibraries` 目前没有任何读取方，但仍然保留着（见该属性的注释）。
//

import Foundation
import SwiftyJSON

extension MinecraftInstance {
    /// 读取并应用本实例的配置。**配置文件不存在或为空会抛错**，
    /// 调用方（`MinecraftInstance.swift:97`）据此回落到默认配置。
    ///
    /// 注意这里**不做兼容性兜底**：抛错就意味着「整份配置用默认值」，
    /// 而默认值里 `javaURL` 是未设置、`maxMemory` 是 4096 —— 也就是用户之前选过的 Java 会丢。
    /// 所以只有在「确实读不出内容」时才抛（空文件、打不开）。
    public func loadConfig() throws {
        // readToEnd 可能返回 nil（空/损坏配置文件），强解包会崩；失败时抛错让调用方用默认配置
        let fh = try FileHandle(forReadingFrom: configPath)
        defer { try? fh.close() }
        guard let data = try fh.readToEnd() else {
            throw MyLocalizedError(reason: "配置文件为空: \(configPath.path)")
        }
        self.config = .init(try .init(data: data))
    }
    
    /// 把当前配置写回 `.SL.json`。**不会抛错**（失败只打日志）。
    ///
    /// 两个细节：
    /// - 先 `createDirectory` 再写：实例目录可能还不存在（新建实例后立刻保存配置的场景）；
    /// - `options: .atomic`：先写临时文件再原子替换，避免写到一半断电留下半份 JSON
    ///   —— 下一轮启动时那半份文件会解码失败，进而把用户配置全部丢掉。
    ///
    /// 调用点：`MinecraftInstance.swift:115`（实例初始化后）、
    /// `SLLaunchBridge.swift:282`（启动前写回解析好的 Java）、
    /// `MinecraftInstallerPostProcess.swift:127`、`FabricInstaller.swift:19`。
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

/// 一个版本实例的配置。落盘为实例目录下的 `.SL.json`。
///
/// 字段读写的非对称、以及 `javaURLString` 沿用旧键名这两点见文件头。
public struct MinecraftConfig: Codable {
    /// 死代码标注：全库无引用，待清理（勿删，保留以兼容既有 .SL.json 字段）。
    ///
    /// 现状：只有写入方——本类型的 CodingKeys 与 `init(_ json:)` 自编解码，读取方为零，
    /// 即外部配置实际无法追加支持库，功能未接线。
    ///
    /// 标注形式说明：该属性在本文件内仍有活引用（解码赋值处），改为
    /// `@available(*, deprecated, message:)` 会在该处引入一条弃用告警，且「已弃用」与
    /// 其真实状态（有写入、无读取）不符，故以本注释作为等价标注。
    public var additionalLibraries: Set<String> = []
    /// 本实例要用的 Java 可执行文件。**空串（即 `nil`）表示「没设置，请自动选」**。
    ///
    /// 对外是 `URL!`、对内存字符串：`Codable` 直接编解码可选 URL 的缺省语义不好控制，
    /// 换成一个「空串即未设置」的存储字段更直白（键名沿用历史的 `"javaURL"`）。
    ///
    /// **setter 里必须容忍 nil**：调用方会用它来「清掉已失效的缓存 Java」
    /// （`MinecraftInstanceJava.swift:38`）。旧实现写的是 `javaURLString = value.path` ——
    /// 对 `URL!` 取 `.path` 会隐式强解包，赋 nil 时**直接 fatalError 崩溃**
    /// （已用最小复现证实：`Fatal error: Unexpectedly found nil while implicitly
    /// unwrapping an Optional value`）。触发条件是「配置里缓存了 Java，
    /// 但它已失效或版本不够」—— 例如用户换了更高版本的游戏、或把原来的 JDK 删了。
    /// 现在写成 `value?.path ?? ""`，语义与原来一致（nil → 空串 → getter 返回 nil）。
    public var javaURL: URL! {
        get {
            return javaURLString == "" ? nil : URL(fileURLWithPath: javaURLString)
        }
        set (value) {
            javaURLString = value?.path ?? ""
        }
    }
    /// 启动前的资源校验开关。置真表示**跳过**资源完整性检查（更快，但缺资源会到游戏里才报错）。
    public var skipResourcesCheck: Bool = false
    /// JVM 最大堆（MB）。缺省 4096。
    /// 解码时若字段缺失或不是整数，同样回落 4096（`json[...].int32 ?? 4096`）。
    public var maxMemory: Int32 = 4096
    /// 进程调度质量等级，透传给系统。见文件末尾的 `QualityOfService` 追溯扩展。
    public var qualityOfService: QualityOfService = .default
    /// 本实例对应的 Minecraft 版本号。
    ///
    /// **注意是 `String!`**：`init(version:)` 传进来的可能已经是 nil（无版本的新实例），
    /// 此时读它**会崩**。取用前必须自己保证非空（或改用可选绑定）。
    public var minecraftVersion: String!
    
    /// 落盘的 Java 路径字符串。空串 = 未设置。**不要直接改它**，走 `javaURL`。
    private var javaURLString: String
    
    /// 持久化键名。注意 `javaURLString` 映射成 `"javaURL"`（历史键名）——
    /// 改这里会让已有 `.SL.json` 的 Java 设置读不出来。
    enum CodingKeys: String, CodingKey {
        case additionalLibraries
        case javaURLString = "javaURL"
        case skipResourcesCheck
        case maxMemory
        case qualityOfService
        case minecraftVersion
    }
    
    /// 从 `.SL.json` 的 JSON 构造。**每个字段都有兜底**，不会因为缺字段而失败。
    ///
    /// 两处特殊处理：
    /// - `qualityOfService`：`rawValue == 0` 时强制回落 `.default`。
    ///   因为老配置文件里这个字段可能是 0（未写入或陈旧枚举取值），
    ///   而 0 在系统语义里不是「默认」而是某个具体档位，直接采纳会让调度行为跑偏。
    /// - `javaURLString` 用 `json["javaURL"].stringValue`：字段缺失时得到空串，
    ///   正好等于「未设置」，所以不需要额外的 nil 分支。
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
    
    /// 为某个版本新建一份配置（未设置 Java，其余取默认值）。
    ///
    /// 注意 `version` 为 nil 时会写出 `minecraftVersion = nil` —— 而该字段是 `String!`，
    /// 见上面 `minecraftVersion` 的说明。
    public init(version: MinecraftVersion?) {
        self.minecraftVersion = version?.displayName
        self.javaURLString = ""
    }
}

/// 客户端品牌（原版 / 各加载器）。
///
/// `rawValue` 同时承担两个用途，改名会同时影响两处：
/// 1. **持久化**（`Codable`）：写进 `.SL.json` 或清单；
/// 2. **图标资源名**：`MinecraftInstance.getIconName()` 用
///    `"\(rawValue.capitalized)Icon"` 拼资源名（原版除外），
///    即 `"fabric"` → `FabricIcon`。所以改 rawValue 等于让图标找不到。
///
/// 注意 `.quilt` 目前**没有任何产生它的路径** —— `MinecraftInstanceVersion.getClientBrand`
/// 只判 `neoforged` / `fabric` / `forge` 三个关键字，没有 quilt 分支。
/// 保留该 case 是为了将来支持，不代表现在能识别出 Quilt 实例。
public enum ClientBrand: String, Codable, Hashable {
    case vanilla = "vanilla"
    case fabric = "fabric"
    case quilt = "quilt"
    case forge = "forge"
    case neoforge = "neoforge"
    
    /// 面向用户的品牌名。
    ///
    /// `neoforge` 要特判：`"neoforge".capitalized` 得到的是 `"Neoforge"`，
    /// 而产品上一直写作 **`NeoForge`**。其余几个（Fabric / Quilt / Forge / Vanilla）
    /// 首字母大写即可，所以只对 neoforge 单独处理。
    public func getName() -> String {
        if self == .neoforge {
            return "NeoForge"
        } else {
            return self.rawValue.capitalized
        }
    }
}

/// 给系统类型 `QualityOfService` 补 `Codable` 一致性。
///
/// `QualityOfService` 来自 Foundation，本身不满足 `Codable`，而 `MinecraftConfig`
/// 需要整体可编码（`saveConfig` 走 `JSONEncoder`），所以在这里补一段空实现
/// （按 `RawRepresentable` 的默认行为编码成整数）。
///
/// `@retroactive`：显式声明「我知道这是在给别的模块的类型加一致性」，
/// 用来消除相关的警告。**不要删这个标注**，否则编译告警会回归。
extension QualityOfService: @retroactive Codable { }
