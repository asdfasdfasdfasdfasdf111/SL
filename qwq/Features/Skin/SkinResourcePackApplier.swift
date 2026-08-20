import Foundation

// MARK: - 离线皮肤资源包方案（PCL2 移植，自 MinecraftSkinManager 拆出）
// 生成 `resourcepacks/SL 皮肤.zip` 并注入 options.txt 的 resourcePacks。
// 资源包内同时写入 1.19.3+ 的 `entity/player/{slim,wide}/{9 默认皮肤}.png` 与旧版
// `entity/{steve,alex}.png`，全版本生效；不修改 JAR、不依赖 authlib-injector。

enum SkinResourcePackApplier {
    /// PCL2 离线皮肤资源包名（与 options.txt 的 resourcePacks 引用一致）
    static let packFileName = "SL 皮肤.zip"

    /// 生成皮肤资源包并注入 options.txt，幂等：同一版本 + 同一皮肤文件只处理一次
    /// （以 settings.appliedSkinHash 判断，避免反复重建 zip）。
    static func apply(skinURL: URL, toVersion version: String, gameDir: URL, settings: LauncherSettings) throws {
        let fileManager = FileManager.default
        // 幂等：同一版本 + 同一皮肤文件只处理一次
        let skinHash = (try? Util.sha1OfFile(url: skinURL)) ?? "unknown"
        let currentHash = "pack_\(version)_\(skinHash)"
        if settings.appliedSkinHash == currentHash {
            NSLog("皮肤资源包未变化，跳过")
            return
        }

        let resourcePacksDir = gameDir.appendingPathComponent("resourcepacks", isDirectory: true)
        try fileManager.createDirectory(at: resourcePacksDir, withIntermediateDirectories: true)
        let zipURL = resourcePacksDir.appendingPathComponent(packFileName)

        // 1) 组织临时目录：pack.mcmeta + assets 皮肤文件
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: tempDir) }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // pack.mcmeta：pack_format 版本自适应——现代版本（1.21+）从 jar 内 version.json 动态读
        // pack_version.resource_major（26.2 实测 88）；老版本（无该字段）回落 pack_format 1
        // （旧格式仍被老版本接受，但新版本会报 "Removed ... no longer compatible" 并拒绝加载）
        let packVersion = SkinResourcePackApplier.packPackVersion(for: gameDir.appendingPathComponent("\(version).jar"))
        let mcmetaURL = tempDir.appendingPathComponent("pack.mcmeta")
        // 25w31a+（resource pack >= 65）格式改用必填 min_format/max_format；此时旧字段
        // pack_format/supported_formats "not allowed and must be removed"（写了判 no longer compatible，26.2 实测）。
        // <25w31a 的版本不认新字段，回落 pack_format
        let mcmeta: String
        if let packVersion, packVersion.major >= 65 {
            mcmeta = #"{"pack":{"description":"SL 启动器 自定义离线皮肤资源包","min_format":[\#(packVersion.major),\#(packVersion.minor)],"max_format":[\#(packVersion.major),\#(packVersion.minor)]}}"#
        } else {
            mcmeta = #"{"pack":{"pack_format":\#(packVersion?.major ?? 1),"description":"SL 启动器 自定义离线皮肤资源包"}}"#
        }
        try mcmeta.write(to: mcmetaURL, atomically: true, encoding: .utf8)

        // 皮肤写入所有可能被加载的默认皮肤路径（wide + slim 双模型 + 旧版顶层路径）
        let defaultNames = ["alex", "ari", "efe", "kai", "makena", "noor", "steve", "sunny", "zuri"]
        func putSkin(relativePath: String) throws {
            let dest = tempDir.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: skinURL, to: dest)
        }
        for model in ["wide", "slim"] {
            for name in defaultNames {
                try putSkin(relativePath: "assets/minecraft/textures/entity/player/\(model)/\(name).png")
            }
        }
        try putSkin(relativePath: "assets/minecraft/textures/entity/steve.png")
        try putSkin(relativePath: "assets/minecraft/textures/entity/alex.png")

        // 2) 打包为 zip（先删旧包保证重建，避免残留旧条目；临时目录下执行保证 zip 内路径相对）
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        try runCommand("/usr/bin/zip", arguments: ["-rq", zipURL.path, "pack.mcmeta", "assets"], currentDirectory: tempDir)

        // 3) 注入 options.txt 的 resourcePacks（PCL2 逻辑：去重后追加到末尾 = 最高优先级）
        try updateOptionsResourcePacks(gameDir: gameDir, addPack: packFileName)

        settings.appliedSkinHash = currentHash
    }

    /// 移除皮肤资源包：删除 zip 并从 options.txt 的 resourcePacks 摘除
    static func remove(gameDir: URL) throws {
        let zipURL = gameDir.appendingPathComponent("resourcepacks").appendingPathComponent(packFileName)
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try updateOptionsResourcePacks(gameDir: gameDir, removePack: packFileName)
    }

    /// 修改 options.txt 的 resourcePacks：追加（最高优先级）或移除指定资源包。
    /// options.txt 为 INI 风格（key:value），resourcePacks 值为 JSON 数组字符串。
    private static func updateOptionsResourcePacks(gameDir: URL, addPack: String? = nil, removePack: String? = nil) throws {
        let fileManager = FileManager.default
        let optionsURL = gameDir.appendingPathComponent("options.txt")
        var content = ""
        if fileManager.fileExists(atPath: optionsURL.path) {
            content = (try String(contentsOf: optionsURL, encoding: .utf8))
        }

        var packs: [String] = []
        // 解析现有 resourcePacks（宽松解析：取出方括号内的逗号分隔元素）
        if let range = content.range(of: "resourcePacks:"),
           let open = content.range(of: "[", range: range.upperBound..<content.endIndex),
           let close = content.range(of: "]", range: open.upperBound..<content.endIndex) {
            let inner = String(content[open.upperBound..<close.lowerBound])
            packs = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        let packRefs = [addPack, removePack].compactMap { $0 }
        packs.removeAll { p in
            let trimmed = p.replacingOccurrences(of: "\"", with: "")
            return packRefs.contains(trimmed)
        }
        // 追加"vanilla"打底（PCL2 行为），再 append 皮肤包 → 列表末尾优先级最高
        if packs.isEmpty { packs.append("\"vanilla\"") }
        if let addPack {
            packs.append("\"file/\(addPack)\"")
        }
        let newValue = "[" + packs.joined(separator: ",") + "]"

        // 替换或追加 resourcePacks 行
        if let lineRange = content.range(of: "resourcePacks:[^\n]*", options: .regularExpression) {
            content.replaceSubrange(lineRange, with: "resourcePacks:\(newValue)")
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            content += "resourcePacks:\(newValue)\n"
        }
        try content.write(to: optionsURL, atomically: true, encoding: .utf8)
        NSLog("options.txt resourcePacks 已更新: \(newValue)")
    }

    /// 读取版本 jar 内 version.json 的 pack_version（resource_major/minor）。
    /// 老版本 client jar 无 version.json 或该字段，返回 nil → 调用方回落 pack_format 1
    private static func packPackVersion(for versionJar: URL) -> (major: Int, minor: Int)? {
        guard FileManager.default.fileExists(atPath: versionJar.path) else { return nil }
        guard let out = AppContext.shared.processPool.execute(
            "/usr/bin/unzip", args: ["-p", versionJar.path, "version.json"],
            timeout: 10, captureStderr: true
        ),
        let data = out.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let pv = obj["pack_version"] as? [String: Any],
        let major = pv["resource_major"] as? Int else { return nil }
        let minor = pv["resource_minor"] as? Int ?? 0
        return (major, minor)
    }

    /// 执行命令（使用 ProcessPool）
    private static func runCommand(_ command: String, arguments: [String], currentDirectory: URL? = nil) throws {
        let result = AppContext.shared.processPool.execute(
            command, args: arguments, timeout: 15, captureStderr: true,
            currentDirectory: currentDirectory
        )
        guard result != nil else {
            throw LauncherError.jarModificationFailed("命令执行失败")
        }
    }
}
