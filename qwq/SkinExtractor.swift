//
//  SkinExtractor.swift
//  模块化拆分：从游戏版本 JAR 提取默认皮肤（从 CategoryContentView.swift 拆出）
//  /usr/bin/unzip 提取 assets/minecraft/textures/entity/{steve,alex}.png
//

import Foundation

enum SkinExtractor {

    /// 从指定版本的客户端 JAR 提取默认皮肤（steve 优先，其次 alex），成功返回临时文件 URL
    static func extractFromGameJar(version: String, gameDir: URL) -> URL? {
        let jarURL = gameDir.appendingPathComponent("versions/\(version)/\(version).jar")
        guard FileManager.default.fileExists(atPath: jarURL.path) else { return nil }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        if let skinURL = extractSkinFile(from: jarURL, tempDir: tempDir, skinName: "steve") {
            return skinURL
        }
        if let skinURL = extractSkinFile(from: jarURL, tempDir: tempDir, skinName: "alex") {
            return skinURL
        }
        return nil
    }

    private static func extractSkinFile(from jarURL: URL, tempDir: URL, skinName: String) -> URL? {
        let result = AppContext.shared.processPool.execute(
            "/usr/bin/unzip",
            args: ["-j", jarURL.path, "assets/minecraft/textures/entity/\(skinName).png", "-d", tempDir.path],
            timeout: 10
        )
        guard result != nil else { return nil }
        let skinURL = tempDir.appendingPathComponent("\(skinName).png")
        if FileManager.default.fileExists(atPath: skinURL.path) {
            return skinURL
        }
        return nil
    }
}
