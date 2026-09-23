//
//  MinecraftVersion.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/23.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  游戏版本号的**值语义建模**：一个版本 = 「显示名（如 1.21.8）+ 版本类型（正式版/快照/…）」，
//  外加一个可排序的时间轴（发布时间）。它是个轻量标识符，**不承载安装信息** ——
//  版本目录、jar 路径、加载器等一概不在这里（那属于 `MinecraftInstance` / `MinecraftDirectory`）。
//
//  ── 关键设计：排序为什么按发布时间而不是版本号字符串 ──────────
//  字符串排序会把 "1.9" 排在 "1.10" 之后（因为 '9' > '1'），版本列表会乱序。
//  所以 `<` 用 `releaseDate` 比较，跟人眼的「新旧」一致。
//
//  ── 维护提示 ───────────────────────────────────────────────
//  1. `releaseDate` 是**懒加载**的：首次访问才去 `VersionManifest` 反查。这意味着
//     在版本清单尚未加载时访问它，会得到 1970-01-01 这个兜底值（排在最前）。
//  2. `hash(into:)` 只用了 `displayName`，而 `==` 还要求 `type` 相同。这**不违反**
//     `Hashable` 契约（契约只要求「相等则哈希必相同」），但会让同名不同类的对象
//     落进同一个哈希桶 —— 属于有意的取舍，改 `==` 时别忘了这里。
//

import Foundation

/// 一个 Minecraft 游戏版本标识。
///
/// 现有构造点：`VersionManifest.swift:54`（由版本清单构造，带 type）、
/// `MinecraftInstanceVersion.swift:73`（由实例 json 的 `"id"` 构造，type 靠反查）、
/// `MinecraftInstance.swift:35-37`（三个 Java 版本阈值常量，显式传 `.snapshot`）。
public class MinecraftVersion: Comparable, Hashable {
    /// 面向用户的版本号原文，如 `"1.21.8"`、`"24w14a"`。也是唯一标识。
    public let displayName: String
    /// 版本类别。未显式传入时由 `VersionType.parse` 反查版本清单得到。
    public let type: VersionType
    /// 懒加载缓存。命中后不再重复查清单。
    private var _releaseDate: Date?
    /// 发布时间。首次访问会触发一次版本清单查询（见文件头「维护提示 1」）。
    public var releaseDate: Date {
        if _releaseDate == nil {
            _releaseDate = VersionManifest.getReleaseDate(self)
        }
        return _releaseDate ?? Date(timeIntervalSince1970: TimeInterval(0))
    }
    
    /// 只按 `displayName` 计算哈希 —— 见文件头「维护提示 2」。
    public func hash(into hasher: inout Hasher) {
        hasher.combine(displayName)
    }
    
    /// 构造一个版本标识。
    /// - Parameter type: 显式指定版本类型；传 `nil` 时会去版本清单里反查（清单未加载则回落 `.release`）。
    public init(displayName: String, type: VersionType? = nil) {
        self.displayName = displayName
        self.type = type ?? .parse(displayName)
    }
    
    /// 按发布时间比较 —— 这是版本列表排序的依据（理由见文件头）。
    public static func < (lhs: MinecraftVersion, rhs: MinecraftVersion) -> Bool {
        lhs.releaseDate < rhs.releaseDate
    }
    
    /// 显示名与类型都相同才算同一个版本。
    public static func == (lhs: MinecraftVersion, rhs: MinecraftVersion) -> Bool {
        lhs.displayName == rhs.displayName && lhs.type == rhs.type
    }
    
    /// 返回版本列表里用的图标资源名（对应 `Assets.xcassets` 中的图片集）。
    /// 快照与待发布共用一枚图标；未知类型兜底用正式版图标，避免出现空白图。
    public func getIconName() -> String {
        switch type {
        case .release: "ReleaseVersionIcon"
        case .snapshot, .pending: "SnapshotVersionIcon"
        case .beta, .alpha: "OldVersionIcon"
        case .aprilFool: "AprilFoolVersionIcon"
        default: "ReleaseVersionIcon"
        }
    }
}

/// 版本类别。`rawValue` 与官方版本清单里的 `"type"` 字段**逐字一致**，
/// 因此可以直接 `Codable` 解码清单而无需映射表。
///
/// 注意 `rawValue` 用的是下划线/连字符（`"pre-release"` / `"old_beta"` / `"april_fool"`），
/// 不要顺手「规范化」成驼峰 —— 会直接导致清单解析失败。
///
/// `Core/Minecraft/Module/MinecraftInstanceInfo.swift` 里的 `MinecraftVersionKind`
/// 是本枚举的镜像（取值字符串完全相同、可互转），两处改动要同步。
public enum VersionType: String, Codable {
    case release = "release"
    case snapshot = "snapshot"
    case prerelease = "pre-release"
    case rc = "rc"
    case alpha = "old_alpha"
    case beta = "old_beta"
    case aprilFool = "april_fool"
    case pending = "pending"
    
    /// 由版本号字符串反查版本类型。
    ///
    /// 两种回落都会返回 `.release`（这是保守选择：正式版图标一定存在）：
    /// - 版本清单还没加载 —— 这属于**时序错误**，会打一条要求上报的日志
    ///   （正常流程里清单应当先就绪，见到这条日志说明启动顺序被改坏了）；
    /// - 清单里查不到这个版本号（例如用户手输了一个不存在的版本）—— 静默回落。
    public static func parse(_ displayVersion: String) -> VersionType {
        guard let manifest = DataManager.shared.versionManifest else {
            err("版本清单加载时机错误，请将此问题报告给开发者")
            return .release
        }
        
        guard let version = manifest.versions.first(where: { $0.id == displayVersion }) else {
            return .release
        }
        
        return version.type
    }
}
