//
//  ModDragInstaller.swift
//  模块化拆分：从 ContentView.swift 拆出（原 findMatchingInstances / installModToInstances）
//  纯逻辑：拖拽安装模组的实例匹配与拷贝安装——扫描全部游戏根目录 + 用户选择根目录，
//  按模组版本范围过滤出匹配实例；把模组文件拷贝到每个实例的 versions/<v>/mods。
//  无视图依赖（不持有 @State、不弹窗），弹窗提示由调用方负责。
//

import Foundation

/// 拖拽安装模组的纯逻辑（实例匹配 + 文件拷贝）
enum ModDragInstaller {
    /// 在所有游戏根目录（含用户选择的根目录）中查找匹配模组版本范围的实例
    static func findInstances(for versionRange: String, savedRoot: String) -> [GameInstance] {
        let roots = MinecraftVersionManager.findGameRootDirectories()
        var seen = Set<String>()
        var instances: [GameInstance] = []

        func appendMatching(from root: String) {
            let normalized = (root as NSString).standardizingPath
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)
            let versions = MinecraftVersionManager.getVersions(from: normalized)
            for version in versions {
                if ModVersionDetector().versionMatches(modVersion: versionRange, gameVersion: version) {
                    instances.append(GameInstance(rootPath: normalized, version: version))
                }
            }
        }

        for root in roots {
            appendMatching(from: root)
        }

        if !savedRoot.isEmpty {
            appendMatching(from: savedRoot)
        }

        return instances
    }

    /// 把模组文件拷贝到所有匹配实例的 versions/<version>/mods 目录（同名覆盖）
    /// - Returns: 成功安装的实例数
    @discardableResult
    static func install(modURL: URL, to instances: [GameInstance]) -> Int {
        let modFileName = modURL.lastPathComponent
        var successCount = 0
        for instance in instances {
            // 游戏启动时 gameDir = <rootPath>/versions/<version>，mods 在版本文件夹内
            let modsDir = URL(fileURLWithPath: instance.rootPath).appendingPathComponent("versions/\(instance.version)/mods")
            do {
                try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
                let destURL = modsDir.appendingPathComponent(modFileName)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: modURL, to: destURL)
                successCount += 1
            } catch {
                print("安装模组到 \(instance.rootPath) 失败: \(error.localizedDescription)")
            }
        }
        return successCount
    }
}
