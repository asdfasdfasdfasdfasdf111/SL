//
//  GameVersionHelper.swift
//  模块化拆分：共享游戏版本工具（消除 ModDetailView / GameViews 中的重复实现）
//  版本比较 / 显示排序 / 愚人节版本判断
//

import Foundation

enum GameVersionHelper {

    /// 版本号比较（点分数字逐段比较，缺位按 0 补）：a > b 返回正数
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va - vb }
        }
        return 0
    }

    /// 显示用版本排序：降序排列；当前实例版本（selected）置顶
    static func sortForDisplay(_ versions: [String], selected: String) -> [String] {
        var sorted = versions.sorted { compare($0, $1) > 0 }
        if !selected.isEmpty, let idx = sorted.firstIndex(of: selected) {
            sorted.remove(at: idx)
            sorted.insert(selected, at: 0)
        }
        return sorted
    }

    // 愚人节版本列表（参考 PCL.Mac VersionManifest.swift）
    static let aprilFoolVersions: [String] = [
        "15w14a", "1.rv-pre1", "3d shareware v1.34", "20w14infinite",
        "22w13oneblockatatime", "23w13a_or_b", "24w14potato", "25w14craftmine"
    ]

    /// 判断是否为愚人节版本（参考 PCL.Mac isAprilFoolVersion）
    static func isAprilFoolVersion(id: String, type: String) -> Bool {
        let normalized = id.replacingOccurrences(of: "point", with: ".")
        if aprilFoolVersions.contains(normalized.lowercased()) { return true }
        guard type == "snapshot" else { return false }
        // 新版 Mojang 命名（2026 起）：快照为「主版本号-snapshot-N」如 26.3-snapshot-7，
        // 正式版为「主版本号」如 26.2，这些是正式内容，绝不能判为愚人节。
        let snapshotPattern = #"^[0-9][0-9]?(\.[0-9]+)?-snapshot-[0-9]+$"#
        if normalized.range(of: snapshotPattern, options: .regularExpression) != nil { return false }
        // 旧版标准快照格式（如 23w33a）：正式快照，非愚人节
        let oldSnapshotPattern = #"^[0-9]{2}w[0-9]{2}[a-z]$"#
        if normalized.range(of: oldSnapshotPattern, options: .regularExpression) != nil { return false }
        // 至少有一个字母（筛掉 1.x 与 1.x.x），且不是 -pre/-rc
        if normalized.rangeOfCharacter(from: .letters) == nil { return false }
        if normalized.contains("-pre") || normalized.contains("-rc") { return false }
        return true
    }
}
