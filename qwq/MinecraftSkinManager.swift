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

    // MARK: - JAR 修改方式（回退方案）

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