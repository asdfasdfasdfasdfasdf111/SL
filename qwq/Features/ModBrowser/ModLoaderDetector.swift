//
//  ModLoaderDetector.swift
//  从本地 .jar 里判断它属于哪个模组加载器（纯函数，无状态）。
//
//  判据：加载器的特征**清单文件**是否存在于 jar 内。各加载器的标志文件：
//  Quilt = quilt.mod.json、Fabric = fabric.mod.json、
//  NeoForge = meta-inf/neoforge.mods.toml、Forge = meta-inf/mods.toml、Rift = mod.json。
//
//  ⚠️ **判断顺序不可调换**（这一点没有编译期保护，改动前务必读这里）：
//  - Quilt 排在 Fabric 之前：Quilt 模组通常**同时**包含 `fabric.mod.json`（兼容 Fabric 生态），
//    先判 Fabric 会把 Quilt 模组误判成 Fabric。
//  - NeoForge 排在 Forge 之前：NeoForge 的 `neoforge.mods.toml` 与 Forge 的 `mods.toml`
//    在路径形态上是不同文件名，但 NeoForge 包也可能带上旧式 `mods.toml` 作为兼容层。
//  换言之，这里是一串「更具体的特征优先」的判定，不是无关的顺序。
//
//  实现方式与代价（调用方需要注意的**性能事实**）：
//  - 通过 `/usr/bin/unzip -l` **列出 jar 条目**来判断，即每次都真的起一个子进程；
//  - `ProcessPool.execute` 是**同步**接口，默认超时 10s；而本工程的
//    `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 意味着未标注 nonisolated 的同步函数
//    **跑在主线程**上。因此本函数被调用的次数 = 主线程被阻塞的次数。
//  - 现有唯一调用点是 `GameDirectoryScanner.scanLocalLoaderMap`，它在打开模组 / 光影 /
//    资源包详情页时于主线程跑，最多遍历 10 个版本 × 每版本 3 个 jar，
//    即**单次开页最多 30 次同步子进程调用**。这是该页面首帧卡顿的主要来源。
//    缓解手段：把扫描移到后台（显式 nonisolated + Task.detached），或先按文件名/缓存过滤。
//
//  失败语义：文件不存在、unzip 不可用、超时、输出不可解析 —— 一律返回 `.unknown`。
//  也就是说 `.unknown` 同时代表「读懂了且不是这些加载器」与「根本没读成功」，
//  调用方无法区分。当前调用方（只想知道「这个版本用的哪个加载器」）可以接受这种合并；
//  若将来要据此给用户提示，需要拆分返回值。
//
//  现有调用点：`GameDirectoryScanner.swift:56`。
//

import Foundation

/// 本地模组 jar 的加载器探测（无状态，全部为静态方法）。
struct ModLoaderDetector {

    /// 探测给定 jar 所属的加载器；任何一步失败都返回 `.unknown`（语义见文件头）。
    static func detect(from url: URL) -> ModLoader {
        // 前置检查：文件必须存在，否则连 unzip 都不用起
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unknown
        }

        // 起子进程列出 jar 条目；失败（非 zip、超时、unzip 不可用）即放弃
        guard let entries = listJarEntries(at: url) else {
            return .unknown
        }

        // 统一转小写：zip 条目名在 ODF/规范上区分大小写，但各加载器写入时大小写不统一
        // （META-INF 目录常见大写），故比较前一律小写化
        let paths = entries.map { $0.lowercased() }

        // ⚠️ 以下顺序有意为之，不可调换 —— 原因见文件头
        if paths.contains(where: { $0 == "quilt.mod.json" }) {
            return .quilt
        }
        if paths.contains(where: { $0 == "fabric.mod.json" }) {
            return .fabric
        }
        if paths.contains(where: { $0 == "meta-inf/neoforge.mods.toml" }) {
            return .neoforge
        }
        if paths.contains(where: { $0 == "meta-inf/mods.toml" }) {
            return .forge
        }
        if paths.contains(where: { $0 == "mod.json" }) {
            return .rift
        }

        return .unknown
    }

    /// 用 `/usr/bin/unzip -l` 列出 jar 内条目名；子进程失败时返回 nil。
    ///
    /// 解析方式：`unzip -l` 输出是表头 + 一行行 `长度 日期 时间 名称`，末尾还有分隔线与汇总行。
    /// 这里**不按列位置解析**，而是每行取「以空白切分后的最后一段」当作条目名 ——
    /// 这样对表头（最后一列是 "Name"）、汇总行（最后一段是文件名或数量）都不会崩，
    /// 靠后续「必须与已知标志文件名精确相等」的比较把噪声排除掉。
    ///
    /// `private`：本函数的解析假设只服务于上面的 `detect`，不是通用的 zip 列表工具。
    private static func listJarEntries(at url: URL) -> [String]? {
        guard let output = AppContext.shared.processPool.execute(
            "/usr/bin/unzip", args: ["-l", url.path], timeout: 10
        ) else { return nil }

        var entries: [String] = []
        let lines = output.split(separator: "\n")
        for line in lines {
            let trimmed = String(line)
            // omittingEmptySubsequences 保证连续空格不会产生空字段，`parts.last` 即该行最后一个 token
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if let last = parts.last {
                let entry = String(last)
                // 过滤掉空串与表头/汇总行里可能出现的孤立 "/"
                if !entry.isEmpty && entry != "/" {
                    entries.append(entry)
                }
            }
        }
        return entries
    }
}