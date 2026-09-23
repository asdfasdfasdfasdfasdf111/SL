//
//  SkinDecoderTests.swift
//  qwqTests
//
//  覆盖 `Features/Skin/Module/SkinDecoder.swift` 的尺寸白名单，以及
//  `Features/Skin/SkinAvatarCropper.swift` 的 `validateSkin(at:)` 口径一致性。
//
//  背景（2026-09-24 修正的一处真实缺陷）：
//  `validateSkin` 曾放行 128×128，而 `cropAvatar` 只认 64×64 / 64×32 ——
//  于是「高清皮肤」能过校验、却在裁剪时抛错，用户看到的是与真实原因无关的
//  「不合法的图片 / 保存头像失败」。而按中文 Minecraft Wiki「皮肤」条目：
//  **Java 版皮肤上限为 64×64，128×128 是基岩版格式** —— 即 128 本就不该被放行。
//
//  这两个测试的作用是把这个约定钉死：白名单一旦再被加回 128，测试立刻失败。
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import qwq

final class SkinDecoderTests: XCTestCase {

    // MARK: - 测试数据构造

    /// 生成指定像素尺寸的纯色 PNG（不经 AppKit，可在任意线程调用）。
    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(data: nil, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "应能创建位图上下文"
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0))
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

    /// 把 PNG 写到临时文件，返回 URL 与清理闭包。
    private func makeTempSkinFile(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-skin-\(width)x\(height)-\(UUID().uuidString).png")
        try makePNG(width: width, height: height).write(to: url)
        return url
    }

    // MARK: - 白名单（SkinDecoder）

    /// 白名单必须**恰好**是 64×64 与 64×32。这条断言是防回退的主要闸门。
    func testSupportedPixelSizesExcludes128() async {
        let sizes = DefaultSkinDecoder.supportedPixelSizes
        XCTAssertEqual(sizes.count, 2, "白名单应只有 2 项，实际 \(sizes)")
        XCTAssertTrue(sizes.contains { $0.width == 64 && $0.height == 64 }, "应含 64×64")
        XCTAssertTrue(sizes.contains { $0.width == 64 && $0.height == 32 }, "应含 64×32")
        XCTAssertFalse(sizes.contains { $0.width == 128 && $0.height == 128 },
                       "128×128 是基岩版格式，Java 版启动器不得放行")
    }

    func testInspectAccepts64x64() async throws {
        let info = try DefaultSkinDecoder().inspect(makePNG(width: 64, height: 64))
        XCTAssertEqual(info.pixelWidth, 64)
        XCTAssertEqual(info.pixelHeight, 64)
        XCTAssertFalse(info.isLegacyFormat, "64×64 是新版格式，不是旧版")
        XCTAssertGreaterThan(info.byteCount, 0, "字节数应被如实记录")
    }

    func testInspectAccepts64x32AsLegacy() async throws {
        let info = try DefaultSkinDecoder().inspect(makePNG(width: 64, height: 32))
        XCTAssertEqual(info.pixelWidth, 64)
        XCTAssertEqual(info.pixelHeight, 32)
        XCTAssertTrue(info.isLegacyFormat, "64×32 应被标记为旧版格式（只有一层，无帽子图层）")
    }

    func testInspectRejects128x128() async throws {
        let data = try makePNG(width: 128, height: 128)
        XCTAssertThrowsError(try DefaultSkinDecoder().inspect(data)) { error in
            guard case SkinError.unsupportedDimensions(let width, let height) = error else {
                return XCTFail("应抛 unsupportedDimensions，实际抛的是 \(error)")
            }
            XCTAssertEqual(width, 128)
            XCTAssertEqual(height, 128)
        }
    }

    func testInspectRejectsUnreadableData() async {
        XCTAssertThrowsError(try DefaultSkinDecoder().inspect(Data("not a png".utf8))) { error in
            guard case SkinError.unreadableImage = error else {
                return XCTFail("非图像数据应抛 unreadableImage，实际抛的是 \(error)")
            }
        }
    }

    // MARK: - 校验口径（SkinAvatarCropper，与裁剪保持一致）

    func testValidateSkinAccepts64x64() async throws {
        let url = try makeTempSkinFile(width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try SkinAvatarCropper.validateSkin(at: url), "64×64 必须通过校验")
    }

    func testValidateSkinAccepts64x32() async throws {
        let url = try makeTempSkinFile(width: 64, height: 32)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try SkinAvatarCropper.validateSkin(at: url), "64×32 必须通过校验")
    }

    /// 修前此用例会失败（128×128 被放行）。文案里必须点明原因，否则用户拿不到可行动信息。
    func testValidateSkinRejects128WithActionableMessage() async throws {
        let url = try makeTempSkinFile(width: 128, height: 128)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SkinAvatarCropper.validateSkin(at: url)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("128×128"), "文案应指出实际尺寸，实际：\(message)")
            XCTAssertTrue(message.contains("基岩版"), "文案应解释 128×128 属基岩版格式，实际：\(message)")
            XCTAssertTrue(message.contains("64×64"), "文案应给出可用尺寸，实际：\(message)")
        }
    }

    /// 校验放行的尺寸必须真的能被裁剪 —— 这正是修前缺的那条约束
    /// （旧代码里 128×128 过了 validateSkin、却在 cropAvatar 抛错）。
    func testAcceptedSizeCanActuallyBeCropped() async throws {
        for (w, h) in [(64, 64), (64, 32)] {
            let url = try makeTempSkinFile(width: w, height: h)
            defer { try? FileManager.default.removeItem(at: url) }
            try SkinAvatarCropper.validateSkin(at: url)
            let avatar = try SkinAvatarCropper.cropAvatar(from: url)
            XCTAssertEqual(avatar.size.width, 128, "\(w)×\(h) 裁剪结果宽度应为 128")
            XCTAssertEqual(avatar.size.height, 128, "\(w)×\(h) 裁剪结果高度应为 128")
        }
    }
}
