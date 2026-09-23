import Foundation

/// 模组加载器枚举（ModDownloader 搜索过滤 / 详情页加载器解析 / 本地加载器检测共享）。
/// 按「一个文件一个顶层声明」原则拆自 ModDownloader.swift；纯搬移零行为变更。
/// ⚠️ rawValue 是**小写**的（`"neoforge"`），而 `assetName` 里有大小写混排
///（`"NeoForged"`）—— 两者用途不同：rawValue 用于与 Modrinth 接口对齐，
/// assetName 用于找本地图片资源，别把其中一个当另一个用。
public enum ModLoader: String, CaseIterable {
    case fabric, forge, quilt, neoforge, rift, unknown
}

extension ModLoader {
    /// UI 上的显示名（如 `NeoForge`）。
    /// ⚠️ 这是 internal（无 `public`）—— 跨模块不可见；本工程是单 target，暂时够用。
    var displayName: String {
        switch self {
        case .fabric: return "Fabric"
        case .forge: return "Forge"
        case .quilt: return "Quilt"
        case .neoforge: return "NeoForge"
        case .rift: return "Rift"
        case .unknown: return "Unknown"
        }
    }

    /// 本地图片资源名。
    /// ⚠️ 两处刻意的不一致，**不能**用 assetName 反推加载器类型：
    ///   `rift`    → "fabric"：Rift 已停止维护，没有独立图标，借 Fabric 的用；
    ///   `unknown` → "fabric"：同样没有图标，只是回落成一个中性图形。
    var assetName: String {
        switch self {
        case .fabric: return "fabric"
        case .forge: return "Forge"
        case .quilt: return "Quilt"
        case .neoforge: return "NeoForged"
        case .rift: return "fabric"
        case .unknown: return "fabric"
        }
    }
}
