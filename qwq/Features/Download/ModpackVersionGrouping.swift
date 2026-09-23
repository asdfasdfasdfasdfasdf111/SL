import Foundation

// MARK: - 整合包版本分组（自 ModDetailView 拆出）
// 把整合包的多版本列表按「游戏版本」去重：每个游戏版本只保留**第一次出现**的那个包版本。
//
// ⚠️ 两条与上面这句话字面不完全一致的事实（以代码为准）：
//   1. 只用 `game_versions.first` 当键 —— 一个包版本若声明了多个游戏版本，
//      除第一个之外的版本**不会**单独出现在结果里；
//   2. 「降序」是交给 `GameVersionHelper.compare` 判定的，**不是字符串比较** ——
//      所以 1.10 会正确地排在 1.9 之后（字符串排序会排反）。

/// 纯函数工具：无状态、除 GameVersionHelper 外无依赖，便于单测与复用。
enum ModpackVersionGrouping {
    /// 按游戏版本去重：返回 (游戏版本, 该组的第一个 ModpackVersion)，降序排列。
    static func uniqueGameVersions(_ versions: [ModpackVersion]) -> [(gameVersion: String, version: ModpackVersion)] {
        // ⚠️ 返回的是**视图而非副本**：结果里的 ModpackVersion 与入参是同一批对象引用，
        // 改动它们会反映到原列表上（本类型不复制、不深拷贝）。
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
