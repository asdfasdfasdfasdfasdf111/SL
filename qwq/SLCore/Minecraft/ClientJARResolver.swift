//
//  ClientJARResolver.swift
//  解析实例**实际可用的客户端 JAR 路径**。
//
//  背景（真实故障）：加载器实例（Forge / Fabric / NeoForge…）的版本目录里常常**只有清单**，
//  客户端本体留在它 `inheritsFrom` 指向的原版版本目录里。旧逻辑一律按
//  `<实例目录>/<实例名>.jar` 取路径，于是这类实例会被误判成「客户端 JAR 缺失」而拒绝启动
//  （用户实测：`26.2-Forge` 自身无 jar、父版本 `26.2` 有 jar）；
//  即使放行，classpath 也会指向不存在的文件 —— JVM 对不存在的 classpath 条目**静默忽略**，
//  直到进游戏才以 ClassNotFoundException 崩溃，届时只能看到「异常退出」。
//
//  因此把「有效 JAR」的解析收敛到这一处，校验与 classpath 共用同一口径。
//

import Foundation

enum ClientJARResolver {
    /// 向上查找的层数上限：防止清单互相引用（A inheritsFrom B、B inheritsFrom A）导致死循环。
    private static let maxDepth = 8

    /// 解析有效客户端 JAR。
    /// - Returns: 存在的 JAR 路径；自身与父链都找不到时返回 nil（调用方据此报告缺失）。
    static func resolve(runningDirectory: URL, name: String, versionsRoot: URL) -> URL? {
        let own = runningDirectory.appendingPathComponent("\(name).jar")
        if FileManager.default.fileExists(atPath: own.path) { return own }

        var currentDir = runningDirectory
        var currentName = name
        for _ in 0..<maxDepth {
            guard let parent = inheritsFrom(in: currentDir, name: currentName) else { return nil }
            let parentDir = versionsRoot.appendingPathComponent(parent)
            let jar = parentDir.appendingPathComponent("\(parent).jar")
            if FileManager.default.fileExists(atPath: jar.path) { return jar }
            currentDir = parentDir
            currentName = parent
        }
        return nil
    }

    /// 读版本目录里的 `<name>.json`，取 `inheritsFrom`（无则 nil）。
    private static func inheritsFrom(in dir: URL, name: String) -> String? {
        let json = dir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: json),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["inheritsFrom"] as? String
    }
}
