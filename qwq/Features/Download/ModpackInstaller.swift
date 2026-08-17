import Foundation

class ModpackInstaller {

    struct Manifest {
        let minecraftVersion: String
        let loader: String
        let loaderVersion: String
        let mods: [ModInfo]
    }

    struct ModInfo {
        let name: String
        let downloadURL: URL?
    }

    func install(packURL: URL, to instanceDir: URL) async throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try unzip(packURL, to: tempDir)

        let manifest = try parseManifest(in: tempDir)

        let versionsDir = instanceDir.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        try await installMinecraft(version: manifest.minecraftVersion, to: instanceDir)

        try await installLoader(manifest.loader, version: manifest.loaderVersion, minecraftVersion: manifest.minecraftVersion, to: instanceDir)

        let modsDir = instanceDir.appendingPathComponent("mods")
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        for mod in manifest.mods {
            try await downloadMod(mod, to: modsDir)
        }

        let overrides = tempDir.appendingPathComponent("overrides")
        if FileManager.default.fileExists(atPath: overrides.path) {
            try copyContents(from: overrides, to: instanceDir)
        }

        print("整合包安装完成：\(instanceDir.lastPathComponent)")
    }

    private func createTempDir() -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func unzip(_ source: URL, to destination: URL) throws {
        guard let _ = AppContext.shared.processPool.execute(
            "/usr/bin/unzip",
            args: ["-q", source.path, "-d", destination.path],
            timeout: 120,
            captureStderr: true
        ) else {
            throw InstallError.unzipFailed(exitCode: -1)
        }
    }

    private func parseManifest(in dir: URL) throws -> Manifest {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.invalidManifest
        }

        let minecraftInfo = json["minecraft"] as? [String: Any]
        let mcVersion = minecraftInfo?["version"] as? String ?? "1.20.1"
        let loaders = minecraftInfo?["modLoaders"] as? [[String: Any]]
        let rawLoaderId = loaders?.first?["id"] as? String ?? "fabric"
        let (loader, loaderVersion) = parseLoaderAndVersion(rawLoaderId)

        var mods: [ModInfo] = []
        if let files = json["files"] as? [[String: Any]] {
            for file in files {
                let name = file["name"] as? String ?? "unknown"
                var downloadURL: URL?
                if let downloads = file["downloads"] as? [String],
                   let first = downloads.first {
                    downloadURL = URL(string: first)
                }
                mods.append(ModInfo(name: name, downloadURL: downloadURL))
            }
        }

        return Manifest(
            minecraftVersion: mcVersion,
            loader: loader,
            loaderVersion: loaderVersion,
            mods: mods
        )
    }

    private func parseLoaderAndVersion(_ id: String) -> (loader: String, version: String) {
        let knownLoaders = ["fabric", "quilt", "forge", "neoforge"]
        for known in knownLoaders {
            if id.hasPrefix(known) {
                let versionStart = id.index(id.startIndex, offsetBy: known.count)
                let version = id[versionStart...].trimmingCharacters(in: CharacterSet(charactersIn: "-.")).isEmpty
                    ? "0.15.11"
                    : String(id[versionStart...].dropFirst())
                return (known, version)
            }
        }
        return (id, "0.15.11")
    }

    private func installMinecraft(version: String, to dir: URL) async throws {
        let versionsDir = dir.appendingPathComponent("versions/\(version)")
        try FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        let jsonURL = URL(string: "https://launchermeta.mojang.com/mc/game/version_manifest.json")!
        let (manifestData, _) = try await AppContext.shared.apiSession.data(from: jsonURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let versions = manifest["versions"] as? [[String: Any]],
              let match = versions.first(where: { ($0["id"] as? String) == version }),
              let versionURLStr = match["url"] as? String,
              let versionURL = URL(string: versionURLStr) else {
            throw InstallError.versionNotFound(version)
        }

        let (versionData, _) = try await AppContext.shared.apiSession.data(from: versionURL)
        try versionData.write(to: versionsDir.appendingPathComponent("\(version).json"))
    }

    private func installLoader(_ loader: String, version: String, minecraftVersion: String, to dir: URL) async throws {
        let loaderLower = loader.lowercased()
        print("安装加载器: \(loaderLower) \(version) for Minecraft \(minecraftVersion)")
        
        // 使用 PCL 核心的安装任务来处理加载器安装
        // 这里需要 PCL 核心模块的支持，暂时记录日志
        print("加载器安装需要 PCL 核心模块支持: \(loaderLower) \(version)")
        
        // TODO: 后续集成 PCL 核心的 InstallTask
        // 例如：await InstallTask.installLoader(loader: loaderLower, version: version, minecraftVersion: minecraftVersion, to: dir)
    }

    private func downloadMod(_ mod: ModInfo, to dir: URL) async throws {
        guard let url = mod.downloadURL else {
            print("模组 \(mod.name) 无可下载地址")
            return
        }
        let (tempURL, _) = try await AppContext.shared.apiSession.download(from: url)
        let destURL = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
    }

    private func copyContents(from source: URL, to destination: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            let dest = destination.appendingPathComponent(item.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: item, to: dest)
        }
    }

    enum InstallError: Error, LocalizedError {
        case invalidManifest
        case versionNotFound(String)
        case unzipFailed(exitCode: Int32)
        case unzipTimedOut

        var errorDescription: String? {
            switch self {
            case .invalidManifest:
                return "整合包清单无效"
            case .versionNotFound(let v):
                return "未找到 Minecraft 版本: \(v)"
            case .unzipFailed(let code):
                return "解压失败 (退出码: \(code))"
            case .unzipTimedOut:
                return "解压超时"
            }
        }
    }
}
