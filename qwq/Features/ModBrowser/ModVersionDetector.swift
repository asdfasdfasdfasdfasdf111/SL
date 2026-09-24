//
//  ModVersionDetector.swift
//  从模组 jar 内部元数据反查「这个 mod 支持哪个游戏版本区间、属于哪个加载器」。
//
//  职责：① 列出 jar 条目（`unzip -Z1`）；② 按加载器优先级读元数据
//        （`fabric.mod.json` / `quilt.mod.json` / `mods.toml` / `mcmod.info` / `MANIFEST.MF`）；
//        ③ 解析版本区间（含 maven 风格 `[1.20,1.21)`）并判断是否覆盖给定游戏版本。
//  边界：**只读 jar**，不修改、不下载、不安装（下载与落盘分别属 Downloader / Installer）。
//  性能约束（改之前必读）：`Process` 实例只能 `run()` 一次，**「尝试次数」就是「进程创建次数」**。
//        旧实现按 fabric → quilt → forge → mcmod → manifest 顺序逐条试 `unzip -p`，
//        「条目不存在」也要完整启停一次 unzip 才能得到结论，全部未命中要创建 5 个进程；
//        现在先列一次条目清单、再由清单决定提取哪些条目，进程数最坏值由 5 降到 2。
//        **新增元数据来源时不要再加"试一次看看"的分支**，要走清单判断。
//

import Foundation

class ModVersionDetector {

    struct ModVersionInfo {
        let versionRange: String
        let loader: String?
    }

    func detectVersion(from jarURL: URL) -> ModVersionInfo? {
        // 条目清单只取一次：旧实现按 fabric → quilt → forge → mcmod → manifest 顺序逐条尝试
        // `unzip -p`，每个「不存在」的条目都要完整启停一次 unzip 才能得到「没有」的结论，
        // 单个 jar 最坏创建 5 个 Process（全部未命中时必然是 5 个）。
        // 现在先用 `unzip -Z1` 列一次条目名，再由清单决定哪些条目才需要提取：
        // 有命中时进程数固定为 2，全部未命中时为 1，最坏值由 5 降到 2。
        // 依据：《Process》—— 一个 Process 实例只能 run 一次，每次执行命令都要新建实例，
        // 因此「尝试次数」即「进程创建次数」，减少尝试次数即直接减少进程创建。
        // 官方链接：https://developer.apple.com/documentation/foundation/process
        let entries = listJarEntries(jarURL: jarURL)

        if let info = readFabricModJSON(from: jarURL, entries: entries) {
            return info
        }
        if let info = readQuiltModJSON(from: jarURL, entries: entries) {
            return info
        }
        if let info = readModsTOML(from: jarURL, entries: entries) {
            return info
        }
        if let info = readMcmodInfo(from: jarURL, entries: entries) {
            return info
        }
        if let version = readManifestVersion(from: jarURL, entries: entries) {
            return ModVersionInfo(versionRange: version, loader: nil)
        }
        return nil
    }

    func versionMatches(modVersion: String, gameVersion: String) -> Bool {
        let trimmed = modVersion.trimmingCharacters(in: .whitespaces)
        let gameTrimmed = gameVersion.trimmingCharacters(in: .whitespaces)

        if trimmed == gameTrimmed {
            return true
        }

        // 版本段边界前缀匹配：模组声明 `1.20` 时，实例 `1.20.1` 也算兼容；
        // 但声明 `1.1` 不得匹配 `1.10.2` —— 旧实现用 `gameTrimmed.hasPrefix(trimmed)` 做字符级前缀，
        // `1.10.2` 以 `1.1` 开头即被判为兼容，模组因此被装进不兼容的实例。
        // 故要求前缀之后紧跟版本段分隔符 `.`，即「多出的部分是一个完整版本段」。
        // （实例目录名带加载器后缀如 `1.20.1-Forge` 的情形由下方「主次版本相同」分支覆盖。）
        if trimmed.contains(".") && gameTrimmed.hasPrefix(trimmed + ".") {
            return true
        }

        if trimmed.hasPrefix(">=") {
            let minVer = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return compareVersions(gameTrimmed, minVer) >= 0
        }
        if trimmed.hasPrefix(">") {
            let minVer = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            return compareVersions(gameTrimmed, minVer) > 0
        }
        if trimmed.hasPrefix("<=") {
            let maxVer = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return compareVersions(gameTrimmed, maxVer) <= 0
        }
        if trimmed.hasPrefix("<") {
            let maxVer = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            return compareVersions(gameTrimmed, maxVer) < 0
        }
        // Maven 区间写法：Forge 的 mods.toml `versionRange`（如 `[1.20.1,1.21)`、`[1.14.4]`）
        // 用的就是该语法，检出后即按它定论。缺失这一步时，第 2 条修好之后的区间字符串
        // 仍会被下面的分支判为不匹配，拖拽安装依旧恒失败。
        if let bracketResult = mavenRangeResult(trimmed, gameVersion: gameTrimmed) {
            return bracketResult
        }
        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-", maxSplits: 1)
            if parts.count == 2 {
                let minVer = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let maxVer = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return compareVersions(gameTrimmed, minVer) >= 0 && compareVersions(gameTrimmed, maxVer) <= 0
            }
        }

        let modParts = trimmed.split(separator: ".").compactMap { Int($0) }
        let gameParts = gameTrimmed.split(separator: ".").compactMap { Int($0) }
        if modParts.count >= 2 && gameParts.count >= 2 && modParts[0] == gameParts[0] && modParts[1] == gameParts[1] {
            return true
        }

        return false
    }

    /// Maven 版本区间的区间判定。
    /// - Returns: `nil` 表示该字符串不是 Maven 区间写法（由调用方的其余分支处理）；
    ///   否则给出「游戏版本是否落在该区间内」的定论。
    ///
    /// 语法（含闭开括号语义）：`[a,b]` 闭区间、`[a,b)` / `(a,b]` 半开区间、
    /// `[a,)` / `(,b]` 单边区间、`[a]` 精确版本。a 为空表示不设下限，b 为空表示不设上限。
    /// 依据：Forge 官方文档「Mod Files」明确 “All version ranges use the Maven Version Range
    /// Specification.” https://docs.minecraftforge.net/en/1.20.1/gettingstarted/modfiles/
    /// 语法定义见 Maven 官方「Dependency Version Requirement Specification」
    /// https://maven.apache.org/enforcer/enforcer-rules/versionRanges.html
    private func mavenRangeResult(_ range: String, gameVersion: String) -> Bool? {
        guard range.count >= 3,
              let open = range.first, open == "[" || open == "(",
              let close = range.last, close == "]" || close == ")" else { return nil }
        let parts = range.dropFirst().dropLast()
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // `[a]`：精确版本
        if parts.count == 1 {
            guard !parts[0].isEmpty else { return nil }
            return compareVersions(gameVersion, parts[0]) == 0
        }
        let lower = parts[0], upper = parts[1]
        if !lower.isEmpty {
            let c = compareVersions(gameVersion, lower)
            if open == "[" ? c < 0 : c <= 0 { return false }
        }
        if !upper.isEmpty {
            let c = compareVersions(gameVersion, upper)
            if close == "]" ? c > 0 : c >= 0 { return false }
        }
        return true
    }

    private func compareVersions(_ a: String, _ b: String) -> Int {
        // 复用加载器候选判定同一口径（LoaderSupportChecker.versionCompare）：按版本号基数比较，
        // 忽略 `-preN` / `-rcN` 后缀。原实现用 GameVersionHelper.compare —— 它以 compactMap
        // 丢弃非数字段，`1.21-pre1` 退化为 [1] 而低于 `1.20.1`，预发布 / 候选版的区间判定因此错位。
        // 依据：SemVer 2.0.0（预发布低于对应正式版，主/次/补丁按数值比较）https://semver.org/
        // 与 Minecraft Wiki「Java Edition version history」（`1.21-pre1` / `1.21.4-rc1` 形态）
        // https://minecraft.wiki/w/Java_Edition_version_history
        return LoaderSupportChecker.versionCompare(a, b)
    }

    // MARK: - JAR 内容读取（使用 ProcessPool）

    /// 一次性列出 jar 内全部条目名。
    ///
    /// 使用 `unzip -Z1`（zipinfo 单列模式）：仅输出条目名，每行一个，不带表头与摘要，
    /// 可直接按行切分，无需解析表格化输出。
    /// - Returns: 条目名集合；返回 `nil` 表示清单不可得（jar 非 zip / 已损坏 / 进程失败 /
    ///   条目名不是合法 UTF-8）。调用方据此退回逐条提取，保证失败路径与旧实现一致。
    private func listJarEntries(jarURL: URL) -> Set<String>? {
        guard let output = AppContext.shared.processPool.execute(
            "/usr/bin/unzip", args: ["-Z1", jarURL.path], timeout: 10
        ) else { return nil }
        let names = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return Set(names.filter { !$0.isEmpty })
    }

    /// 读取 jar 内指定条目内容。
    ///
    /// `entries` 非空时，条目不在清单里即直接返回 `nil`，省去一次必然失败的 `unzip -p`；
    /// `entries` 为 `nil`（清单不可得）时不做预判，行为与旧实现完全一致。
    private func readFileFromJar(jarURL: URL, entryName: String, entries: Set<String>?) -> Data? {
        if let entries, !entries.contains(entryName) { return nil }
        return AppContext.shared.processPool.executeForData(
            "/usr/bin/unzip", args: ["-p", jarURL.path, entryName], timeout: 10
        )
    }

    private func readFabricModJSON(from jarURL: URL, entries: Set<String>?) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "fabric.mod.json", entries: entries) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let depends = json["depends"] as? [String: Any],
              let minecraftDep = depends["minecraft"] as? String else {
            if let depends = json["depends"] as? [String: String],
               let minecraftDep = depends["minecraft"] {
                return ModVersionInfo(versionRange: minecraftDep, loader: "fabric")
            }
            return nil
        }
        return ModVersionInfo(versionRange: minecraftDep, loader: "fabric")
    }

    private func readQuiltModJSON(from jarURL: URL, entries: Set<String>?) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "quilt.mod.json", entries: entries) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let minecraft = json["minecraft"] as? [String: Any],
           let depends = minecraft["depends"] as? [[String: Any]] {
            for dep in depends {
                if let id = dep["id"] as? String, id == "minecraft",
                   let versions = dep["versions"] as? String {
                    return ModVersionInfo(versionRange: versions, loader: "quilt")
                }
            }
        }
        if let quiltLoader = json["quilt_loader"] as? [String: Any],
           let depends = quiltLoader["depends"] as? [[String: Any]] {
            for dep in depends {
                if let id = dep["id"] as? String, id == "minecraft",
                   let versions = dep["versions"] as? String {
                    return ModVersionInfo(versionRange: versions, loader: "quilt")
                }
            }
        }
        return nil
    }

    /// 读取 META-INF/mods.toml 中「Minecraft 依赖」的版本区间（Forge / NeoForge 模组）。
    ///
    /// TOML 结构依据（Forge 官方文档「Mod Files」的 Dependency Configurations 一节）：
    /// 依赖以**数组表**声明，表头为 `[[dependencies.<声明方自己的 modId>]]` ——
    /// 表头里写的是**本模组自己**的 modId（示例即 `[[dependencies.examplemod]]`），
    /// 因此表头中永远不含被依赖方的名字；被依赖的模组由块内 `modId` 字段指明
    /// （如 `modId="forge"` / `modId="minecraft"`），块内 `versionRange` 才是该依赖的
    /// Maven 版本区间（`[1.20.1,1.21)` 这类）。
    /// 官方链接：https://docs.minecraftforge.net/en/1.20.1/gettingstarted/modfiles/
    /// 另见 1.14.x 同节（`[[dependencies.examplemod]] modId="minecraft" versionRange="[1.14.4]"`）：
    /// https://docs.minecraftforge.net/en/1.14.x/gettingstarted/structuring/
    ///
    /// 旧实现的两处错误即源于忽略该结构：
    /// ① 按行匹配 `[[dependencies.` 且要求该行含字面 "minecraft" —— 表头不含它，分支永不命中；
    /// ② 回退分支取「文件里第一个 versionRange」—— 那通常是 `modId="forge"` 的加载器区间，
    ///    于是把 Forge 加载器版本当成所需游戏版本，拖拽安装恒报「未找到匹配的游戏版本」。
    /// 现按块处理：切出依赖块 → 块内找 `modId == "minecraft"` → 取**同一块内**的 `versionRange`。
    private func readModsTOML(from jarURL: URL, entries: Set<String>?) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "META-INF/mods.toml", entries: entries) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        for block in tomlBlocks(in: content) where block.key.hasPrefix("dependencies.") {
            var modId: String?
            var versionRange: String?
            for line in block.body {
                // 注释不是数据（TOML 中 `#` 起为注释）：跳过，避免把模板里注释掉的示例读成真实依赖
                if modId == nil, let value = extractTOMLString(line, key: "modId") { modId = value }
                if versionRange == nil, let value = extractTOMLString(line, key: "versionRange") { versionRange = value }
            }
            // 键值对顺序在 TOML 中无约束，故先收齐整块再判定；versionRange 缺失或为空表示「匹配任意版本」，
            // 无法据此判定游戏版本，继续找下一个依赖块
            guard modId?.lowercased() == "minecraft", let versionRange, !versionRange.isEmpty else { continue }
            return ModVersionInfo(versionRange: versionRange, loader: "forge")
        }
        return nil
    }

    /// 按 TOML 表头切块：表头行开启新块，其余行归入当前块；首个表头之前的文件头属性丢弃。
    /// - Returns: `(表头键名, 该块的正文行)`；表头键名即 `[[a.b]]` / `[a.b]` 中的 `a.b`
    private func tomlBlocks(in content: String) -> [(key: String, body: [String])] {
        var blocks: [(key: String, body: [String])] = []
        var currentKey: String?
        var currentBody: [String] = []

        func flushCurrentBlock() {
            if let currentKey { blocks.append((currentKey, currentBody)) }
            currentBody = []
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#"), let key = tableHeaderKey(trimmed) {
                flushCurrentBlock()
                currentKey = key
            } else if currentKey != nil {
                currentBody.append(line)
            }
        }
        flushCurrentBlock()
        return blocks
    }

    /// 解析 TOML 表头行，返回表头内的键名；非表头返回 nil。
    /// 兼容三种现实写法：`[[dependencies.examplemod]]`、带引号的点分键
    /// `[[dependencies."my-mod"]]`（模板常见）、以及行尾注释 `[[dependencies.examplemod]] # optional`。
    private func tableHeaderKey(_ trimmedLine: String) -> String? {
        // TOML 允许表头后跟行尾注释，先剥掉注释部分再判形
        let line = trimmedLine.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        var key = line[...]
        while key.hasPrefix("[") { key = key.dropFirst() }
        while key.hasSuffix("]") { key = key.dropLast() }
        let name = key.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 取一行 TOML 键值对中的字符串值（键须在行首，值须为双引号字符串）。
    /// 与旧实现相比去掉了对 `#` 前缀键的容忍：注释掉的行不该被当成依赖数据。
    private func extractTOMLString(_ line: String, key: String) -> String? {
        let pattern = #"^\s*"# + key + #"\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private func readMcmodInfo(from jarURL: URL, entries: Set<String>?) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "mcmod.info", entries: entries) else { return nil }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let items: [[String: Any]]
        if let array = jsonObject as? [[String: Any]] {
            items = array
        } else if let dict = jsonObject as? [String: Any] {
            if let modList = dict["modList"] as? [[String: Any]] {
                items = modList
            } else {
                items = [dict]
            }
        } else {
            return nil
        }

        for item in items {
            if let mcVersion = item["mcversion"] as? String, !mcVersion.isEmpty {
                return ModVersionInfo(versionRange: mcVersion, loader: "forge")
            }
            if let version = item["version"] as? String,
               version.contains(".") && version.first?.isNumber == true {
                return ModVersionInfo(versionRange: version, loader: "forge")
            }
        }
        return nil
    }

    private func readManifestVersion(from jarURL: URL, entries: Set<String>?) -> String? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "META-INF/MANIFEST.MF", entries: entries) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("Implementation-Version:") {
                let version = line.replacingOccurrences(of: "Implementation-Version:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !version.isEmpty {
                    return version
                }
            }
        }
        return nil
    }
}