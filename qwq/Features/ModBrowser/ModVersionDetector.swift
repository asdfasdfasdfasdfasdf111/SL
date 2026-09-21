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

        if gameTrimmed.hasPrefix(trimmed) && trimmed.contains(".") {
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

    private func compareVersions(_ a: String, _ b: String) -> Int {
        GameVersionHelper.compare(a, b).signum()
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

    private func readModsTOML(from jarURL: URL, entries: Set<String>?) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "META-INF/mods.toml", entries: entries) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        var inMinecraftDep = false
        // 该模式每一行都要用一次，提到循环外只编译一次：旧写法把 NSRegularExpression 建在逐行
        // 循环体内，minecraft 依赖块里的每一行都会重新编译同一个（已固定的）模式。
        // 依据：NSRegularExpression 是「编译后的正则」的不可变表示，构造即编译，成本与待匹配
        // 字符串无关；官方明确其不可变且线程安全，可安全复用同一实例。
        // 官方链接：https://developer.apple.com/documentation/foundation/nsregularexpression
        let minecraftModIdRegex = try? NSRegularExpression(
            pattern: #"#?modId\s*=\s*"minecraft""#,
            options: .caseInsensitive
        )

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[[dependencies.") && trimmed.contains("minecraft") {
                inMinecraftDep = true
                continue
            }
            if inMinecraftDep && trimmed.hasPrefix("[[dependencies.") {
                inMinecraftDep = false
                continue
            }
            // 匹配模式、选项与匹配范围（整行）均与旧实现一致，仅编译时机改变
            if inMinecraftDep,
               let match = minecraftModIdRegex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               match.numberOfRanges > 0 {
                for l in lines {
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("versionRange") || t.hasPrefix("#versionRange") {
                        if let range = extractTOMLValue(t, key: "versionRange") {
                            return ModVersionInfo(versionRange: range, loader: "forge")
                        }
                    }
                }
            }
        }

        let versionPattern = #"(?:#?\s*)versionRange\s*=\s*"([^"]*)""#
        if let regex = try? NSRegularExpression(pattern: versionPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            let versionStr = String(content[range])
            if versionStr.contains("minecraft") || !versionStr.isEmpty {
                for line in lines {
                    if line.contains("modId") && line.contains("minecraft") {
                        return ModVersionInfo(versionRange: versionStr, loader: "forge")
                    }
                }
                return ModVersionInfo(versionRange: versionStr, loader: "forge")
            }
        }

        return nil
    }

    private func extractTOMLValue(_ line: String, key: String) -> String? {
        let pattern = #"(?:#?\s*)"# + key + #"\s*=\s*"([^"]*)""#
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