import Foundation
import AppKit
import CoreGraphics

// MARK: - 皮肤管理器（重构：皮肤文件存磁盘，不再塞 UserDefaults）

class MinecraftSkinManager {
    static let shared = MinecraftSkinManager()
    private let fileManager = FileManager.default
    private let defaultSkinNames = ["steve", "alex", "ari", "kai", "noor", "sunny", "zuri", "efe", "makena"]

    // authlib-injector 路径
    private var authlibInjectorURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SL启动器/authlib-injector.jar")
    }

    // 皮肤持久化目录
    var skinsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SL启动器/Skins")
    }

    // MARK: - 头像裁剪

    enum HeadDirection {
        case front, back, left, right, top, bottom
        var offset: (x: Int, y: Int) {
            switch self {
            case .front: return (8, 8)
            case .back:  return (24, 8)
            case .left:  return (0, 8)
            case .right: return (16, 8)
            case .top:   return (8, 0)
            case .bottom:return (16, 0)
            }
        }
    }

    func validateSkin(at url: URL) throws {
        guard let image = NSImage(contentsOf: url) else {
            throw LauncherError.skinValidationFailed("无法读取图片")
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LauncherError.skinValidationFailed("无法获取图像数据")
        }
        let w = cgImage.width, h = cgImage.height
        guard (w == 64 && h == 64) || (w == 64 && h == 32) || (w == 128 && h == 128) else {
            throw LauncherError.skinValidationFailed("不支持的尺寸: \(w)×\(h)")
        }
    }

    func cropAvatar(from url: URL, targetSize: NSSize = NSSize(width: 128, height: 128)) throws -> NSImage {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LauncherError.skinValidationFailed("无法加载图片")
        }
        let width = cgImage.width
        let height = cgImage.height
        guard (width == 64 && height == 64) || (width == 64 && height == 32) else {
            throw LauncherError.skinValidationFailed("不支持的皮肤尺寸: \(width)×\(height)")
        }
        let layer1Rect = CGRect(x: 8, y: 8, width: 8, height: 8)
        guard let layer1 = cgImage.cropping(to: layer1Rect) else {
            throw LauncherError.skinValidationFailed("无法裁剪第一层")
        }
        if height == 32 {
            return try zoomImage(layer1, to: targetSize)
        }
        let layer2Rect = CGRect(x: 40, y: 8, width: 8, height: 8)
        guard let layer2 = cgImage.cropping(to: layer2Rect) else {
            return try zoomImage(layer1, to: targetSize)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(data: nil, width: 8, height: 8,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            throw LauncherError.skinValidationFailed("无法创建画布")
        }
        context.draw(layer1, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        context.draw(layer2, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let finalHead = context.makeImage() else {
            throw LauncherError.skinValidationFailed("无法合成头像")
        }
        return try zoomImage(finalHead, to: targetSize)
    }

    private func zoomImage(_ cgImage: CGImage, to targetSize: NSSize) throws -> NSImage {
        let finalImage = NSImage(size: targetSize)
        finalImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cgImage, size: targetSize).draw(in: NSRect(origin: .zero, size: targetSize))
        finalImage.unlockFocus()
        return finalImage
    }

    // MARK: - authlib-injector 下载

    func downloadAuthlibInjector(completion: @escaping (Result<URL, Error>) -> Void) {
        if fileManager.fileExists(atPath: authlibInjectorURL.path) {
            completion(.success(authlibInjectorURL))
            return
        }

        let session = AppContext.shared.apiSession

        let metaURL = URL(string: "https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/latest.json")!
        session.dataTask(with: metaURL) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let downloadURLStr = json["download_url"] as? String,
                  let downloadURL = URL(string: downloadURLStr) else {
                completion(.failure(NSError(domain: "SkinManager", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "无法解析 authlib-injector 下载地址"])))
                return
            }

            // 下载用长超时 session
            AppContext.shared.downloadSession.downloadTask(with: downloadURL) { tempURL, _, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let tempURL = tempURL else {
                    completion(.failure(NSError(domain: "SkinManager", code: -2)))
                    return
                }
                do {
                    try self.fileManager.createDirectory(at: self.authlibInjectorURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                    if self.fileManager.fileExists(atPath: self.authlibInjectorURL.path) {
                        try self.fileManager.removeItem(at: self.authlibInjectorURL)
                    }
                    try self.fileManager.moveItem(at: tempURL, to: self.authlibInjectorURL)
                    completion(.success(self.authlibInjectorURL))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        }.resume()
    }

    func isAuthlibInjectorAvailable() -> Bool {
        return fileManager.fileExists(atPath: authlibInjectorURL.path)
    }

    func getAuthlibInjectorPath() -> String {
        return authlibInjectorURL.path
    }

    // MARK: - 皮肤应用

    /// 保存皮肤到持久化目录（文件系统，不再塞 UserDefaults）
    func saveSkin(_ skinURL: URL, forUUID uuid: String) throws -> URL {
        try fileManager.createDirectory(at: skinsDirectory, withIntermediateDirectories: true)

        let skinData = try Data(contentsOf: skinURL)
        let destURL = skinsDirectory.appendingPathComponent("\(uuid).png")

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try skinData.write(to: destURL)

        return destURL
    }

    /// 获取皮肤数据（优先磁盘，不缓存大对象到内存）
    func getSkinData(forUUID uuid: String) -> Data? {
        let url = skinsDirectory.appendingPathComponent("\(uuid).png")
        return try? Data(contentsOf: url)
    }

    /// 构建 authlib-injector 离线 Yggdrasil 元数据
    func buildOfflineSkinMeta(uuid: String, username: String, skinLocalPath: String) -> String {
        let texturesJSON: [String: Any] = [
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "profileId": uuid,
            "profileName": username,
            "textures": [
                "SKIN": [
                    "url": "file://\(skinLocalPath)"
                ]
            ]
        ]
        let texturesData = try! JSONSerialization.data(withJSONObject: texturesJSON)
        let texturesBase64 = texturesData.base64EncodedString()

        let profileJSON: [String: Any] = [
            "id": uuid,
            "name": username,
            "properties": [
                [
                    "name": "textures",
                    "value": texturesBase64
                ]
            ]
        ]
        let profileData = try! JSONSerialization.data(withJSONObject: profileJSON)
        return profileData.base64EncodedString()
    }

    /// 构建 JVM 参数
    func buildAuthlibInjectorArgs(uuid: String, username: String, skinLocalPath: String) -> [String] {
        var args: [String] = []
        guard isAuthlibInjectorAvailable() else { return args }

        args.append("-javaagent:\(authlibInjectorURL.path)")
        let profileBase64 = buildOfflineSkinMeta(uuid: uuid, username: username, skinLocalPath: skinLocalPath)
        args.append("-Dauthlibinjector.yggdrasil.prefetched=\(profileBase64)")

        return args
    }

    // MARK: - 资源包方式（PCL2 移植，离线皮肤唯一可靠方案）

    /// PCL2 离线皮肤资源包名（与 options.txt 的 resourcePacks 引用一致）
    private static let skinPackFileName = "SL 皮肤.zip"

    /// PCL2 移植：生成皮肤资源包 `resourcepacks/SL 皮肤.zip` 并注入 options.txt 的 resourcePacks。
    /// 资源包内同时写入 1.19.3+ 的 `entity/player/{slim,wide}/{9 默认皮肤}.png` 与旧版
    /// `entity/{steve,alex}.png`，全版本生效；不修改 JAR、不依赖 authlib-injector。
    func applySkinAsResourcePack(skinURL: URL, toVersion version: String, gameDir: URL, settings: LauncherSettings) throws {
        // 幂等：同一版本 + 同一皮肤文件只处理一次
        let skinHash = (try? Util.sha1OfFile(url: skinURL)) ?? "unknown"
        let currentHash = "pack_\(version)_\(skinHash)"
        if settings.appliedSkinHash == currentHash {
            print("皮肤资源包未变化，跳过")
            return
        }

        let resourcePacksDir = gameDir.appendingPathComponent("resourcepacks", isDirectory: true)
        try fileManager.createDirectory(at: resourcePacksDir, withIntermediateDirectories: true)
        let zipURL = resourcePacksDir.appendingPathComponent(Self.skinPackFileName)

        // 1) 组织临时目录：pack.mcmeta + assets 皮肤文件
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: tempDir) }

        // pack.mcmeta：pack_format 用 1 保证全版本可加载（旧格式在新版可正常使用，仅显示"旧格式"标记）
        let mcmetaURL = tempDir.appendingPathComponent("pack.mcmeta")
        let mcmeta = #"{"pack":{"pack_format":1,"description":"SL 启动器 自定义离线皮肤资源包"}}"#
        try mcmeta.write(to: mcmetaURL, atomically: true, encoding: .utf8)

        // 皮肤写入所有可能被加载的默认皮肤路径（wide + slim 双模型 + 旧版顶层路径）
        let defaultNames = ["alex", "ari", "efe", "kai", "makena", "noor", "steve", "sunny", "zuri"]
        func putSkin(relativePath: String) throws {
            let dest = tempDir.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: skinURL, to: dest)
        }
        for model in ["wide", "slim"] {
            for name in defaultNames {
                try putSkin(relativePath: "assets/minecraft/textures/entity/player/\(model)/\(name).png")
            }
        }
        try putSkin(relativePath: "assets/minecraft/textures/entity/steve.png")
        try putSkin(relativePath: "assets/minecraft/textures/entity/alex.png")

        // 2) 打包为 zip（先删旧包保证重建，避免残留旧条目；临时目录下执行保证 zip 内路径相对）
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        try runCommand("/usr/bin/zip", arguments: ["-rq", zipURL.path, "pack.mcmeta", "assets"], currentDirectory: tempDir)
        print("皮肤资源包已生成: \(zipURL.path)")

        // 3) 注入 options.txt 的 resourcePacks（PCL2 逻辑：去重后追加到末尾 = 最高优先级）
        try updateOptionsResourcePacks(gameDir: gameDir, addPack: Self.skinPackFileName)

        settings.appliedSkinHash = currentHash
    }

    /// 移除皮肤资源包：删除 zip 并从 options.txt 的 resourcePacks 摘除
    func removeSkinResourcePack(gameDir: URL) throws {
        let zipURL = gameDir.appendingPathComponent("resourcepacks").appendingPathComponent(Self.skinPackFileName)
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        try updateOptionsResourcePacks(gameDir: gameDir, removePack: Self.skinPackFileName)
    }

    /// 修改 options.txt 的 resourcePacks：追加（最高优先级）或移除指定资源包。
    /// options.txt 为 INI 风格（key:value），resourcePacks 值为 JSON 数组字符串。
    private func updateOptionsResourcePacks(gameDir: URL, addPack: String? = nil, removePack: String? = nil) throws {
        let optionsURL = gameDir.appendingPathComponent("options.txt")
        var content = ""
        if fileManager.fileExists(atPath: optionsURL.path) {
            content = (try String(contentsOf: optionsURL, encoding: .utf8))
        }

        var packs: [String] = []
        // 解析现有 resourcePacks（宽松解析：取出方括号内的逗号分隔元素）
        if let range = content.range(of: "resourcePacks:"),
           let open = content.range(of: "[", range: range.upperBound..<content.endIndex),
           let close = content.range(of: "]", range: open.upperBound..<content.endIndex) {
            let inner = String(content[open.upperBound..<close.lowerBound])
            packs = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        let packRefs = [addPack, removePack].compactMap { $0 }
        packs.removeAll { p in
            let trimmed = p.replacingOccurrences(of: "\"", with: "")
            return packRefs.contains(trimmed)
        }
        // 追加"vanilla"打底（PCL2 行为），再 append 皮肤包 → 列表末尾优先级最高
        if packs.isEmpty { packs.append("\"vanilla\"") }
        if let addPack {
            packs.append("\"file/\(addPack)\"")
        }
        let newValue = "[" + packs.joined(separator: ",") + "]"

        // 替换或追加 resourcePacks 行
        if let lineRange = content.range(of: "resourcePacks:[^\n]*", options: .regularExpression) {
            content.replaceSubrange(lineRange, with: "resourcePacks:\(newValue)")
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            content += "resourcePacks:\(newValue)\n"
        }
        try content.write(to: optionsURL, atomically: true, encoding: .utf8)
        print("options.txt resourcePacks 已更新: \(newValue)")
    }

    // MARK: - JAR 修改方式（旧版回退，1.13+ 无效）

    func applySkinToJar(skinURL: URL, toVersion version: String, gameDir: URL, settings: LauncherSettings) throws {
        let attrs = try fileManager.attributesOfItem(atPath: skinURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        let modDate = attrs[.modificationDate] as? Date ?? Date()
        let currentHash = "\(version)_\(fileSize)_\(modDate.timeIntervalSince1970)"

        if settings.appliedSkinHash == currentHash {
            print("皮肤未变化，跳过替换")
            return
        }

        let jarURL = gameDir.appendingPathComponent("versions/\(version)/\(version).jar")
        guard fileManager.fileExists(atPath: jarURL.path) else {
            throw LauncherError.jarModificationFailed("未找到版本 JAR 文件")
        }

        let backupURL = jarURL.deletingPathExtension().appendingPathExtension("jar.backup")
        if !fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.copyItem(at: jarURL, to: backupURL)
        }

        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assetDir = tempDir.appendingPathComponent("assets/minecraft/textures/entity")
        try fileManager.createDirectory(at: assetDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        for skinName in defaultSkinNames {
            let destPath = assetDir.appendingPathComponent("\(skinName).png")
            if fileManager.fileExists(atPath: destPath.path) {
                try fileManager.removeItem(at: destPath)
            }
            try fileManager.copyItem(at: skinURL, to: destPath)
        }

        try runCommand("/usr/bin/zip", arguments: ["-rq", jarURL.path, "assets"], currentDirectory: tempDir)
        print("皮肤已应用到版本: \(version) (JAR 方式)")
        settings.appliedSkinHash = currentHash
    }

    func restoreOriginalJar(forVersion version: String, gameDir: URL) throws {
        let jarURL = gameDir.appendingPathComponent("versions/\(version)/\(version).jar")
        let backupURL = jarURL.deletingPathExtension().appendingPathExtension("jar.backup")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: jarURL)
            try fileManager.moveItem(at: backupURL, to: jarURL)
        }
    }

    // MARK: - 命令执行（使用 ProcessPool）

    private func runCommand(_ command: String, arguments: [String], currentDirectory: URL? = nil) throws {
        let result = AppContext.shared.processPool.execute(
            command, args: arguments, timeout: 15, captureStderr: true,
            currentDirectory: currentDirectory
        )
        guard result != nil else {
            throw LauncherError.jarModificationFailed("命令执行失败")
        }
    }
}