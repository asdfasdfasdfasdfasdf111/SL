//
//  SkinPatchSupportTests.swift
//  qwqTests
//
//  覆盖「高清皮肤补丁（CustomSkinLoader）」功能的**纯逻辑**部分：
//  `Features/Skin/SkinHDSupport.swift`（尺寸分类 / 版本 id 拆分 / 文案）
//  与 `Features/Skin/SkinPatchCatalog.swift`（加载器闸门 `supports`）。
//
//  为什么值得专门测：这套逻辑里有**四处「不写测试就一定会被改坏」的约定** ——
//   1. 尺寸分类刻意**不猜**：非整倍数一律拒绝，装补丁也救不了（放宽它 = 骗用户）；
//   2. 版本 id 必须拆出纯游戏版本才能拿去过滤 Modrinth（带后缀会一条都查不到）；
//   3. 补丁必须**自己声明支持**当前加载器才能装（否则 Forge 包会进 Fabric 实例）；
//   4. 正文段落必须首行缩进两个全角空格（用户明确要求的排版，且不能混入 Markdown 标记）。
//  以上每一条都是「看起来能跑、但静默错」的类型，只有测试能钉住。
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import qwq

final class SkinPatchSupportTests: XCTestCase {

    // MARK: - 测试数据构造

    /// 生成指定像素尺寸的纯色 PNG（不经 AppKit，可在任意线程调用）。
    /// 与 `SkinDecoderTests.makePNG` 同一套写法 —— 刻意不共用，避免两个测试文件互相牵制。
    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(data: nil, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "应能创建位图上下文"
        )
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage(), "应能生成 CGImage")

        let buffer = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil),
            "应能创建 PNG 编码器"
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "PNG 编码应成功")
        return buffer as Data
    }

    /// 把 PNG 写到临时文件，返回 URL（调用方负责 `defer` 删除）。
    private func makeTempPNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-patch-\(width)x\(height)-\(UUID().uuidString).png")
        try makePNG(width: width, height: height).write(to: url)
        return url
    }

    /// 读 PNG **数据**的像素尺寸（走 ImageIO，不经 NSImage，避免「点 vs 像素」的歧义）。
    private func pixelSize(ofPNGData data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), "应能创建图像源")
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            "应能读出图像属性"
        )
        let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int, "应能读出像素宽")
        let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int, "应能读出像素高")
        return (width, height)
    }

    /// 造一个 Modrinth 版本对象（只填本功能用得到的字段）。
    private func makeVersion(versionNumber: String = "15.0.1-Universal",
                             gameVersions: [String] = ["1.21.1"],
                             loaders: [String],
                             filename: String = "CustomSkinLoader_Universal-15.0.1.jar") -> ModrinthVersion {
        ModrinthVersion(
            id: "test-version",
            name: versionNumber,
            version_number: versionNumber,
            game_versions: gameVersions,
            loaders: loaders,
            files: [
                ModrinthVersion.ModrinthFile(
                    url: "https://example.invalid/\(filename)",
                    filename: filename,
                    primary: true,
                    size: 1024,
                    hashes: ["sha1": "0000000000000000000000000000000000000000"]
                )
            ]
        )
    }

    /// 造一个 `SkinPatchCatalog.Patch`（用于文案测试）。
    private func makePatch(loaders: [String] = ["fabric", "forge", "neoforge", "quilt"],
                           verifiedLoader: ModLoader = .fabric) -> SkinPatchCatalog.Patch {
        let version = makeVersion(loaders: loaders)
        return SkinPatchCatalog.Patch(
            versionNumber: version.version_number,
            filename: version.files[0].filename,
            gameVersions: version.game_versions,
            loaders: version.loaders,
            verifiedLoader: verifiedLoader,
            version: version
        )
    }

    // MARK: - A. 尺寸分类

    /// 原版两种尺寸都必须判为「直接可用」—— 这类皮肤不需要任何补丁，卡片也不该弹。
    func testClassifyVanillaSizes() async {
        XCTAssertEqual(SkinSizeInspector.classify(width: 64, height: 64),
                       .vanillaSupported(width: 64, height: 64), "64×64 是新版原版尺寸")
        XCTAssertEqual(SkinSizeInspector.classify(width: 64, height: 32),
                       .vanillaSupported(width: 64, height: 32), "64×32 是旧版原版尺寸")
    }

    /// 整倍数高清尺寸：判定为「需要补丁」，且倍数算对、新旧布局分对。
    /// 这三条直接决定卡片正文里写「128×128」还是「192×192」、以及要不要提帽子图层。
    func testClassifyIntegerMultipleHD() async {
        XCTAssertEqual(SkinSizeInspector.classify(width: 128, height: 128),
                       .needsPatch(width: 128, height: 128, scale: 2, isLegacyLayout: false),
                       "128×128 = 64×64 的 2 倍，属新版布局")
        XCTAssertEqual(SkinSizeInspector.classify(width: 192, height: 192),
                       .needsPatch(width: 192, height: 192, scale: 3, isLegacyLayout: false),
                       "192×192 = 64×64 的 3 倍")
        XCTAssertEqual(SkinSizeInspector.classify(width: 256, height: 256),
                       .needsPatch(width: 256, height: 256, scale: 4, isLegacyLayout: false),
                       "256×256 = 64×64 的 4 倍")
        XCTAssertEqual(SkinSizeInspector.classify(width: 128, height: 64),
                       .needsPatch(width: 128, height: 64, scale: 2, isLegacyLayout: true),
                       "128×64 = 64×32 的 2 倍，属旧版布局（无帽子图层）")
        XCTAssertEqual(SkinSizeInspector.classify(width: 192, height: 96),
                       .needsPatch(width: 192, height: 96, scale: 3, isLegacyLayout: true),
                       "192×96 = 64×32 的 3 倍")
        XCTAssertEqual(SkinSizeInspector.classify(width: 256, height: 128),
                       .needsPatch(width: 256, height: 128, scale: 4, isLegacyLayout: true),
                       "256×128 = 64×32 的 4 倍")
    }

    /// **刻意不猜**：非整倍数尺寸一律拒绝。
    /// 放宽这一条等于告诉用户「装个补丁就能用」，而实际上装了什么都没用 —— 是最坏的一种错。
    func testClassifyRejectsNonIntegerMultiple() async {
        let rejected: [(Int, Int)] = [
            (100, 100),   // 既不是 64 的倍数，也不是它的整倍放大
            (32, 32),     // 比原版还小
            (64, 128),    // 长宽颠倒
            (64, 96),     // 高不是 32 的倍数
            (96, 64),     // 宽不是 64 的倍数
            (0, 0),       // 空图
            (-1, -1),     // 非法尺寸不应崩，应如实拒绝
        ]
        for (w, h) in rejected {
            XCTAssertEqual(SkinSizeInspector.classify(width: w, height: h),
                           .unsupported(width: w, height: h),
                           "\(w)×\(h) 不是合法的原版/整倍数尺寸，必须拒绝")
        }
    }

    /// `128×32` 单独一条：它宽是 64 的倍数、高也是 32 的倍数，**很容易被误判为合法的旧版布局**
    /// —— 但 128/64 = 2 而 32/32 = 1，两者不等，即它不是同一个倍数的放大，不是 2:1 布局。
    func testClassifyRejects128x32DespiteBothBeingMultiples() async {
        XCTAssertEqual(SkinSizeInspector.classify(width: 128, height: 32),
                       .unsupported(width: 128, height: 32),
                       "128×32 宽高倍数不一致（2 vs 1），必须拒绝 —— 这是最容易漏的一条")
    }

    // MARK: - B. 版本 id 拆分

    /// 加载器后缀要从**后往前**扫：`26.3-snapshot-3-Fabric` 最后一段才是加载器，
    /// 正着扫会把版本号里的 `3` 之类片段当候选（虽然本例不命中，但顺序错了迟早出事）。
    func testLoaderToken() async {
        XCTAssertEqual(SkinVersionIdentity.loaderToken(from: "1.21.1-Fabric"), "fabric")
        XCTAssertEqual(SkinVersionIdentity.loaderToken(from: "1.20.1-Forge"), "forge")
        XCTAssertEqual(SkinVersionIdentity.loaderToken(from: "1.21.1-NeoForge"), "neoforge")
        XCTAssertEqual(SkinVersionIdentity.loaderToken(from: "1.21.1-NeoForged"), "neoforged")
        XCTAssertEqual(SkinVersionIdentity.loaderToken(from: "1.21.1-Quilt"), "quilt")
        XCTAssertEqual(SkinVersionIdentity.loaderToken(from: "26.3-snapshot-3-Fabric"), "fabric",
                       "加载器在最后一段，必须从后往前扫才能找到")
        XCTAssertNil(SkinVersionIdentity.loaderToken(from: "26.2"), "纯版本号 = 原版，没有加载器后缀")
        XCTAssertNil(SkinVersionIdentity.loaderToken(from: "26.3-snapshot-3"), "快照版号里的 snapshot 不是加载器")
    }

    /// 加载器枚举映射。**返回 nil 是有意义的结果、不是失败**：
    /// 原版客户端加载不了模组，「装补丁」这条路根本不存在，界面必须如实说明。
    func testLoaderMapping() async {
        XCTAssertEqual(SkinVersionIdentity.loader(from: "1.21.1-Fabric"), .fabric)
        XCTAssertEqual(SkinVersionIdentity.loader(from: "1.20.1-Forge"), .forge)
        XCTAssertEqual(SkinVersionIdentity.loader(from: "1.21.1-NeoForge"), .neoforge)
        XCTAssertEqual(SkinVersionIdentity.loader(from: "1.21.1-NeoForged"), .neoforge,
                       "neoforged 是同一个加载器的另一种写法，必须映射到 .neoforge")
        XCTAssertEqual(SkinVersionIdentity.loader(from: "1.21.1-Quilt"), .quilt)
        XCTAssertNil(SkinVersionIdentity.loader(from: "26.2"), "原版没有加载器，返回 nil 而不是 .unknown")
    }

    /// 拆出纯游戏版本 —— 这是「拿版本 id 去过滤 Modrinth 一条都查不到」那个坑的正解。
    func testMinecraftVersionStripsLoaderSuffix() async {
        XCTAssertEqual(SkinVersionIdentity.minecraftVersion(from: "1.21.1-Fabric"), "1.21.1")
        XCTAssertEqual(SkinVersionIdentity.minecraftVersion(from: "1.20.1-Forge"), "1.20.1")
        XCTAssertEqual(SkinVersionIdentity.minecraftVersion(from: "1.21.1-NeoForge"), "1.21.1")
        XCTAssertEqual(SkinVersionIdentity.minecraftVersion(from: "26.3-snapshot-3-Fabric"), "26.3-snapshot-3",
                       "快照版的完整版本号（含 -snapshot-3）必须保留，只去掉加载器后缀")
        XCTAssertEqual(SkinVersionIdentity.minecraftVersion(from: "26.2"), "26.2",
                       "无加载器后缀的原样返回")
    }

    /// **机器化保证**：拆出来的游戏版本里不能再残留任何加载器词。
    /// 一旦这条失败，就意味着会拿 `1.21.1-Fabric` 这种值去查 Modrinth —— 上游没有这个版本号，
    /// 结果是「明明有补丁却查不到」，而且不报错、只是静默走 noPatch 分支。
    func testStrippedVersionCarriesNoLoaderToken() async {
        let versionIDs = [
            "1.21.1-Fabric", "1.20.1-Forge", "1.21.1-NeoForge",
            "1.21.1-NeoForged", "1.21.1-Quilt", "1.21.1-Rift",
            "26.3-snapshot-3-Fabric", "26.1.1-Forge", "26.2",
        ]
        for id in versionIDs {
            let stripped = SkinVersionIdentity.minecraftVersion(from: id)
            XCTAssertNil(SkinVersionIdentity.loaderToken(from: stripped),
                         "\(id) 拆出的 \"\(stripped)\" 仍带加载器词 —— 拿它查 Modrinth 会查不到")
        }
    }

    // MARK: - C. 加载器闸门（最后一道防线）

    /// 固定项目 id：防止哪天有人手滑把补丁指向另一个模组而没有任何测试发现。
    func testCatalogPinsExpectedProject() async {
        XCTAssertEqual(SkinPatchCatalog.projectID, "idMHQ4n2")
        XCTAssertEqual(SkinPatchCatalog.slug, "customskinloader")
    }

    /// Universal 单包：声明支持四种加载器时，四种都应放行。
    /// （CustomSkinLoader 上游现状即如此：只发一个 `CustomSkinLoader_Universal-x.y.z.jar`。）
    func testSupportsAcceptsUniversalBuild() async {
        let universal = makeVersion(loaders: ["fabric", "forge", "neoforge", "quilt"])
        for loader in [ModLoader.fabric, .forge, .neoforge, .quilt] {
            XCTAssertTrue(SkinPatchCatalog.supports(universal, loader: loader),
                          "Universal 包声明支持 \(loader.rawValue)，应放行")
        }
    }

    /// **这就是「万一下一个 forge 的 mod 回来呢」的防线**：
    /// 上游返回一个只声明 forge 的构建时，绝不能把它当 fabric 用 —— 装进 Fabric 实例游戏会直接报错。
    /// 本工程的做法是「查到之后**再审一遍**」，而不是只信查询参数传对了。
    func testSupportsRejectsWrongLoaderBuild() async {
        let forgeOnly = makeVersion(versionNumber: "15.0.1-Forge",
                                    loaders: ["forge"],
                                    filename: "CustomSkinLoader_Forge-15.0.1.jar")
        XCTAssertTrue(SkinPatchCatalog.supports(forgeOnly, loader: .forge), "forge 包对 forge 是合法的")
        XCTAssertFalse(SkinPatchCatalog.supports(forgeOnly, loader: .fabric),
                       "forge 专用包绝不能当成 fabric 包 —— 这正是加载器闸门要拦的")
        XCTAssertFalse(SkinPatchCatalog.supports(forgeOnly, loader: .neoforge),
                       "neoforge 也不是 forge 的别名（Modrinth 的 loaders 字段里两者分开）")
        XCTAssertFalse(SkinPatchCatalog.supports(forgeOnly, loader: .quilt))
    }

    /// 加载器列表为空 = 谁都不支持。上游偶有这种残缺数据，必须当作「没有可用版本」而不是默认放行。
    func testSupportsRejectsEmptyLoaderList() async {
        let empty = makeVersion(loaders: [])
        for loader in [ModLoader.fabric, .forge, .neoforge, .quilt] {
            XCTAssertFalse(SkinPatchCatalog.supports(empty, loader: loader),
                           "loaders 为空的版本不能默认放行")
        }
    }

    // MARK: - D. 文案

    /// 缩进常量本身必须是**两个全角空格**（`\u{3000}` 各一个）。
    /// 半角空格在中文正文里只有半个字宽，看起来就不对；这条把「两格」的字面量钉死。
    func testIndentIsTwoFullWidthSpaces() async {
        XCTAssertEqual(SkinPatchCopy.indent, "\u{3000}\u{3000}",
                       "首行缩进必须是两个全角空格")
        XCTAssertEqual(SkinPatchCopy.indent.count, 2, "缩进恰好两个字符")
    }

    /// 每个正文段落都必须以缩进开头 —— 这是「正文首行缩进两格」的机器化保证。
    /// ⚠️ 缩进是拼在字符串**开头**的，不是靠 SwiftUI 的 padding 模拟：
    /// 拼字符串只影响首行，padding 会把整段（含折行）都推进去，视觉上是两回事。
    func testAllBodiesStartWithIndent() async {
        let patch = makePatch()
        let bodies: [String] = [
            SkinPatchCopy.checkingBody(),
            SkinPatchCopy.availableBody(pixelSize: "128×128", patch: patch,
                                        gameVersion: "1.21.1", loader: .fabric),
            SkinPatchCopy.noPatchBody(pixelSize: "128×128", gameVersion: "26.3-snapshot-3", loader: .fabric),
            SkinPatchCopy.noLoaderBody(pixelSize: "128×128", gameVersion: "26.2"),
            SkinPatchCopy.noVersionBody(),
            SkinPatchCopy.queryFailedBody(pixelSize: "128×128", reason: "连不上网络"),
        ]
        for body in bodies {
            XCTAssertTrue(body.hasPrefix(SkinPatchCopy.indent),
                          "正文必须以两个全角空格开头，实际：\(body.prefix(12))…")
        }
    }

    /// 文案里不能出现 `**`：SwiftUI 的 `Text(String)` **不解析 Markdown**，
    /// `**粗体**` 会被原样显示成带星号的文字（本功能开发过程中真的踩过一次）。
    func testCopyContainsNoMarkdownMarkers() async {
        let patch = makePatch()
        let bodies: [String] = [
            SkinPatchCopy.title,
            SkinPatchCopy.vanillaSizeHint,
            SkinPatchCopy.checkingBody(),
            SkinPatchCopy.availableBody(pixelSize: "128×128", patch: patch,
                                        gameVersion: "1.21.1", loader: .fabric),
            SkinPatchCopy.noPatchBody(pixelSize: "128×128", gameVersion: "26.3-snapshot-3", loader: .fabric),
            SkinPatchCopy.noLoaderBody(pixelSize: "128×128", gameVersion: "26.2"),
            SkinPatchCopy.noVersionBody(),
            SkinPatchCopy.queryFailedBody(pixelSize: "128×128", reason: "连不上网络"),
        ]
        for body in bodies {
            XCTAssertFalse(body.contains("**"), "文案不得含 Markdown 标记（Text 不解析）：\(body)")
            XCTAssertFalse(body.contains("##"), "文案不得含 Markdown 标题标记：\(body)")
        }
    }

    /// 可安装文案必须**如实给出文件名与上游声明的加载器列表** ——
    /// 这是「凭什么说这个包适用于当前加载器」的唯一凭据，摆在用户眼前比藏在代码里更经得起追问。
    func testAvailableBodyExposesFilenameAndLoaders() async {
        let patch = makePatch()
        let text = SkinPatchCopy.availableBody(pixelSize: "128×128", patch: patch,
                                               gameVersion: "1.21.1", loader: .fabric)
        XCTAssertTrue(text.contains(patch.filename), "正文应写明要装的 jar 文件名，实际：\(text)")
        XCTAssertTrue(text.contains("128×128"), "正文应写明用户选的尺寸")
        XCTAssertTrue(text.contains("1.21.1"), "正文应写明目标游戏版本")
        XCTAssertTrue(text.contains("Fabric"), "正文应写明目标加载器（显示名）")
        XCTAssertTrue(text.contains(SkinPatchCatalog.chineseName), "正文应带上社区通用中文名，便于用户认出来")
    }

    // MARK: - E. 真实图片路径

    /// 像素尺寸读取：必须看**真实像素**而不是 NSImage 的「点」尺寸
    /// （带 DPI 元信息的 PNG 会让「点」尺寸算错，进而算错倍数）。
    func testPixelSizeReadsTruePixels() async throws {
        let url = try makeTempPNG(width: 128, height: 128)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try XCTUnwrap(SkinSizeInspector.pixelSize(of: url), "应能读出像素尺寸")
        XCTAssertEqual(size.width, 128)
        XCTAssertEqual(size.height, 128)
    }

    func testPixelSizeReturnsNilForNonImage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-not-an-image-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(SkinSizeInspector.pixelSize(of: url), "非图像数据应返回 nil 而不是崩")
    }

    /// 降采样：启动器自身的头像管线（`SkinLayerView.cropped` / `SkinAvatarCropper`）取景坐标
    /// 是按 64×64 布局写死的，把 128×128 直接喂进去会**取错区域**、头像错位 ——
    /// 所以高清皮肤在「启动器显示」这一侧必须先降到原版尺寸。
    func testVanillaDownscaleProducesVanillaSizes() async throws {
        let cases: [(input: (Int, Int), expected: (Int, Int))] = [
            ((128, 128), (64, 64)),
            ((256, 256), (64, 64)),
            ((128, 64), (64, 32)),
            ((256, 128), (64, 32)),
            ((64, 64), (64, 64)),   // 幂等：原版尺寸过一遍仍是原版尺寸
            ((64, 32), (64, 32)),
        ]
        for (input, expected) in cases {
            let url = try makeTempPNG(width: input.0, height: input.1)
            defer { try? FileManager.default.removeItem(at: url) }

            let data = try SkinSizeInspector.vanillaSizedPNGData(from: url)
            let out = try pixelSize(ofPNGData: data)
            XCTAssertEqual(out.width, expected.0, "\(input.0)×\(input.1) 降采样后宽应为 \(expected.0)")
            XCTAssertEqual(out.height, expected.1, "\(input.0)×\(input.1) 降采样后高应为 \(expected.1)")
        }
    }

    /// 降采样产物必须能被 `SkinAvatarCropper.cropAvatar` 真正裁剪 ——
    /// 这正是「校验放行的尺寸必须真的能用」的那条约束（历史上 128×128 过了校验却在裁剪处抛错）。
    func testDownscaledOutputIsAcceptedByAvatarCropper() async throws {
        let url = try makeTempPNG(width: 128, height: 128)
        defer { try? FileManager.default.removeItem(at: url) }

        let vanillaData = try SkinSizeInspector.vanillaSizedPNGData(from: url)
        let vanillaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-downscaled-\(UUID().uuidString).png")
        try vanillaData.write(to: vanillaURL)
        defer { try? FileManager.default.removeItem(at: vanillaURL) }

        XCTAssertNoThrow(try SkinAvatarCropper.validateSkin(at: vanillaURL),
                         "降采样产物必须是原版可用尺寸")
        let avatar = try SkinAvatarCropper.cropAvatar(from: vanillaURL)
        XCTAssertEqual(avatar.size.width, 128)
        XCTAssertEqual(avatar.size.height, 128)
    }
}
