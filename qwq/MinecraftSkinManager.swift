import Foundation
import AppKit
import CoreGraphics

// MARK: - 皮肤管理器（重构：皮肤文件存磁盘，不再塞 UserDefaults）
// 已拆出：SkinAvatarCropper（头像裁剪）/ SkinResourcePackApplier（PCL2 资源包方案，离线皮肤主路径）。
// 本类保留：皮肤持久化、authlib-injector 下载与 JVM 参数、JAR 修改方式（旧版回退，1.13+ 无效）。

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

    // MARK: - 皮肤持久化

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
