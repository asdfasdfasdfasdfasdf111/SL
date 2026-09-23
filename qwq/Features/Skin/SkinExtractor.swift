//
//  SkinExtractor.swift
//  模块化拆分：从游戏版本 JAR 提取默认皮肤（从 CategoryContentView.swift 拆出）
//  /usr/bin/unzip 提取 assets/minecraft/textures/entity/... 下的 steve/alex 皮肤
//

import Foundation

/// 从游戏客户端 JAR 里提取默认皮肤（用户没设皮肤时用它做头像）。
/// 走 `/usr/bin/unzip -j`（`-j` 表示**剥掉目录层级**、只落文件名），因此候选路径里
/// 不同目录下的同名文件（`.../wide/steve.png` 与 `.../entity/steve.png`）在临时目录里
/// 会互相覆盖 —— 但因为是「按顺序取到就返回」，实际不会冲突。
enum SkinExtractor {

    /// 从指定版本的客户端 JAR 提取默认皮肤（steve 优先，其次 alex）。
    /// 提取出的皮肤会复制到持久化目录，返回的 URL 指向该持久文件，不会随函数返回被删除。
    /// 按候选路径依次尝试，**取到第一个就返回**（steve 优先于 alex、wide 优先于 slim）。
    /// 全部失败返回 nil（不抛错）—— 调用方据此回落到内置皮肤。
    /// 返回的 URL 指向**持久化目录**里的文件，不会随临时目录清理而失效（见 persistExtractedSkin）。
    static func extractFromGameJar(version: String, gameDir: URL) -> URL? {
        let jarURL = gameDir.appendingPathComponent("versions/\(version)/\(version).jar")
        guard FileManager.default.fileExists(atPath: jarURL.path) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 临时目录用完即删（defer 保证异常路径也清理）—— 这也是下一步必须把结果复制到
        // 持久化目录的原因，否则返回的 URL 会指向一个刚被删掉的文件。
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 新版（1.17+）皮肤在 player/{wide,slim}/ 下；旧版在 entity/ 下。
        let candidatePaths = [
            "assets/minecraft/textures/entity/player/wide/steve.png",
            "assets/minecraft/textures/entity/player/wide/alex.png",
            "assets/minecraft/textures/entity/player/slim/steve.png",
            "assets/minecraft/textures/entity/player/slim/alex.png",
            "assets/minecraft/textures/entity/steve.png",
            "assets/minecraft/textures/entity/alex.png"
        ]

        // 顺序即优先级：wide（经典 4px 手臂）排在 slim（Alex 3px 手臂）之前。
        for path in candidatePaths {
            if let tempSkinURL = extractSkinFile(from: jarURL, tempDir: tempDir, archivePath: path) {
                return persistExtractedSkin(tempURL: tempSkinURL, version: version)
            }
        }
        return nil
    }

    /// 用 unzip 从 JAR 里单独抽一个条目到临时目录。
    /// ⚠️ `-j` 剥掉目录层级，所以落盘文件名只有 `steve.png` / `alex.png` ——
    /// 下面按 `lastPathComponent` 拼路径就是依赖这个行为。
    /// 退出码非 0（条目不存在）时 `execute` 返回 nil，此处直接回落。
    private static func extractSkinFile(from jarURL: URL, tempDir: URL, archivePath: String) -> URL? {
        let result = AppContext.shared.processPool.execute(
            "/usr/bin/unzip",
            args: ["-j", jarURL.path, archivePath, "-d", tempDir.path],
            timeout: 10
        )
        guard result != nil else { return nil }
        let fileName = (archivePath as NSString).lastPathComponent
        let skinURL = tempDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: skinURL.path) {
            return skinURL
        }
        return nil
    }

    /// 把临时目录中的提取结果复制到持久化目录，避免返回的 URL 在 defer 中被删除后悬空。
    /// 目标文件名按版本号命名（`extracted_<版本>.png`）—— 同一版本重复提取会**覆盖**，
    /// 不同版本各留一份、互不影响。
    private static func persistExtractedSkin(tempURL: URL, version: String) -> URL? {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
        try? fileManager.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let destURL = skinDir.appendingPathComponent("extracted_\(version).png")
        do {
            // ⚠️ 必须先删再 copy：`copyItem` 遇到已存在的目标会**抛错**，而不是覆盖。
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: tempURL, to: destURL)
            return destURL
        } catch {
            LogManager.err("无法持久化提取的皮肤: \(error.localizedDescription)")
            return nil
        }
    }
}
