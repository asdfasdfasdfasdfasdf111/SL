import Foundation

// MARK: - 加载器名称解析（自 ModDetailView 拆出）
// 从版本字符串/加载器 key 映射到 UI 资源名（assetName）。

enum LoaderNameResolver {
    /// 加载器 key → 资源名（无回退；nil 表示未知 key）。
    /// 数据源**收口到 `ModLoader.assetName`**（enum case 是唯一事实源，见
    /// `ModLoaderTests` 的「assetName 不是单射」用例），这里只做字符串反查。
    /// `neoforged` 是历史版本后缀里出现过的别名（enum 无此 case），故补一行特例；
    /// 其余大小写不敏感地反查 enum，未知 key 返回 nil、由调用方决定回退。
    static func resolvedAssetName(for loader: String) -> String? {
        let key = loader.lowercased()
        if key == "neoforged" { return "NeoForged" }
        return ModLoader(rawValue: key)?.assetName
    }

    /// 加载器 key → 资源名（未知 key 回退 "fabric"，与 `ModLoader.unknown` 同口径）
    static func assetName(for loader: String) -> String {
        resolvedAssetName(for: loader) ?? "fabric"
    }

    /// 后缀词表：`ModLoader` 的全部 case（除 `unknown`）+ `neoforged` 别名。
    /// 语义等价于旧 `assetMap.keys`（fabric / forge / neoforge / neoforged / quilt / rift），
    /// 供「从版本 id 尾部识别加载器词」的调用方（如 `SkinHDSupport.SkinVersionIdentity`）复用，
    /// 避免再各维护一份加载器名单。
    static let loaderTokens: Set<String> = {
        var tokens = Set(ModLoader.allCases.map(\.rawValue))
        tokens.remove("unknown")
        tokens.insert("neoforged")
        return tokens
    }()

    /// 从版本字符串解析加载器资源名。
    /// 优先本地扫描结果（localLoaders），其次版本字符串后缀（如 "1.20.1-Forge"），
    /// 再子串模糊匹配，最后回退用户选择的加载器（fallback）。
    static func name(forVersion version: String, localLoaders: [String: ModLoader], fallback: String) -> String {
        // 优先从本地扫描结果获取
        if let detected = localLoaders[version] {
            return detected.assetName
        }
        // 从版本字符串后缀解析加载器（如 "1.20.1-Forge"、"26.3-snapshot-3-Fabric"）
        let lower = version.lowercased()
        let parts = lower.split(separator: "-")
        for part in parts.reversed() {
            let p = String(part).trimmingCharacters(in: .whitespaces)
            if let matched = resolvedAssetName(for: p) {
                return matched
            }
        }
        // 子串模糊匹配
        if lower.contains("neoforge") || lower.contains("neoforged") { return "NeoForged" }
        if lower.contains("forge") { return "Forge" }
        if lower.contains("quilt") { return "Quilt" }
        if lower.contains("fabric") { return "fabric" }
        if lower.contains("rift") { return "fabric" }
        // 回退：使用用户选择的 loader，而非硬编码版本
        return fallback.isEmpty ? "fabric" : fallback
    }
}
