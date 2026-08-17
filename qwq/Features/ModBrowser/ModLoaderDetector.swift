import Foundation

struct ModLoaderDetector {

    static func detect(from url: URL) -> ModLoader {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unknown
        }

        guard let entries = listJarEntries(at: url) else {
            return .unknown
        }

        let paths = entries.map { $0.lowercased() }

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

    private static func listJarEntries(at url: URL) -> [String]? {
        guard let output = AppContext.shared.processPool.execute(
            "/usr/bin/unzip", args: ["-l", url.path], timeout: 10
        ) else { return nil }

        var entries: [String] = []
        let lines = output.split(separator: "\n")
        for line in lines {
            let trimmed = String(line)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if let last = parts.last {
                let entry = String(last)
                if !entry.isEmpty && entry != "/" {
                    entries.append(entry)
                }
            }
        }
        return entries
    }
}