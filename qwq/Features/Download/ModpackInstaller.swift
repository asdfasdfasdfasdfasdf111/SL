import Foundation
import ZIPFoundation

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

        try await installMinecraft(version: manifest.minecraftVersion, to: instanceDir)

        // MARK: 目录口径（本次修改的唯一依据，实读自启动链路）
        // 游戏进程的 `game_directory` = `MinecraftInstance.runningDirectory`
        // = `<游戏根目录>/versions/<版本>`（见 `MinecraftLauncher` 的 game_directory 取值，
        // 以及 `SkinResourcePackApplier.versionDirectory` 的契约注释：`resourcepacks`、
        // `options.txt`、`<版本>.jar` 均位于版本运行目录；`ModDragInstaller.install` 亦按
        // `<root>/versions/<版本>/mods` 落盘）。因此整合包内容（`mods` 与 `overrides` 里的
        // `resourcepacks`/`config` 等）都必须写到**版本运行目录**；写到游戏根目录游戏不会加载。
        // 该目录与下面的 `installMinecraft` 保持同一口径（同一个 `versions/<版本>`）。
        let gameDir = instanceDir
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(manifest.minecraftVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

        let modsDir = gameDir.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        for mod in manifest.mods {
            try await downloadMod(mod, to: modsDir)
        }

        let overrides = tempDir.appendingPathComponent("overrides")
        if FileManager.default.fileExists(atPath: overrides.path) {
            // overrides 与 mods 同口径：整体落到版本运行目录（而非游戏根目录）
            try copyContents(from: overrides, to: gameDir)
        }

        log("整合包原版与内容已安装：\(instanceDir.lastPathComponent)（Minecraft \(manifest.minecraftVersion)）")

        // 加载器放在最后：让原版清单与整合包内容先落盘（用户随后在已带加载器的实例中
        // 复用这些文件即可），再由 `installLoader` 抛错把「未装加载器」暴露给用户。
        try await installLoader(manifest.loader, version: manifest.loaderVersion, minecraftVersion: manifest.minecraftVersion, to: instanceDir)
    }

    private func createTempDir() -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func unzip(_ source: URL, to destination: URL) throws {
        do {
            let archive = try Archive(url: source, accessMode: .read)
            for entry in archive {
                // ZIP Slip 防御（同 Util.unzip）：拒绝绝对路径与含 .. 的条目，防止写入目标目录之外
                let entryPath = entry.path.replacingOccurrences(of: "\\", with: "/")
                let normalizedPath = (entryPath as NSString).standardizingPath
                if normalizedPath.hasPrefix("/") || normalizedPath.components(separatedBy: "/").contains("..") {
                    continue
                }
                _ = try archive.extract(entry, to: destination.appendingPathComponent(normalizedPath))
            }
        } catch {
            throw InstallError.unzipFailed
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
        try versionData.write(to: versionsDir.appendingPathComponent("\(version).json"), options: .atomic)
    }

    /// 安装整合包所需的加载器。
    ///
    /// **本次修改：改为明确失败（抛错），不再静默假装成功。**
    ///
    /// 旧实现只 `log` + `warn` 后正常返回，调用方随即提示「整合包安装完成」——
    /// 实例实际没有加载器，模组一个都不会被加载，用户拿到的是「假成功」。
    ///
    /// 为什么没有接线（普查结论：`qwq/PCLCore/Minecraft/Mod/Loader/**` +
    /// `PCLCore/Minecraft/Download/LoaderInstallTasks.swift` + `MinecraftInstaller.swift`）：
    ///  - **Fabric**：`FabricInstaller.installFabric(version:minecraftDirectory:runningDirectory:_:)`
    ///    签名可直接调用，但它写入的是 `inheritsFrom: <原版版本>` 的**加载器清单**，必须落在
    ///    独立版本目录 `<原版版本>-<加载器>`：`MinecraftInstance.loadManifest` 只认
    ///    `<目录名>/<目录名>.json`，而 `ClientManifest.parse` 按
    ///    `versionsURL/<inheritsFrom>/<inheritsFrom>.json` 解析父清单——写进原版目录会覆盖
    ///    原版 JSON 并形成自继承（递归到 16 层后判为循环引用）。也就是说，接线后启动的实例是
    ///    `versions/<原版版本>-<加载器>`，而本文件的 mods/overrides 按上面的口径落在
    ///    `versions/<原版版本>`，两者不是同一个 game_directory，「模组不加载」依旧存在。
    ///  - **Forge / NeoForge**：`ForgeInstaller` 需要 `ClientManifest` + `MinecraftInstallTask`，
    ///    由 `LoaderInstallTask.install(_:)` 驱动，签名与「给定一个已存在的目录」不匹配。
    ///  - **完整链路**（也是唯一能真正接上的路径）：`MinecraftInstaller.createTask` +
    ///    `InstallTasks`，它把原版清单/本体/资源/依赖/natives 与加载器、加载器依赖库
    ///    串成一条任务链，并通过全局 `DataManager.inprogressInstallTasks` 与下载详情页
    ///    （`DownloadDetailManager` / 导航 router）展示进度。在整合包安装里裸调它会接管导航与
    ///    下载 UI（属交互观感变更，超出本次可改范围）；而且本文件的 `installMinecraft` 只取
    ///    版本 JSON，不下载原版本体与依赖库，只补加载器同样得不到可启动实例。
    ///
    /// 真接线需要补齐：整合包安装整体改走 `MinecraftInstaller.createTask` + 加载器 `InstallTask`
    /// 的统一任务链（原版本体/资源/依赖/natives 与加载器一并下载），实例名与
    /// game_directory 统一为 `<原版版本>-<加载器>`，并把 mods/overrides 落到该目录。
    private func installLoader(_ loader: String, version: String, minecraftVersion: String, to dir: URL) async throws {
        let loaderLower = loader.lowercased()
        log("安装加载器: \(loaderLower) \(version) for Minecraft \(minecraftVersion)")
        warn("加载器未安装（当前不支持自动安装加载器）: \(loaderLower) \(version) for Minecraft \(minecraftVersion)")

        throw InstallError.loaderInstallUnsupported(
            loader: loaderLower,
            version: version,
            minecraftVersion: minecraftVersion
        )
    }

    private func downloadMod(_ mod: ModInfo, to dir: URL) async throws {
        guard let url = mod.downloadURL else {
            warn("模组 \(mod.name) 无可下载地址")
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
        case unzipFailed
        /// 整合包声明的加载器当前无法自动安装（明确失败，避免「安装完成」撒谎）。
        case loaderInstallUnsupported(loader: String, version: String, minecraftVersion: String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest:
                return "整合包清单无效"
            case .versionNotFound(let v):
                return "未找到 Minecraft 版本: \(v)"
            case .unzipFailed:
                return "整合包解压失败"
            case .loaderInstallUnsupported(let loader, let version, let minecraftVersion):
                return "加载器未安装：该整合包需要 \(loader) \(version)（Minecraft \(minecraftVersion)），"
                    + "当前版本暂不支持自动安装加载器，游戏将无法加载整合包内的模组。"
                    + "请在已带 \(loader) 加载器的实例中安装此整合包。"
            }
        }
    }
}
