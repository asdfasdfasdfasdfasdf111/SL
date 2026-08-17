import Foundation

/// 模组加载器枚举（ModDownloader 搜索过滤 / 详情页加载器解析 / 本地加载器检测共享）。
/// 按「一个文件一个顶层声明」原则拆自 ModDownloader.swift；纯搬移零行为变更。
public enum ModLoader: String, CaseIterable {
    case fabric, forge, quilt, neoforge, rift, unknown
}

extension ModLoader {
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
