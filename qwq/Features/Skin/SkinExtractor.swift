//
//  SkinExtractor.swift
//  模块化拆分：从游戏版本 JAR 提取默认皮肤（从 CategoryContentView.swift 拆出）
//  /usr/bin/unzip 提取 assets/minecraft/textures/entity/... 下的 steve/alex 皮肤
//

import Foundation

enum SkinExtractor {

    /// 从指定版本的客户端 JAR 提取默认皮肤（steve 优先，其次 alex）。
    /// 提取出的皮肤会复制到持久化目录，返回的 URL 指向该持久文件，不会随函数返回被删除。
    static func extractFromGameJar(version: String, gameDir: URL) -> URL? {
        let jarURL = gameDir.appendingPathComponent("versions/\(version)/\(version).jar")
        guard FileManager.default.fileExists(atPath: jarURL.path) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

        for path in candidatePaths {
            if let tempSkinURL = extractSkinFile(from: jarURL, tempDir: tempDir, archivePath: path) {
                return persistExtractedSkin(tempURL: tempSkinURL, version: version)
            }
        }
        return nil
    }

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
    private static func persistExtractedSkin(tempURL: URL, version: String) -> URL? {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
        try? fileManager.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let destURL = skinDir.appendingPathComponent("extracted_\(version).png")
        do {
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: tempURL, to: destURL)
            return destURL
        } catch {
            print("⚠️ 无法持久化提取的皮肤: \(error.localizedDescription)")
            return nil
        }
    }
}
