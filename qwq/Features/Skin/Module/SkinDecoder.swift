//
//  SkinDecoder.swift
//  模块化拆分：Skin 模块的图像解码协议与最小实现
//
//  既有实现散在 `qwq/Features/Skin/`：
//  - `SkinAvatarCropper`：校验尺寸（64×64 / 64×32 / 128×128）并裁剪头像
//  - `SkinExtractor`：从游戏 JAR 提取默认皮肤
//  - `MinecraftSkinManager`：皮肤文件持久化
//  - `SkinResourcePackApplier`：生成离线皮肤资源包
//  本模块把这些能力收敛为协议，UI 只依赖协议。
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - 模块错误

/// Skin 模块的统一错误类型。
///
/// 收敛三类失败：图像不可读、尺寸不在白名单、资源包生成失败
/// （后者由既有 `SkinResourcePackApplier` 抛出的错误映射而来）。
enum SkinError: LocalizedError {

    /// 数据不是可识别的图像
    case unreadableImage

    /// 图像尺寸不在支持的范围内
    case unsupportedDimensions(width: Int, height: Int)

    /// 资源包生成或移除失败
    case resourcePackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "无法读取皮肤图片"
        case .unsupportedDimensions(let width, let height):
            return "不支持的皮肤尺寸：\(width)×\(height)"
        case .resourcePackFailed(let reason):
            return "皮肤资源包处理失败：\(reason)"
        }
    }
}

// MARK: - 图像信息

/// 皮肤图像的只读描述。
struct SkinImageInfo: Sendable, Hashable {

    /// 像素宽
    let pixelWidth: Int

    /// 像素高
    let pixelHeight: Int

    /// 图像数据的字节数
    let byteCount: Int

    /// 是否为旧版 64×32 皮肤（`SkinAvatarCropper` 对该尺寸只取头图层，不叠加帽子图层）
    var isLegacyFormat: Bool { pixelWidth == 64 && pixelHeight == 32 }
}

// MARK: - 解码协议

/// 皮肤图像解码与校验。
///
/// 只做「读懂图片」：读取像素尺寸并做合法性校验，不落盘、不裁剪、不依赖 AppKit 渲染。
protocol SkinDecoder: Sendable {

    /// 读取皮肤图像的尺寸信息并校验合法性。尺寸不在白名单时抛 `SkinError.unsupportedDimensions`。
    func inspect(_ data: Data) throws -> SkinImageInfo
}

// MARK: - 最小实现

/// 基于 ImageIO 的最小实现。
///
/// 尺寸白名单与 `SkinAvatarCropper.validateSkin(at:)` 完全一致（64×64 / 64×32 / 128×128），
/// 但改用 `CGImageSource` 直读像素尺寸：不经过 `NSImage`，因此可在任意线程调用。
struct DefaultSkinDecoder: SkinDecoder {

    /// 支持的像素尺寸白名单。与 `SkinAvatarCropper.validateSkin(at:)` 的判定保持同步。
    static let supportedPixelSizes: [(width: Int, height: Int)] = [
        (64, 64),
        (64, 32),
        (128, 128)
    ]

    func inspect(_ data: Data) throws -> SkinImageInfo {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SkinError.unreadableImage
        }
        let width = image.width
        let height = image.height
        guard Self.supportedPixelSizes.contains(where: { $0.width == width && $0.height == height }) else {
            throw SkinError.unsupportedDimensions(width: width, height: height)
        }
        return SkinImageInfo(pixelWidth: width, pixelHeight: height, byteCount: data.count)
    }
}
