//
//  GameVersionFilter.swift
//  模块化拆分：版本清单按子分类过滤纯逻辑。
//  消除 GameViews.fetchMinecraftVersions 与 ModDetailView.fetchManifestVersions 两处相同的
//  release/snapshot/ancient 过滤 switch（石山融合重构：重复逻辑合并为共享模块）。
//  零状态零副作用。
//

import Foundation

enum GameVersionFilter {
    /// 按子分类过滤 Mojang 版本清单，返回 id 列表：
    /// - release：所有 type == "release" 的版本（含 1.7.x、1.8、1.12.2 等老版本）
    /// - snapshot：标准快照 + 未列出的 pending（combat/实验快照），排除愚人节版本（归远古版）
    /// - ancient：old_alpha/old_beta + 愚人节版本（参考 PCL.Mac）
    /// - none：空
    static func filteredIDs(_ versions: [[String: Any]], subCategory: GameSubCategory?) -> [String] {
        switch subCategory {
        case .release:
            return versions.filter { ($0["type"] as? String) == "release" }
                .compactMap { $0["id"] as? String }
        case .snapshot:
            return versions.filter { v in
                let t = v["type"] as? String ?? ""
                let id = v["id"] as? String ?? ""
                return (t == "snapshot" || t == "pending") && !GameVersionHelper.isAprilFoolVersion(id: id, type: t)
            }.compactMap { $0["id"] as? String }
        case .ancient:
            return versions.filter {
                let t = $0["type"] as? String ?? ""
                let id = $0["id"] as? String ?? ""
                return t == "old_alpha" || t == "old_beta" || GameVersionHelper.isAprilFoolVersion(id: id, type: t)
            }.compactMap { $0["id"] as? String }
        case .none:
            return []
        }
    }
}
