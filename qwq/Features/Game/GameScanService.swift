//
//  GameScanService.swift
//  模块化拆分：从 GameCategoryView 提炼「游戏根目录扫描」纯逻辑。
//  零状态零副作用（除磁盘扫描本身）：已保存根目录优先 → 全盘兜底；全盘扫描取第一个有效游戏。
//

import Foundation

enum GameScanService {
    /// 已保存根目录优先，其次全盘查找第一个有效游戏目录。
    /// 返回 (root, versions)；找不到返回 nil。
    static func resolveGameRoot(savedRoot: String) async -> (root: String, versions: [String])? {
        if !savedRoot.isEmpty, FileManager.default.fileExists(atPath: savedRoot + "/versions") {
            let versions = MinecraftVersionManager.getVersions(from: savedRoot)
            if !versions.isEmpty { return (savedRoot, versions) }
        }
        return await MinecraftVersionManager.asyncFindFirstValidGame()
    }

    /// 全盘扫描所有游戏目录：返回总数与第一个有效游戏（root + 版本列表）。
    static func fullDiskScanGames() async -> (count: Int, first: (root: String, versions: [String])?) {
        let roots = await MinecraftVersionManager.asyncFullDiskScanForGames()
        guard let firstRoot = roots.first else { return (roots.count, nil) }
        let versions = MinecraftVersionManager.getVersions(from: firstRoot)
        guard !versions.isEmpty else { return (roots.count, nil) }
        return (roots.count, (firstRoot, versions))
    }
}
