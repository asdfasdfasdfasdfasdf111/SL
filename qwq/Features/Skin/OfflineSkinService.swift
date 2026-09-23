import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - 离线皮肤服务（自 CategoryContentView 拆出）
// 皮肤选择面板、默认皮肤恢复、从游戏 JAR / bundle 提取头像。
// 只依赖 LauncherSettings 单例（引用类型）与调用方传入的 isLaunching（避免启动中重入），
// 不持有视图、不写 @State。

enum OfflineSkinService {
    /// 应用支持目录 + 皮肤/头像子目录（三段重复逻辑共用）
    private static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }
    private static var skinDir: URL { appSupportDir.appendingPathComponent("SL启动器/Skins") }
    private static var avatarDir: URL { appSupportDir.appendingPathComponent("SL启动器/Avatars") }

    /// 皮肤原图落盘（创建目录 + 写 default 文件名），返回目标 URL
    ///
    /// 空数据一律拒绝写入：`Data()` 经 `.atomic` 覆写会把**已保存的皮肤文件截断为 0 字节**，
    /// 而 0 字节文件在磁盘上依然「存在」，后续 `settings.skinImageURL` 会继续引用它。
    /// 调用方既有语义已兼容返回 `nil`（例如 `loadDefaultIfNeeded` 的
    /// `skinDestURL?.path ?? ""` 分支），因此这里返回 `nil` 不引入新分支。
    static func saveSkinImage(_ data: Data, fileName: String = "selected_skin.png") -> URL? {
        guard !data.isEmpty else {
            err("皮肤数据为空，跳过写入以免截断已保存的皮肤")
            return nil
        }
        try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let dest = skinDir.appendingPathComponent(fileName)
        do { try data.write(to: dest, options: .atomic) }
        catch { err("皮肤写入失败: \(error.localizedDescription)"); return nil }
        return dest
    }

    /// 裁剪头像并落盘（创建目录 + 写 fileName），返回目标 URL
    static func saveAvatar(from sourceURL: URL, fileName: String) -> URL? {
        try? FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
        guard let avatar = try? SkinAvatarCropper.cropAvatar(from: sourceURL),
              let pngData = avatar.pngData() else { return nil }
        let dest = avatarDir.appendingPathComponent(fileName)
        do { try pngData.write(to: dest, options: .atomic) }
        catch { err("头像写入失败: \(error.localizedDescription)"); return nil }
        return dest
    }

    /// 弹出皮肤选择面板：按尺寸分类 → 保存原图/头像 → 持久化 → 应用 PCL2 资源包方案。
    ///
    /// 三类尺寸的出路**完全不同**（2026-09-24 引入高清皮肤支撑后）：
    /// - **原版尺寸**（64×64 / 64×32）：原样走老流程。
    /// - **整倍数高清**（128×128、128×64…）：原版不认，但装 CustomSkinLoader（万用皮肤补丁）
    ///   就能用。这里把皮肤**降采样成原版尺寸副本**喂给启动器自身（头像管线与资源包都只认原版布局），
    ///   同时**保留高清原图**供游戏侧使用，最后发通知让界面弹询问卡片。
    /// - **其余**（非整倍数、长宽不成对等）：如实拒绝 —— 装补丁也救不了。
    static func selectSkinImage(settings: LauncherSettings) {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择皮肤图片"
        openPanel.message = "请选择一张 Minecraft 皮肤图片（64×64 或 64×32；高清尺寸需安装皮肤补丁）"
        openPanel.allowedContentTypes = [.png]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }
            do {
                try handlePickedSkin(at: url, settings: settings)
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

    /// 尺寸分类后的三分支分派。规则与文案口径见 `SkinHDSupport`（分类）与 `SkinPatchCardView`（询问卡片）。
    /// - Throws: 分类为「原版不支持」时抛 `LauncherError.skinValidationFailed`（文案直接展示给用户）；
    ///   落盘/裁剪失败时原样上抛。
    private static func handlePickedSkin(at url: URL, settings: LauncherSettings) throws {
        guard let pixel = SkinSizeInspector.pixelSize(of: url) else {
            throw LauncherError.skinValidationFailed("无法读取图片")
        }
        let sizeClass = SkinSizeInspector.classify(width: pixel.width, height: pixel.height)

        switch sizeClass {
        case .unsupported:
            // 之前的卡片不再适用（用户换了张更不靠谱的图）—— 先收起再抛错，免得弹窗后面
            // 还压着一张描述旧尺寸的卡片。
            postSizeClassified(pixelSize: nil)
            // 复用裁剪器已有的口径与文案（「Java 版皮肤必须是 64×64 或 64×32，当前为 …」）。
            // ⚠️ 但**不能**用它的文案去描述 128×128：那句「128×128 是基岩版格式，Java 版不支持」
            // 在有了补丁之后已经不成立（补丁正是为这类整倍数高清尺寸准备的），故高清尺寸走下面分支，
            // 不在这一支里被误杀。
            try SkinAvatarCropper.validateSkin(at: url)

        case .vanillaSupported:
            try applySkin(source: url, settings: settings)
            // 换回原版尺寸 → 收回可能还开着的那张补丁卡片（否则它会继续用旧尺寸描述误导用户）
            postSizeClassified(pixelSize: nil)

        case .needsPatch:
            // 1) 降采样出原版尺寸副本，供**启动器自身**使用。
            //    理由：`SkinLayerView.cropped`（yOffset 只认 h==32/64）与
            //    `SkinAvatarCropper.cropAvatar` 的取景坐标都按 64×64 布局写死 ——
            //    把 128×128 直接喂进去会**取错区域**（头部在 (16,16) 而不是 (8,8)），
            //    表现为头像错位。故「启动器显示」一律吃降采样副本，「游戏内」才用原图。
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("sl-vanilla-skin-\(UUID().uuidString).png")
            try SkinSizeInspector.vanillaSizedPNGData(from: url).write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }

            // 2) 高清原图单独留一份 —— 这才是「装补丁」真正想要的那个文件。
            //    落盘失败不致命（启动器仍能正常显示降采样副本），但会让游戏侧拿不到高清图，
            //    故记一条日志，便于用户反馈「装了补丁但还是模糊」时定位。
            let hdData = try Data(contentsOf: url)
            if saveSkinImage(hdData, fileName: "selected_skin_hd.png") == nil {
                err("高清皮肤原图落盘失败，游戏侧将只能拿到降采样副本")
            }

            try applySkin(source: temporary, settings: settings)

            // 3) 一切落盘成功之后，才去问用户要不要装补丁 —— 顺序不能反：
            //    先弹卡片再保存的话，用户关掉卡片就会留下「没保存皮肤、却被告知要装补丁」的错乱状态。
            postSizeClassified(pixelSize: sizeClass.sizeText)
        }
    }

    /// 广播「尺寸分类结果」到界面（主线程）。
    /// - Parameter pixelSize: 需要补丁时的尺寸文案（如 `128×128`）；传 `nil` 表示「不需要补丁」，
    ///   界面据此收起先前可能还开着的询问卡片。
    private static func postSizeClassified(pixelSize: String?) {
        DispatchQueue.main.async {
            var info: [String: Any] = [:]
            if let pixelSize { info["pixelSize"] = pixelSize }
            NotificationCenter.default.post(name: .skinSizeClassified, object: nil, userInfo: info)
        }
    }

    /// 落盘 + 应用（原先内联在 `selectSkinImage` 里那段，逐字保留，只把来源 URL 提为参数）。
    ///
    /// ⚠️ `source` 必须是**原版尺寸**（64×64 / 64×32）的图片：头像裁剪与资源包生成都以它为输入，
    /// 高清尺寸必须先经 `SkinSizeInspector.vanillaSizedPNGData` 降采样（见调用点）。
    private static func applySkin(source url: URL, settings: LauncherSettings) throws {
        try SkinAvatarCropper.validateSkin(at: url)

        // 顺序：**先裁头像、后写皮肤原图**。
        // 反过来的话（原实现），一旦头像裁剪失败，磁盘上的 selected_skin.png
        // 已被新皮肤覆盖、而 settings 仍是旧值 —— 留下「文件是新皮肤、
        // 界面还是旧头像」的半完成状态；用户下次看到的是旧头像配新皮肤文件。
        // 校验口径统一（去掉 128×128）之后此路径已很难走到，但仍按正确顺序写。
        let avatarDestURL = saveAvatar(from: url, fileName: "selected_avatar.png")

        if let avatarDestURL {
            let skinData = try Data(contentsOf: url)
            let skinDestURL = saveSkinImage(skinData)
            // 必须先落盘再指向：否则 avatarImageURL 指向从未写入的文件（悬空指针）
            DispatchQueue.main.async {
                settings.avatarImageURL = avatarDestURL
                // 仅当皮肤原图落盘成功才更新 skinImageURL：落盘失败（如磁盘瞬时繁忙）
                // 时若直接赋 nil，会把用户既有皮肤清空、与已更新的头像产生不一致。
                if let skinDestURL {
                    settings.skinImageURL = skinDestURL
                }
            }
            // 保存皮肤到持久化目录（供 authlib-injector 使用）
            // 落盘经 Skin 服务层：DefaultSkinService.saveSkin 内部即委托 MinecraftSkinManager，抛错语义不变
            let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
            _ = try DefaultSkinService().saveSkin(from: url, forUUID: offlineUUID)

            let version = settings.selectedMinecraftVersion
            let gameRootPath = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
            if !version.isEmpty && !gameRootPath.isEmpty {
                // 离线皮肤统一走资源包方案（PCL2 移植）：生成 resourcepacks/SL 皮肤.zip
                // 并注入 options.txt。1.19.3+ 的默认皮肤在 entity/player/{slim,wide}/ 下，
                // 旧版 JAR 顶层替换对 1.13+ 无效（26.2 实测不加载）。
                // 目标目录为**版本运行目录** gameRoot/versions/<版本>（游戏的 game_directory），
                // 与启动链路口径一致；写入游戏根目录游戏不会加载。
                do {
                    let versionDir = SkinResourcePackApplier.versionDirectory(gameRoot: gameRootPath, version: version)
                    try SkinResourcePackApplier.apply(skinURL: url, toVersion: version, gameDir: versionDir, settings: settings)
                } catch {
                    // 皮肤图片与头像已落盘并更新，但游戏内资源包未生成：
                    // 此前只 print，用户进游戏看不到新皮肤且毫无感知。现接入统一日志与提示通道。
                    LogManager.err("皮肤资源包生成失败: \(error.localizedDescription)")
                    NoticeCenter.shared.post(
                        Notice(level: .warning,
                               title: "皮肤已保存，资源包注入失败",
                               message: "皮肤图片与头像已更新，但游戏内资源包生成失败，进入游戏可能看不到新皮肤（\(error.localizedDescription)）。")
                    )
                }
            }
        } else {
            throw LauncherError.skinValidationFailed("保存头像失败")
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

        // 优先从皮肤文件系统缓存加载（经 Skin 服务层读取，返回语义与 MinecraftSkinManager 一致）
        let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
        if let cachedSkinData = DefaultSkinService().skinData(forUUID: offlineUUID) {
            let skinDestURL = saveSkinImage(cachedSkinData)

            let tempDir = FileManager.default.temporaryDirectory
            let tempSkinURL = tempDir.appendingPathComponent("\(offlineUUID).png")
            try? cachedSkinData.write(to: tempSkinURL)
            if let avatarURL = saveAvatar(from: tempSkinURL, fileName: "cached_\(offlineUUID).png") {
                settings.avatarImageURL = avatarURL
                settings.skinImageURL = skinDestURL
            }
            try? FileManager.default.removeItem(at: tempSkinURL)
            return
        }

        // 回退：从 JAR 提取或使用内置皮肤
        let gameDirPath2 = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
        if !settings.selectedMinecraftVersion.isEmpty && !gameDirPath2.isEmpty,
           let gameDirURL = Optional(URL(fileURLWithPath: gameDirPath2)),
           let skinURL = SkinExtractor.extractFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
            let skinDestURL = saveSkinImage((try? Data(contentsOf: skinURL)) ?? Data())
            if FileManager.default.fileExists(atPath: skinDestURL?.path ?? "") {
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
        // 此处原先无条件 `saveSkinImage(Data())`：返回值从未被使用（死赋值），
        // 唯一副作用是把已保存的 `selected_skin.png` 截断为 0 字节，
        // 再经 `handleViewAppear` 的「先本方法、后 loadDefaultIfNeeded」顺序，
        // 撞上 loadDefaultIfNeeded 的「头像存在即提前返回」分支 → 皮肤文件被永久置空。
        // 去掉该写入；皮肤落盘统一由下面确有数据的 `saveSkinImage(skinData)` 负责。
        guard !settings.selectedMinecraftVersion.isEmpty else {
            if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                if let avatarURL = saveAvatar(from: builtinURL, fileName: "default_avatar.png") {
                    settings.avatarImageURL = avatarURL
                } else {
                    settings.avatarImageURL = builtinURL
                }
                settings.skinImageURL = builtinURL
            }
            return
        }
        // 原实现把这段包在 `do { } catch { }` 里，但 do 块内**没有任何会 throw 的调用**
        // （extractFromGameJar / saveAvatar / saveSkinImage 都是返回可选值，Data 读取走 try?），
        // 编译器明确告警 `'catch' block is unreachable because no errors are thrown in 'do' block`。
        // 空壳 catch 的语义等价于「什么都不做」，故直接去掉包装，行为不变。
        let gameDirURL = URL(fileURLWithPath: settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot)
        if let skinURL = SkinExtractor.extractFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
            // 确定性命名（按版本）：同版本重复提取直接覆盖，不再堆 UUID 孤儿文件
            let avatarName = "game_avatar_\(settings.selectedMinecraftVersion).png"
            if let avatarURL = saveAvatar(from: skinURL, fileName: avatarName) {
                settings.avatarImageURL = avatarURL
            } else if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                settings.avatarImageURL = builtinURL
            }
            // 保存皮肤原图
            if let skinData = try? Data(contentsOf: skinURL) {
                if let dest = saveSkinImage(skinData) {
                    settings.skinImageURL = dest
                } else {
                    settings.skinImageURL = skinURL
                }
            } else {
                settings.skinImageURL = skinURL
            }
        } else if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
            settings.avatarImageURL = builtinURL
            settings.skinImageURL = builtinURL
        }
    }
}
