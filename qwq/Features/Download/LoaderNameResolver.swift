import Foundation

// MARK: - 加载器名称解析（自 ModDetailView 拆出）
// 从版本字符串/加载器 key 映射到 UI 资源名（assetName）。

enum LoaderNameResolver {
    /// 加载器 key → 资源名映射（UI 图标/文案用）
    static let assetMap: [String: String] = [
        "fabric": "fabric", "forge": "Forge", "neoforge": "NeoForged",
        "neoforged": "NeoForged", "quilt": "Quilt", "rift": "fabric"
    ]

    /// 加载器 key → 资源名（未知 key 回退 "fabric"）
    static func assetName(for loader: String) -> String {
        assetMap[loader.lowercased()] ?? "fabric"
    }

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
            if let matched = assetMap[p] {
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
