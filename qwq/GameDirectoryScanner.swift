//
//  GameDirectoryScanner.swift
//  模块化拆分：本地游戏目录扫描（从 ModDetailView.swift 拆出）
//  已安装版本 / 版本内 mods 加载器探测 / 光影文件夹检测
//

import Foundation

enum GameDirectoryScanner {

    /// 读取本地游戏根目录 versions 文件夹，返回本地实际安装的有效版本列表。
    /// 有效版本 = 目录中存在同名 .jar 或 .json 文件。
    /// 注意：这里只做「本地拥有」判断，不做任何加载器/兼容性过滤，
    /// 模组兼容性过滤由 ModDetailView 结合 API 的 game_versions 求交集完成。
    static func localOwnedVersions(gameRoot: String) -> [String] {
        guard !gameRoot.isEmpty else { return [] }
        let versionsPath = gameRoot + "/versions"
        guard let versionDirs = try? FileManager.default.contentsOfDirectory(atPath: versionsPath) else { return [] }
        return versionDirs.filter { dir in
            let jarPath = "\(versionsPath)/\(dir)/\(dir).jar"
            let jsonPath = "\(versionsPath)/\(dir)/\(dir).json"
            return FileManager.default.fileExists(atPath: jarPath) || FileManager.default.fileExists(atPath: jsonPath)
        }
    }

    /// 扫描本地前若干版本的 mods 文件夹，探测每个版本使用的加载器（任一 mod 的 jar 命中即记录）。
    /// 返回「版本 → 加载器」映射；每个版本最多探测 limitPerVersion 个 mod 文件。
    static func scanLocalLoaderMap(gameRoot: String, limitVersions: Int = 10, limitPerVersion: Int = 3) -> [String: ModLoader] {
        guard !gameRoot.isEmpty else { return [:] }
        let versionsPath = gameRoot + "/versions"
        guard let versionDirs = try? FileManager.default.contentsOfDirectory(atPath: versionsPath) else { return [:] }
        var result: [String: ModLoader] = [:]
        for versionDir in versionDirs.prefix(limitVersions) {
            let modsPath = "\(versionsPath)/\(versionDir)/mods"
            guard let modFiles = try? FileManager.default.contentsOfDirectory(atPath: modsPath) else { continue }
            var scannedCount = 0
            for modFile in modFiles where modFile.hasSuffix(".jar") {
                guard scannedCount < limitPerVersion else { break }
                let jarURL = URL(fileURLWithPath: "\(modsPath)/\(modFile)")
                let loader = ModLoaderDetector.detect(from: jarURL)
                if loader != .unknown {
                    result[versionDir] = loader
                    break
                }
                scannedCount += 1
            }
        }
        return result
    }

    /// 检测游戏根目录是否存在光影文件夹（优先版本内 shaderpacks，其次全局 shaderpacks）。
    static func hasShaderFolder(gameRoot: String, versions: [String]) -> Bool {
        guard !gameRoot.isEmpty else { return false }
        for version in versions {
            let shaderPath = "\(gameRoot)/versions/\(version)/shaderpacks"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: shaderPath, isDirectory: &isDir), isDir.boolValue {
                return true
            }
        }
        let globalShaderPath = "\(gameRoot)/shaderpacks"
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: globalShaderPath, isDirectory: &isDir) && isDir.boolValue
    }
}
