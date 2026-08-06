import Foundation

/// 参考 PCL.Mac MinecraftInstance.getMinJavaVersion
/// 使用版本号比较而非字符串前缀匹配
func requiredJavaVersionForMinecraft(_ version: String) -> Int {
    let normalized = normalizeVersion(version)
    // 24w14a (1.21) 起需要 Java 21
    if normalized >= normalizeVersion("1.21") { return 21 }
    // 1.18-pre2 起需要 Java 17
    if normalized >= normalizeVersion("1.18") { return 17 }
    // 21w19a 起需要 Java 16
    if normalized >= normalizeVersion("1.17") { return 16 }
    return 8
}

/// 将版本号归一化用于比较：去掉快照前缀，补全为三段式版本号
private func normalizeVersion(_ version: String) -> String {
    var v = version.lowercased()
    // 去掉快照前缀如 "24w14a" 这类直接返回大版本映射
    if v.range(of: #"^\d{2}w\d{2}[a-z]$"#, options: .regularExpression) != nil {
        // 快照版本，根据年份估算
        if let yearStr = v.split(whereSeparator: { $0 == "w" }).first,
           let year = Int(yearStr), year >= 24 { return "1.21" }
        if let yearStr = v.split(whereSeparator: { $0 == "w" }).first,
           let year = Int(yearStr), year >= 23 { return "1.20" }
        return "1.19"
    }
    // 去掉 pre/rc 后缀
    if let range = v.range(of: "-pre") { v = String(v[..<range.lowerBound]) }
    if let range = v.range(of: "-rc") { v = String(v[..<range.lowerBound]) }
    // 补全为三段式
    let parts = v.split(separator: ".").map(String.init)
    if parts.count >= 3 { return v }
    if parts.count == 2 { return "\(v).0" }
    return "\(v).0.0"
}

struct MinecraftVersionManager {
    private static let cacheKey = "cachedGameRoots"
    
    static func findGameRootDirectories() -> [String] {
        if let cached = UserDefaults.standard.stringArray(forKey: cacheKey) {
            let valid = cached.filter { FileManager.default.fileExists(atPath: $0 + "/versions") }
            if !valid.isEmpty { return valid }
        }
        let home = NSHomeDirectory()
        let candidatePaths = [
            home, home + "/.minecraft", home + "/Library/Application Support/minecraft",
            home + "/Library/Application Support/hmcl/.minecraft", home + "/Documents",
            home + "/Documents/minecraft", home + "/Downloads", home + "/Downloads/minecraft",
            home + "/Desktop", home + "/Desktop/minecraft", "/Users/Shared/minecraft"
        ]
        var roots: [String] = []
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path + "/versions") { roots.append(path) }
        }
        let searchPaths = [home + "/Library/Application Support", home + "/Documents", home + "/Downloads"]
        for searchPath in searchPaths {
            if let output = AppContext.shared.processPool.execute(
                "/usr/bin/find",
                args: [searchPath, "-maxdepth", "3", "-type", "d", "-name", "versions", "-exec", "dirname", "{}", ";"],
                timeout: 10
            ) {
                output.enumerateLines { line, _ in
                    if FileManager.default.fileExists(atPath: line + "/versions"), !roots.contains(line) { roots.append(line) }
                }
            }
        }
        UserDefaults.standard.set(roots, forKey: cacheKey)
        return roots
    }
    
    static func getVersions(from gameRoot: String) -> [String] {
        let versionsPath = gameRoot + "/versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsPath) else { return [] }
        return versions.filter { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: "\(versionsPath)/\(path)", isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }
    
    static func findFirstValidGame() -> (root: String, versions: [String])? {
        for root in findGameRootDirectories() {
            let versions = getVersions(from: root)
            if !versions.isEmpty { return (root, versions) }
        }
        return nil
    }
    
    static func asyncFullDiskScanForGames() async -> [String] {
        return await Task.detached(priority: .userInitiated) {
            return findGameRootDirectories()
        }.value
    }
    
    static func asyncFindFirstValidGame() async -> (root: String, versions: [String])? {
        return await Task.detached(priority: .userInitiated) {
            return findFirstValidGame()
        }.value
    }
}