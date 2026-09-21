//
//  GameVersionFilter.swift
//  模块化拆分：版本清单按子分类过滤（适配器）
//
//  过滤规则已收口到 Game 模块的 `VersionFilterUseCase`（Features/Game/Module/VersionFilterUseCase.swift），
//  本类型只做「`[[String: Any]]` → `MinecraftVersionInfo`」的形态转换，
//  避免分类列表（GameViews）与详情页（ModDetailView）各写一遍 switch 造成规则漂移。
//
//  `ModDetailView` 仍按原签名调用 `filteredIDs(_:subCategory:)`，输出与收口前逐条一致：
//  id 缺失的条目被丢弃、type 缺失等同未识别（不匹配任何分类）、顺序保持输入顺序。
//

import Foundation

enum GameVersionFilter {

    private static let useCase = VersionFilterUseCase()

    /// 按子分类过滤 Mojang 版本清单，返回 id 列表：
    /// - release：所有 type == "release" 的版本（含 1.7.x、1.8、1.12.2 等老版本）
    /// - snapshot：标准快照 + 未列出的 pending（combat/实验快照），排除愚人节版本（归远古版）
    /// - ancient：old_alpha/old_beta + 愚人节版本（参考 PCL.Mac）
    /// - none：空
    static func filteredIDs(_ versions: [[String: Any]], subCategory: GameSubCategory?) -> [String] {
        useCase.ids(versions.compactMap(MinecraftVersionInfo.init(manifestEntry:)), subCategory: subCategory)
    }
}
