//
//  LoaderSupportVersionRules.swift
//  PCL.Mac
//
//  加载器候选与版本比较规则（从 LoaderSupportChecker.swift 逐字搬移，规则与常量未变）：
//  - versionAtLeast / isSnapshotVersion：MC 版本号形态与下限比较
//  - candidateDisplayNames：某版本应检测的候选加载器显示名（按版本剔除明确不可能的项）
//  - isFullyResolved：缓存是否已覆盖全部候选（全部定论则无需联网）
//  - orderIndex / displayName(for:)：显示名排序与反查
//

import Foundation

extension LoaderSupportChecker {

    /// 该版本应检测的候选加载器显示名（按 MC 版本剔除明确不可能的项）：
    /// - 远古版（< 1.0 且非快照，如 2point0_blue / old_alpha / old_beta）无任何加载器 → 不联网检测
    /// - Forge 从 1.1 起；Fabric / Quilt 从 1.14 起；NeoForge 从 1.20.1 起
    public static func candidateDisplayNames(for version: String) -> [String] {
        guard isSnapshotVersion(version) || versionAtLeast(version, min: "1.0") else { return [] }
        var names: [String] = []
        if versionAtLeast(version, min: "1.1") { names.append("Forge") }
        if versionAtLeast(version, min: "1.14") { names.append("Fabric"); names.append("Quilt") }
        if maySupportNeoForge(version) { names.append("NeoForged") }
        return names
    }

    /// 缓存是否已覆盖全部候选（无 missing / checking / unavailable 项）—— 全部定论则无需联网。
    /// 注意：`.checking` 是 UI 层未定论占位，绝不能视为「已定论」——
    /// 否则首次无缓存时 `fetchLoaderSupport` 会误判全定论并短路 return，卡片永远停在转圈。
    public static func isFullyResolved(_ states: [String: LoaderState], for version: String) -> Bool {
        for name in candidateDisplayNames(for: version) {
            switch states[name] {
            case .supported, .notSupported: continue
            default: return false   // nil / checking / unavailable 均未定论
            }
        }
        return true
    }

    // MARK: - 按 MC 版本剔除明确不可能的候选（减少无谓请求 + 避免误判）

    private static func maySupportNeoForge(_ version: String) -> Bool {
        if version.range(of: #"^\d{2}w\d{2}"#, options: .regularExpression) != nil { return false }
        return versionAtLeast(version, min: "1.20.1")
    }

    /// 访问级别为 internal：缓存层 TTL 规则与探测层的快照结论抑制均需调用。
    static func isSnapshotVersion(_ version: String) -> Bool {
        version.range(of: #"^\d{2}w\d{2}[a-z]?$"#, options: .regularExpression) != nil
    }

    /// 访问级别为 internal：缓存层 TTL 规则需调用。
    static func versionAtLeast(_ version: String, min: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").compactMap { Int($0) }
        }
        let a = parts(version), b = parts(min)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    /// 访问级别为 internal：缓存层与兼容聚合入口的排序均需调用。
    static func orderIndex(_ name: String) -> Int {
        loaderOrder.firstIndex(of: name) ?? 99
    }

    /// 端点 key → 显示名。注意：当前无调用方（`key(for:)` 只提供显示名→key 的正向映射），保留待清理。
    private static func displayName(for key: String) -> String {
        switch key {
        case "fabric": return "Fabric"
        case "forge": return "Forge"
        case "neoforge": return "NeoForged"
        case "quilt": return "Quilt"
        default: return key
        }
    }
}
