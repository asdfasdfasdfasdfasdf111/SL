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
    private static let renameLock = NSLock()

    /// 规范化版本文件夹名：把「文件夹名是纯版本号、但实际装了加载器」的版本目录
    /// 重命名为「版本号-加载器名」（如 1.6.1 → 1.6.1-Forge）。
    /// 原理（用户明确要求）：启动器列表直接读 versions/ 下的文件夹名展示，
    /// 改文件夹名即改列表显示；新下载流程（GameVersionDownloadStarter 拼 name）
    /// 已产出带后缀目录，本函数只兜底历史遗留/第三方启动器装的版本。
    /// 检测依据：版本目录内 <名>.json 的 libraries 依赖或 inheritsFrom 名称。
    /// 重命名时同步改写 version.json 的 id 字段（JSON 文件名也随目录改名）。
    /// - Returns: 旧名 → 新名 映射（本次实际发生的重命名）。
    @discardableResult
    static func normalizeVersionFolderNames(gameRoot: String) -> [String: String] {
        renameLock.lock()
        defer { renameLock.unlock() }
        let fm = FileManager.default
        let versionsPath = gameRoot + "/versions"
        guard let dirs = try? fm.contentsOfDirectory(atPath: versionsPath) else { return [:] }
        var renames: [String: String] = [:]
        for dir in dirs {
            // 名字已含已知加载器特征（大小写不敏感，如 1.20.1-Forge / 1.6.1-forge8.9.0.753）→ 跳过
            let lower = dir.lowercased()
            if lower.contains("forge") || lower.contains("fabric") || lower.contains("neoforge") || lower.contains("quilt") {
                continue
            }
            let dirPath = "\(versionsPath)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // 读 <名>.json 检测加载器（无 json 无法确认，保守跳过）
            let jsonPath = "\(versionsPath)/\(dir)/\(dir).json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loader = detectLoaderName(in: json) else { continue }

            let newName = "\(dir)-\(loader)"
            let newDirPath = "\(versionsPath)/\(newName)"
            // 目标已存在则跳过，绝不覆盖
            if fm.fileExists(atPath: newDirPath) { continue }

            // ① 写入新名 json（id 同步改为新名），② 删旧 json，③ 重命名目录
            var newJSON = json
            newJSON["id"] = newName
            guard let newData = try? JSONSerialization.data(withJSONObject: newJSON, options: [.prettyPrinted]),
                  (try? newData.write(to: URL(fileURLWithPath: "\(versionsPath)/\(dir)/\(newName).json"))) != nil else { continue }
            try? fm.removeItem(atPath: jsonPath)
            do {
                try fm.moveItem(atPath: dirPath, toPath: newDirPath)
                renames[dir] = newName
                log("版本文件夹重命名: \(dir) → \(newName)")
            } catch {
                // 重命名失败：恢复旧 json（否则目录内 json 名与目录名不一致，启动器无法识别）
                try? fm.moveItem(atPath: "\(versionsPath)/\(dir)/\(newName).json", toPath: jsonPath)
            }
        }
        return renames
    }

    /// 从版本 json 检测加载器名（返回展示名 Forge/Fabric/NeoForge/Quilt；检测不到返回 nil）。
    private static func detectLoaderName(in json: [String: Any]) -> String? {
        // ① libraries 依赖名（PCL2 同款识别：forge/fabric-loader/neoforge/quilt-loader）
        if let libs = json["libraries"] as? [[String: Any]] {
            for lib in libs {
                guard let name = lib["name"] as? String else { continue }
                let n = name.lowercased()
                if n.contains("net.minecraftforge:forge") { return "Forge" }
                if n.contains("net.fabricmc:fabric-loader") { return "Fabric" }
                if n.contains("net.neoforged:neoforge") { return "NeoForge" }
                if n.contains("org.quiltmc:quilt-loader") { return "Quilt" }
            }
        }
        // ② inheritsFrom（如 "1.20.1-forge36.2.39"，加载器版通常继承原版）
        if let inherits = (json["inheritsFrom"] as? String)?.lowercased() {
            if inherits.contains("forge") { return "Forge" }
            if inherits.contains("fabric") { return "Fabric" }
            if inherits.contains("neoforge") { return "NeoForge" }
            if inherits.contains("quilt") { return "Quilt" }
        }
        return nil
    }

    static func findGameRootDirectories() -> [String] {
        let cache = AppContext.shared.cacheManager
        // 统一缓存（内存 LRU + 磁盘，避免 UserDefaults 膨胀）；迁移期回退 UserDefaults 旧缓存一次后即清除
        if let cached = cache.object([String].self, forKey: cacheKey) {
            let valid = cached.filter { FileManager.default.fileExists(atPath: $0 + "/versions") }
            if !valid.isEmpty { return valid }
            cache.removeObject(forKey: cacheKey)
        } else if let legacy = UserDefaults.standard.stringArray(forKey: cacheKey) {
            let valid = legacy.filter { FileManager.default.fileExists(atPath: $0 + "/versions") }
            if !valid.isEmpty {
                cache.setObject(valid, forKey: cacheKey)
                UserDefaults.standard.removeObject(forKey: cacheKey)
                return valid
            }
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
        cache.setObject(roots, forKey: cacheKey)
        return roots
    }
    
    static func getVersions(from gameRoot: String) -> [String] {
        // 加载列表前先规范化文件夹名：历史遗留的「纯版本号但装了加载器」目录
        // 重命名为「版本-加载器」（1.6.1 → 1.6.1-Forge），列表读目录名即显示后缀。
        // 幂等：已带后缀 / 无加载器 / 重命名失败均自动跳过，重复调用无副作用。
        normalizeVersionFolderNames(gameRoot: gameRoot)
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