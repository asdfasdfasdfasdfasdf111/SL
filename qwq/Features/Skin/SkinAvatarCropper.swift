import Foundation
import AppKit
import CoreGraphics

// MARK: - 皮肤头像裁剪（纯图像逻辑，无副作用，自 MinecraftSkinManager 拆出）

enum SkinAvatarCropper {
    /// 头像取景方向（皮肤展开图坐标）
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

    /// 校验皮肤图片合法性：必须是标准尺寸（64×64 / 64×32 / 128×128）
    static func validateSkin(at url: URL) throws {
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

    /// 从皮肤原图裁剪正面头像：64 像素高度时叠加 layer1（头）与 layer2（帽）消除半透明，
    /// 32 像素高度（旧格式）直接用头图层；结果缩放至 targetSize。
    static func cropAvatar(from url: URL, targetSize: NSSize = NSSize(width: 128, height: 128)) throws -> NSImage {
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

    /// 最近邻缩放到目标尺寸（保持像素风格，不做平滑）
    private static func zoomImage(_ cgImage: CGImage, to targetSize: NSSize) throws -> NSImage {
        let finalImage = NSImage(size: targetSize)
        finalImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cgImage, size: targetSize).draw(in: NSRect(origin: .zero, size: targetSize))
        finalImage.unlockFocus()
        return finalImage
    }
}
