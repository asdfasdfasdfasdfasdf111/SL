import Foundation

// MARK: - 整合包版本分组（自 ModDetailView 拆出）
// 把整合包多版本列表按 game_versions 去重分组，每组取第一个版本，按版本号降序。

enum ModpackVersionGrouping {
    /// 按游戏版本去重：返回 (游戏版本, 该组的第一个 ModpackVersion)，降序排列。
    static func uniqueGameVersions(_ versions: [ModpackVersion]) -> [(gameVersion: String, version: ModpackVersion)] {
        var seen: Set<String> = []
        var result: [(String, ModpackVersion)] = []
        for v in versions {
            if let gv = v.game_versions.first, !seen.contains(gv) {
                seen.insert(gv)
                result.append((gv, v))
            }
        }
        return result.sorted(by: { a, b in
            GameVersionHelper.compare(a.0, b.0) > 0
        })
    }
}
