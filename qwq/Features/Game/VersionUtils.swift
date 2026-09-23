//
//  VersionUtils.swift
//  游戏目录发现 / 版本列表读取 / 版本目录名规范化，以及「某个 MC 版本需要哪个 Java」的入口。
//
//  ⚠️ 这里的职责其实横跨三层（Java 需求推导、磁盘扫描、目录名改写），
//  只是因为都服务于「游戏版本」这一屏才放在一起 —— 新增函数前先想想该落哪一层。
//

import Foundation

/// 参考 PCL.Mac MinecraftInstance.getMinJavaVersion
/// 统一委托 `JavaRequirement` 的权威推导（数字逐段比较 + 快照年份映射），
/// 不再自行用字符串字典序比较版本号——旧实现 "1.9.0" 字典序大于 "1.21.0"
/// （位置 3 的 '9' > '2'）会把 1.8/1.9 误判为需要 Java 21、把 1.20.5 误判为需要 Java 17。
/// 之所以保留这么一个薄封装：界面侧不必知道 `JavaRequirement` 的存在，
/// 将来更换推导实现时只需改这一处。
func requiredJavaVersionForMinecraft(_ version: String) -> Int {
    JavaRequirement.minimumMajor(forMinecraftVersion: version)
}

/// 游戏目录与版本列表的静态工具集（无实例、全部 static）。
/// 目录扫描结果带缓存；`normalizeVersionFolderNames` 会**改写磁盘**（见其文档）。
struct MinecraftVersionManager {
    /// 缓存键。历史上曾存在 UserDefaults 里，现已迁到 AppContext 的缓存管理器
    /// （迁移分支见 `findGameRootDirectories`）。
    private static let cacheKey = "cachedGameRoots"
    /// 串行化目录改名。该操作是「读 json → 写新 json → 删旧 json → 移动目录」多步组合，
    /// 不是原子的；用 NSLock 而不是 actor，是因为调用方可能已在主线程同步调用。
    private static let renameLock = NSLock()

    /// 规范化版本文件夹名：把「文件夹名是纯版本号、但实际装了加载器」的版本目录
    /// 重命名为「版本号-加载器名」（如 1.6.1 → 1.6.1-Forge）。
    /// 原理（用户明确要求）：启动器列表直接读 versions/ 下的文件夹名展示，
    /// 改文件夹名即改列表显示；新下载流程（GameVersionDownloadStarter 拼 name）
    /// 已产出带后缀目录，本函数只兜底历史遗留/第三方启动器装的版本。
    /// 检测依据：版本目录内 <名>.json 的 libraries 依赖或 inheritsFrom 名称。
    /// 重命名时同步改写 version.json 的 id 字段（JSON 文件名也随目录改名）。
    /// - Returns: 旧名 → 新名 映射（本次实际发生的重命名）。
    /// ⚠️ 这是本文件唯一会**写磁盘**的方法：既会重命名版本目录，也会改写目录内 json 的 id。
    /// ⚠️ 全程 `try?` 化：任何一步失败都只是「这个目录不改了」，不会中断整轮扫描。
    @discardableResult
    static func normalizeVersionFolderNames(gameRoot: String) -> [String: String] {
        renameLock.lock()
        defer { renameLock.unlock() }
        let fm = FileManager.default
        let versionsPath = gameRoot + "/versions"
        // versions/ 不存在（该 root 其实没有版本）时静默返回空表，不报错。
        guard let dirs = try? fm.contentsOfDirectory(atPath: versionsPath) else { return [:] }
        var renames: [String: String] = [:]
        for dir in dirs {
            // 名字已含已知加载器特征（大小写不敏感，如 1.20.1-Forge / 1.6.1-forge8.9.0.753）→ 跳过
            let lower = dir.lowercased()
            if lower.contains("forge") || lower.contains("fabric") || lower.contains("neoforge") || lower.contains("quilt") {
                continue
            }
            let dirPath = "\(versionsPath)/\(dir)"
            // 只处理目录：versions/ 下除了版本目录，还可能有散放的 json / 图标文件。
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // 读 <名>.json 检测加载器（无 json 无法确认，保守跳过）
            let jsonPath = "\(versionsPath)/\(dir)/\(dir).json"
            // 读不到 <目录名>.json 就无法确认加载器 —— 保守跳过，宁可不动这个目录。
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loader = detectLoaderName(in: json) else { continue }

            let newName = "\(dir)-\(loader)"
            let newDirPath = "\(versionsPath)/\(newName)"
            // 目标已存在则跳过，绝不覆盖
            if fm.fileExists(atPath: newDirPath) { continue }

            // ① 写入新名 json（id 同步改为新名），② 删旧 json，③ 重命名目录
            // id 必须与目录名同步改：启动器读的是 json 里的 id，
            // 两者不一致会导致这个版本无法被识别为有效实例。
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
                // 重命名失败：恢复旧 json（否则目录内 json 名与目录名不一致，启动器无法识别）。
                // 注意此刻磁盘状态是「目录名仍旧、json 已改成新名」，靠这一句回滚回一致状态。
                try? fm.moveItem(atPath: "\(versionsPath)/\(dir)/\(newName).json", toPath: jsonPath)
            }
        }
        return renames
    }

    /// 从版本 json 检测加载器名（返回展示名 Forge/Fabric/NeoForge/Quilt；检测不到返回 nil）。
    /// ⚠️ 判定顺序固定为 libraries → inheritsFrom；libraries 内部又按**数组顺序**先命中先返回 ——
    /// 一个 json 若同时含多种加载器痕迹（极少见），结果取决于数组顺序而非优先级。
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
        // ② 加载器版本的清单通常 inheritsFrom 原版，而自身 name 里带加载器标识。
        if let inherits = (json["inheritsFrom"] as? String)?.lowercased() {
            if inherits.contains("forge") { return "Forge" }
            if inherits.contains("fabric") { return "Fabric" }
            if inherits.contains("neoforge") { return "NeoForge" }
            if inherits.contains("quilt") { return "Quilt" }
        }
        return nil
    }

    /// 找出所有「含 versions/ 子目录」的游戏根目录。
    /// **可能很慢**：除十几个常见路径外，还会对 文稿 / 下载 / Application Support 三处
    /// 各跑一次 `find -maxdepth 3`（每次 10 秒超时）。结果会被缓存，所以正常只慢一次；
    /// 在界面路径上调用请改用异步版本（`asyncFullDiskScanForGames`）。
    static func findGameRootDirectories() -> [String] {
        let cache = AppContext.shared.cacheManager
        // 统一缓存（内存 LRU + 磁盘，避免 UserDefaults 膨胀）；迁移期回退 UserDefaults 旧缓存一次后即清除
        // 缓存命中也要再验一次存在性：缓存里的目录可能已被用户删掉/移走。
        if let cached = cache.object([String].self, forKey: cacheKey) {
            let valid = cached.filter { FileManager.default.fileExists(atPath: $0 + "/versions") }
            if !valid.isEmpty { return valid }
            cache.removeObject(forKey: cacheKey)
        // 迁移分支：老版本把结果存在 UserDefaults 里，这里读一次、搬到新缓存后即删除旧键。
        } else if let legacy = UserDefaults.standard.stringArray(forKey: cacheKey) {
            let valid = legacy.filter { FileManager.default.fileExists(atPath: $0 + "/versions") }
            if !valid.isEmpty {
                cache.setObject(valid, forKey: cacheKey)
                UserDefaults.standard.removeObject(forKey: cacheKey)
                return valid
            }
        }
        let home = NSHomeDirectory()
        // 常见位置清单：家目录、官方启动器目录、HMCL 的目录，以及三个用户常放游戏的位置。
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
        // 再对三个「最可能放游戏」的地方做一次深度 3 的查找；超过该深度就不找了（防卡顿）。
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
        // 连「空结果」也写进缓存 —— 否则每次进游戏页都要重跑三遍 find。
        cache.setObject(roots, forKey: cacheKey)
        return roots
    }
    
    /// 列出某个游戏根目录下的版本名（versions/ 下的**目录名**，字典序排序）。
    /// ⚠️ 调用它有**写副作用**：内部先跑一遍目录名规范化（见 normalizeVersionFolderNames）。
    /// 返回的是文件系统上的目录名，规范化会保证它与 json 里的 id 一致。
    static func getVersions(from gameRoot: String) -> [String] {
        // 加载列表前先规范化文件夹名：历史遗留的「纯版本号但装了加载器」目录
        // 重命名为「版本-加载器」（1.6.1 → 1.6.1-Forge），列表读目录名即显示后缀。
        // 幂等：已带后缀 / 无加载器 / 重命名失败均自动跳过，重复调用无副作用。
        normalizeVersionFolderNames(gameRoot: gameRoot)
        let versionsPath = gameRoot + "/versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsPath) else { return [] }
        // 只保留目录：versions/ 下还可能散落着 json、图标等文件。
        return versions.filter { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: "\(versionsPath)/\(path)", isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }
    
    /// 返回第一个「确实含有版本」的游戏根目录，用于「自动选一个能用的」场景。
    /// 所有候选都为空时返回 nil（不报错、不弹窗）。
    static func findFirstValidGame() -> (root: String, versions: [String])? {
        for root in findGameRootDirectories() {
            let versions = getVersions(from: root)
            if !versions.isEmpty { return (root, versions) }
        }
        return nil
    }
    
    /// 把全盘扫描挪到后台（`.userInitiated` 优先级）。
    /// ⚠️ 用 `Task.detached` 而非普通 Task：扫描是纯同步阻塞的重活，
    /// 不该继承调用方的 actor（尤其是主 actor）。
    static func asyncFullDiskScanForGames() async -> [String] {
        return await Task.detached(priority: .userInitiated) {
            return findGameRootDirectories()
        }.value
    }
    
    /// 同上：把「找第一个可用游戏」整体挪到后台
    ///（内含一次全盘扫描 + 每个候选一次目录名规范化，都是磁盘操作）。
    static func asyncFindFirstValidGame() async -> (root: String, versions: [String])? {
        return await Task.detached(priority: .userInitiated) {
            return findFirstValidGame()
        }.value
    }
}