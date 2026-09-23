//
//  SkinHDSupport.swift
//  高清皮肤支撑逻辑（**纯逻辑：不联网、不写盘**）
//
//  背景：Java 版原版只接受 64×64 / 64×32 的皮肤；128×128、256×256 这类「高清皮肤」
//  原版不认，但装上 **CustomSkinLoader**（中文名「万用皮肤补丁」）就能加载。
//  于是选皮肤时需要回答两个**纯问题**：
//    1. 这张图属于哪一类（原版可用 / 需补丁 / 根本不该接受）？
//    2. 当前选中的版本 id 对应哪个**游戏版本**、哪个**加载器**（决定去哪查补丁、查哪个）？
//
//  ⚠️ 本文件不发起任何网络请求、不写任何文件。联网查补丁在 `SkinPatchCatalog`，
//  安装编排在 `SkinPatchCoordinator`，UI 在 `SkinPatchCardView`。
//

import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 尺寸分类

/// 一张皮肤图按尺寸可归入的三类。
enum SkinSizeClass: Equatable {
    /// 原版直接可用：64×64（1.8+，含帽子图层）或 64×32（1.8 之前，单层）。
    case vanillaSupported(width: Int, height: Int)

    /// 原版不支持，但属于**合法整倍数**（128×128、256×256、128×64 …）——
    /// 这正是「装补丁就能用」的那一类，值得弹卡片询问。
    /// - Parameters:
    ///   - scale: 相对原版基准的倍数（128×128 → 2，256×256 → 4）
    ///   - isLegacyLayout: 是否旧版布局（64×32 的倍数，没有帽子图层）
    case needsPatch(width: Int, height: Int, scale: Int, isLegacyLayout: Bool)

    /// 任何情况下都不该接受：非整倍数、自造尺寸、长宽不成对等。
    case unsupported(width: Int, height: Int)

    /// 界面展示用的尺寸文案（如 `128×128`）。
    var sizeText: String {
        switch self {
        case .vanillaSupported(let w, let h), .unsupported(let w, let h):
            return "\(w)×\(h)"
        case .needsPatch(let w, let h, _, _):
            return "\(w)×\(h)"
        }
    }
}

enum SkinSizeInspector {

    /// 读取图片的**像素**尺寸。读不到返回 nil（调用方据此报「无法读取图片」）。
    ///
    /// ⚠️ 用 `cgImage(forProposedRect:)` 而不是 `NSImage.size`：后者是「点」尺寸，
    /// 会被图片自身的 DPI 元信息影响（例如带 144dpi 标记的 PNG 会算错倍数），
    /// 而皮肤尺寸判断必须看真实像素。
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return (cgImage.width, cgImage.height)
    }

    /// 按尺寸分类。
    ///
    /// 规则来自 Java 原版与 CustomSkinLoader 的共同约定 —— 高清皮肤必须是原版布局的**整倍数**：
    /// - 新版布局 `64n × 64n`（n ≥ 1）：n = 1 即原版 64×64，n ≥ 2 即 128×128、192×192…
    /// - 旧版布局 `64n × 32n`（n ≥ 1）：n = 1 即原版 64×32，n ≥ 2 即 128×64、192×96…
    ///
    /// 其余一律 `unsupported`。**刻意不猜**：`100×100` 这种「看起来像高清」的尺寸
    /// 既不是原版尺寸也不是整倍数，装补丁也没用，必须如实拒绝。
    static func classify(width: Int, height: Int) -> SkinSizeClass {
        guard width > 0, height > 0 else { return .unsupported(width: width, height: height) }

        // 新版布局：长宽相等且都是 64 的整数倍
        if width == height, width % 64 == 0 {
            let scale = width / 64
            return scale == 1
                ? .vanillaSupported(width: width, height: height)
                : .needsPatch(width: width, height: height, scale: scale, isLegacyLayout: false)
        }

        // 旧版布局：宽是 64 的整数倍、高是 32 的整数倍，且两者倍数一致（即 2:1）
        if width % 64 == 0, height % 32 == 0, width / 64 == height / 32 {
            let scale = width / 64
            return scale == 1
                ? .vanillaSupported(width: width, height: height)
                : .needsPatch(width: width, height: height, scale: scale, isLegacyLayout: true)
        }

        return .unsupported(width: width, height: height)
    }

    /// 把一张**整倍数**皮肤降采样成原版尺寸的 PNG 数据。
    ///
    /// 用途：启动器自身的头像管线（`SkinLayerView.cropped` + `SkinAvatarCropper`）
    /// 只认原版布局 —— 128×128 的贴图头部在 (16,16) 而不是 (8,8)，直接喂进去会**取错区域**。
    /// 所以「启动器显示」用降采样副本，「游戏内」用原图（双方各自拿到需要的形态）。
    ///
    /// ⚠️ 用最近邻（`interpolationQuality = .none`）：高清皮肤是原版布局的整倍放大，
    /// 整倍降采样不需要任何插值；一旦插值反而会把像素画糊掉。
    static func vanillaSizedPNGData(from url: URL) throws -> Data {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LauncherError.skinValidationFailed("无法读取图片")
        }
        // 目标尺寸：长宽相等 → 新版 64×64；否则旧版 64×32（上游已按整倍数校验过）
        let target = cgImage.width == cgImage.height ? (width: 64, height: 64) : (width: 64, height: 32)
        guard let context = CGContext(data: nil, width: target.width, height: target.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LauncherError.skinValidationFailed("无法创建缩放画布")
        }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard let scaled = context.makeImage() else {
            throw LauncherError.skinValidationFailed("无法缩放图片")
        }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw LauncherError.skinValidationFailed("无法创建 PNG 编码器")
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LauncherError.skinValidationFailed("PNG 编码失败")
        }
        return buffer as Data
    }
}

// MARK: - 版本 id 拆分

/// 版本 id（形如 `1.21.1-Fabric`）→ 游戏版本 + 加载器。
///
/// ⚠️ 为什么需要它：Modrinth 的 `game_versions` 过滤要的是**纯游戏版本**（`1.21.1`），
/// 而工程里 `settings.selectedMinecraftVersion` 存的是**版本 id**（带加载器后缀）——
/// 直接把 id 当游戏版本传去过滤会一条都查不到（`1.21.1-Fabric` 不是任何模组声明的版本）。
///
/// 后缀词表沿用 `LoaderNameResolver.assetMap` 的键（fabric / forge / neoforge / neoforged /
/// quilt / rift），避免两处各维护一份加载器名单。
enum SkinVersionIdentity {

    /// 加载器后缀词表 —— 直接取自 `LoaderNameResolver.assetMap` 的**键**（都是小写）。
    private static let loaderTokens: Set<String> = Set(LoaderNameResolver.assetMap.keys)

    /// 从版本 id 尾部找出加载器词（找不到返回 nil，表示原版）。
    /// 从**后往前**扫：`26.3-snapshot-3-Fabric` 的最后一段才是加载器。
    static func loaderToken(from versionID: String) -> String? {
        for part in versionID.lowercased().split(separator: "-").reversed() {
            let token = part.trimmingCharacters(in: .whitespaces)
            if loaderTokens.contains(token) { return token }
        }
        return nil
    }

    /// 去掉加载器后缀后的游戏版本。
    /// `1.21.1-Fabric` → `1.21.1`；`26.3-snapshot-3-Fabric` → `26.3-snapshot-3`；
    /// 原版 `26.2` → 原样返回。
    static func minecraftVersion(from versionID: String) -> String {
        guard let token = loaderToken(from: versionID) else { return versionID }
        // 从后往前找 `-<token>`，避免误伤版本号里同名的片段
        if let range = versionID.lowercased().range(of: "-" + token, options: .backwards) {
            return String(versionID[versionID.startIndex..<range.lowerBound])
        }
        return versionID
    }

    /// 加载器枚举（找不到 = 原版，返回 nil）。
    ///
    /// ⚠️ 返回 nil 是有意义的结果，不是失败：**原版客户端加载不了模组**，
    /// 此时「装补丁」这条路根本不存在，界面必须如实说明而不是假装能装。
    static func loader(from versionID: String) -> ModLoader? {
        switch loaderToken(from: versionID) {
        case "fabric": return .fabric
        case "forge": return .forge
        case "neoforge", "neoforged": return .neoforge
        case "quilt": return .quilt
        case "rift": return .rift
        default: return nil
        }
    }
}

// MARK: - 文案

/// 卡片文案（纯函数，便于单测）。
///
/// 排版约定：正文段落**首行缩进两个全角空格**（`\u{3000}`），左对齐、可换行 ——
/// 即中文正文的常规写法；不用居中、也不用 Markdown（SwiftUI 的 `Text` 不解析 Markdown 标题）。
enum SkinPatchCopy {

    /// 全角空格（一个 = 一个汉字宽）
    static let fullWidthSpace = "\u{3000}"
    /// 首行缩进两格
    static let indent = fullWidthSpace + fullWidthSpace

    /// 卡片标题
    static let title = "检测到高清皮肤"

    /// 原版支持的尺寸说明（多处复用，避免文案漂移）
    static let vanillaSizeHint = "64×64 或 64×32"

    /// 查询中
    static func checkingBody() -> String {
        indent + "正在向 Modrinth 查询适配当前游戏版本与加载器的 \(SkinPatchCatalog.displayName) 版本…"
    }

    /// 有可用补丁
    ///
    /// ⚠️ 正文里**如实列出 jar 文件名与它自己声明的加载器列表**（`patch.loaders` 是上游原始字段，
    /// 不做大小写美化）—— 这是「凭什么说这个包适用于当前加载器」的唯一凭据，
    /// 摆在明面上比藏在代码里更经得起追问。
    static func availableBody(pixelSize: String, patch: SkinPatchCatalog.Patch,
                              gameVersion: String, loader: ModLoader?) -> String {
        let loaderText = loader?.displayName ?? "未知加载器"
        return indent
            + "你选择的皮肤尺寸是 \(pixelSize)，而 Java 版原版只支持 \(vanillaSizeHint)，直接用不会正常显示。"
            + "已检测到适用于 \(gameVersion)（\(loaderText)）的补丁："
            + "\(SkinPatchCatalog.displayName)（\(SkinPatchCatalog.chineseName)）\(patch.versionNumber)，"
            + "文件 \(patch.filename)，其声明支持的加载器为 \(patch.loaders.joined(separator: " / "))。"
            + "安装后游戏即可加载该尺寸的皮肤。"
    }

    /// 没有可用的补丁版本（如快照版：上游不提供每周快照支持）
    static func noPatchBody(pixelSize: String, gameVersion: String, loader: ModLoader?) -> String {
        let loaderText = loader?.displayName ?? "未知加载器"
        return indent
            + "你选择的皮肤尺寸是 \(pixelSize)，而 Java 版原版只支持 \(vanillaSizeHint)。"
            + "已查询 \(SkinPatchCatalog.displayName)，但没有找到适用于 \(gameVersion)（\(loaderText)）的版本，"
            + "该补丁只发布正式版、不提供每周快照支持。可以换一个正式版，或换一张 \(vanillaSizeHint) 的皮肤。"
    }

    /// 当前版本是原版（没装加载器）—— 模组根本无法加载
    static func noLoaderBody(pixelSize: String, gameVersion: String) -> String {
        indent
            + "你选择的皮肤尺寸是 \(pixelSize)，而 Java 版原版只支持 \(vanillaSizeHint)。"
            + "但当前版本 \(gameVersion) 是原版，未安装 Fabric / Forge / NeoForge 等加载器，"
            + "模组无法被加载 —— 请先安装一个加载器，再来装皮肤补丁。"
    }

    /// 还没选版本
    static func noVersionBody() -> String {
        indent + "尚未选择游戏版本，无法确定要安装哪个版本的补丁。请先在「游戏」页选择一个版本。"
    }

    /// 查询失败（网络等）
    static func queryFailedBody(pixelSize: String, reason: String) -> String {
        indent
            + "你选择的皮肤尺寸是 \(pixelSize)，而 Java 版原版只支持 \(vanillaSizeHint)。"
            + "但查询 \(SkinPatchCatalog.displayName) 版本时失败：\(reason)"
    }
}
