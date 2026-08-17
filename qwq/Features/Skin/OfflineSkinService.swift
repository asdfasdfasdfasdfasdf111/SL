import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - 离线皮肤服务（自 CategoryContentView 拆出）
// 皮肤选择面板、默认皮肤恢复、从游戏 JAR / bundle 提取头像。
// 只依赖 LauncherSettings 单例（引用类型）与调用方传入的 isLaunching（避免启动中重入），
// 不持有视图、不写 @State。

enum OfflineSkinService {
    /// 弹出皮肤选择面板：校验 → 保存原图/头像 → 持久化 → 应用 PCL2 资源包方案
    static func selectSkinImage(settings: LauncherSettings) {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择皮肤图片"
        openPanel.message = "请选择一张 Minecraft 皮肤图片（64×64 或 64×32）"
        openPanel.allowedContentTypes = [.png]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                do {
                    try SkinAvatarCropper.validateSkin(at: url)

                    // 保存皮肤原图到本地
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
                    try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
                    let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")
                    let skinData = try Data(contentsOf: url)
                    try skinData.write(to: skinDestURL)

                    let avatarImage = try SkinAvatarCropper.cropAvatar(from: url)
                    let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                    try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                    // 确定性命名：固定文件名，避免每次选皮肤都产生一个 UUID 孤儿文件
                    let avatarDestURL = avatarDir.appendingPathComponent("selected_avatar.png")
                    if let pngData = avatarImage.pngData() {
                        // 必须先落盘再指向：否则 avatarImageURL 指向从未写入的文件（悬空指针）
                        try pngData.write(to: avatarDestURL)
                        DispatchQueue.main.async {
                            settings.avatarImageURL = avatarDestURL
                            settings.skinImageURL = skinDestURL
                        }
                        // 保存皮肤到持久化目录（供 authlib-injector 使用）
                        let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
                        _ = try MinecraftSkinManager.shared.saveSkin(url, forUUID: offlineUUID)

                        let version = settings.selectedMinecraftVersion
                        let gameDirPath = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
                        if !version.isEmpty && !gameDirPath.isEmpty {
                            let gameDir = URL(fileURLWithPath: gameDirPath)
                            // 离线皮肤统一走资源包方案（PCL2 移植）：生成 resourcepacks/SL 皮肤.zip
                            // 并注入 options.txt。1.19.3+ 的默认皮肤在 entity/player/{slim,wide}/ 下，
                            // 旧版 JAR 顶层替换对 1.13+ 无效（26.2 实测不加载）。
                            do {
                                try SkinResourcePackApplier.apply(skinURL: url, toVersion: version, gameDir: gameDir, settings: settings)
                            } catch {
                                print("⚠️ 皮肤资源包生成失败: \(error.localizedDescription)")
                            }
                        }
                    } else {
                        throw LauncherError.skinValidationFailed("保存头像失败")
                    }
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "不合法的图片"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "确定")
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// 未设置头像时恢复默认皮肤：磁盘缓存优先 → JAR 提取 → 内置皮肤
    static func loadDefaultIfNeeded(isLaunching: Bool, settings: LauncherSettings) {
        guard !isLaunching else { return }
        // 头像指针为空 **或指向已不存在的文件**（悬空指针）时才重新加载；
        // 正常存在的头像（含用户自选）一律不覆盖。
        if let existing = settings.avatarImageURL,
           FileManager.default.fileExists(atPath: existing.path) {
            return
        }

        // 优先从皮肤文件系统缓存加载
        let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
        if let cachedSkinData = MinecraftSkinManager.shared.getSkinData(forUUID: offlineUUID) {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
            try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
            let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")
            try? cachedSkinData.write(to: skinDestURL)

            let tempDir = FileManager.default.temporaryDirectory
            let tempSkinURL = tempDir.appendingPathComponent("\(offlineUUID).png")
            try? cachedSkinData.write(to: tempSkinURL)
            if let avatar = try? SkinAvatarCropper.cropAvatar(from: tempSkinURL) {
                let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                try? FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                let destURL = avatarDir.appendingPathComponent("cached_\(offlineUUID).png")
                if let pngData = avatar.pngData() {
                    try? pngData.write(to: destURL)
                    settings.avatarImageURL = destURL
                    settings.skinImageURL = skinDestURL
                }
            }
            try? FileManager.default.removeItem(at: tempSkinURL)
            return
        }

        // 回退：从 JAR 提取或使用内置皮肤
        let gameDirPath2 = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
        if !settings.selectedMinecraftVersion.isEmpty && !gameDirPath2.isEmpty,
           let gameDirURL = Optional(URL(fileURLWithPath: gameDirPath2)),
           let skinURL = SkinExtractor.extractFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
            try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
            let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")
            if let skinData = try? Data(contentsOf: skinURL) {
                try? skinData.write(to: skinDestURL)
                settings.skinImageURL = skinDestURL
            }
            settings.avatarImageURL = skinURL
        } else if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
            settings.skinImageURL = builtinURL
            settings.avatarImageURL = builtinURL
        }
    }

    /// 启动后加载头像（JAR 提取优先，回退内置皮肤）
    static func loadAvatarFromGameOrBundle(isLaunching: Bool, settings: LauncherSettings) {
        guard !isLaunching else { return }
        if let existingURL = settings.avatarImageURL,
           FileManager.default.fileExists(atPath: existingURL.path),
           !existingURL.lastPathComponent.hasPrefix("stf") {
            return
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
        try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")

        guard !settings.selectedMinecraftVersion.isEmpty else {
            if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                do {
                    let croppedAvatar = try SkinAvatarCropper.cropAvatar(from: builtinURL)
                    let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                    try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                    let destURL = avatarDir.appendingPathComponent("default_avatar.png")
                    if let pngData = croppedAvatar.pngData() {
                        try pngData.write(to: destURL)
                        settings.avatarImageURL = destURL
                    } else {
                        settings.avatarImageURL = builtinURL
                    }
                    settings.skinImageURL = builtinURL
                } catch {
                    settings.avatarImageURL = builtinURL
                    settings.skinImageURL = builtinURL
                }
            }
            return
        }
        do {
            let gameDirURL = URL(fileURLWithPath: settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot)
            if let skinURL = SkinExtractor.extractFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
                let avatarImage = try SkinAvatarCropper.cropAvatar(from: skinURL)
                let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                // 确定性命名（按版本）：同版本重复提取直接覆盖，不再堆 UUID 孤儿文件
                let destURL = avatarDir.appendingPathComponent("game_avatar_\(settings.selectedMinecraftVersion).png")
                if let pngData = avatarImage.pngData() {
                    try pngData.write(to: destURL)
                    settings.avatarImageURL = destURL
                } else {
                    if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                        settings.avatarImageURL = builtinURL
                    }
                }
                // 保存皮肤原图
                if let skinData = try? Data(contentsOf: skinURL) {
                    try? skinData.write(to: skinDestURL)
                    settings.skinImageURL = skinDestURL
                } else {
                    settings.skinImageURL = skinURL
                }
            } else {
                if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                    settings.avatarImageURL = builtinURL
                    settings.skinImageURL = builtinURL
                }
            }
        } catch {
            if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                settings.avatarImageURL = builtinURL
                settings.skinImageURL = builtinURL
            }
        }
    }
}
