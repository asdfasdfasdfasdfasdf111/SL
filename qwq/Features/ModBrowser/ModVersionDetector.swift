import Foundation

class ModVersionDetector {

    struct ModVersionInfo {
        let versionRange: String
        let loader: String?
    }

    func detectVersion(from jarURL: URL) -> ModVersionInfo? {
        if let info = readFabricModJSON(from: jarURL) {
            return info
        }
        if let info = readQuiltModJSON(from: jarURL) {
            return info
        }
        if let info = readModsTOML(from: jarURL) {
            return info
        }
        if let info = readMcmodInfo(from: jarURL) {
            return info
        }
        if let version = readManifestVersion(from: jarURL) {
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
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal < bVal { return -1 }
            if aVal > bVal { return 1 }
        }
        return 0
    }

    // MARK: - JAR 内容读取（使用 ProcessPool）

    private func readFileFromJar(jarURL: URL, entryName: String) -> Data? {
        return AppContext.shared.processPool.executeForData(
            "/usr/bin/unzip", args: ["-p", jarURL.path, entryName], timeout: 10
        )
    }

    private func readFabricModJSON(from jarURL: URL) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "fabric.mod.json") else { return nil }
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

    private func readQuiltModJSON(from jarURL: URL) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "quilt.mod.json") else { return nil }
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

    private func readModsTOML(from jarURL: URL) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "META-INF/mods.toml") else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        var inMinecraftDep = false

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
            if inMinecraftDep {
                let regex = try? NSRegularExpression(
                    pattern: #"#?modId\s*=\s*"minecraft""#,
                    options: .caseInsensitive
                )
                if let match = regex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)), match.numberOfRanges > 0 {
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

    private func readMcmodInfo(from jarURL: URL) -> ModVersionInfo? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "mcmod.info") else { return nil }
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

    private func readManifestVersion(from jarURL: URL) -> String? {
        guard let data = readFileFromJar(jarURL: jarURL, entryName: "META-INF/MANIFEST.MF") else { return nil }
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