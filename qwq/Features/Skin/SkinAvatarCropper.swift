import Foundation
import AppKit
import CoreGraphics

// MARK: - 皮肤头像裁剪（纯图像逻辑，无副作用，自 MinecraftSkinManager 拆出）

/// 皮肤头像裁剪（**纯图像计算、无副作用**）—— 不读写文件、不改全局状态。
/// ⚠️ 本类型走 CoreGraphics（`cropping` + `CGContext` 合成），与
/// `UI/ViewComponents.swift` 里 `SkinLayerView.cropped` 走 CoreImage 的实现是**两套独立代码**：
/// 这里产出「头 + 帽已合成好的整张头像」，那里产出「单独一层」。改其一别以为改了另一处。
enum SkinAvatarCropper {
    /// 头像取景方向（皮肤展开图坐标）。
    /// ⚠️ 六个方向里四个只改 x（y 恒为 8），只有顶 / 底把 y 换成 0 ——
    /// 这是按 **64×64 新版布局**写死的，32×32 旧布局的贴图区并不相同。
    enum HeadDirection {
        case front, back, left, right, top, bottom
        /// 该方向对应的裁剪起点。返回元组而非 CGRect：宽高恒为 8×8，没必要重复表达。
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

    /// 校验皮肤图是否可接受：**只校验尺寸**，不检查内容（全黑图也会通过）。
    /// 只接受两种尺寸：64×64（1.8+ 新版，含帽子图层）、64×32（1.8 之前的旧版，只有一层）。
    ///
    /// ⚠️ **128×128 不接受**（2026-09-24 修正）。Java 版皮肤的最大尺寸就是 64×64；
    /// 128×128 是**基岩版**的格式。依据：中文 Minecraft Wiki「皮肤」条目原文 ——
    /// 「在Java版中，皮肤的尺寸最大可达64×64；……在基岩版中，皮肤的尺寸最大可达128×128，
    /// 64×64的尺寸仍然适用」。故 128×128 不是「还没支持的高清格式」，而是本就不适用于 Java 版。
    ///
    /// 修前本方法**错误地放行 128×128**，而 `cropAvatar` 只认 64×64 / 64×32 ——
    /// 于是高清皮肤能过校验、却在裁剪时抛错，用户看到的是「不合法的图片 / 保存头像失败」
    /// 这句与真实原因无关的提示（且此时皮肤原图已被写入磁盘，见 OfflineSkinService 的顺序修正）。
    /// 现在两处口径一致，白名单与 `Module/SkinDecoder.swift` 的 `supportedPixelSizes` 同一语义。
    static func validateSkin(at url: URL) throws {
        guard let image = NSImage(contentsOf: url) else {
            throw LauncherError.skinValidationFailed("无法读取图片")
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LauncherError.skinValidationFailed("无法获取图像数据")
        }
        let w = cgImage.width, h = cgImage.height
        guard (w == 64 && h == 64) || (w == 64 && h == 32) else {
            // 128×128 单独给一句解释：它是最容易被误当成「应该支持」的尺寸（基岩版格式）。
            let hint = (w == 128 && h == 128) ? "；128×128 是基岩版皮肤格式，Java 版不支持" : ""
            throw LauncherError.skinValidationFailed("Java 版皮肤必须是 64×64 或 64×32，当前为 \(w)×\(h)\(hint)")
        }
    }

    /// 从皮肤原图裁剪正面头像：64 像素高度时叠加 layer1（头）与 layer2（帽）消除半透明，
    /// 32 像素高度（旧格式）直接用头图层；结果缩放至 targetSize。
    /// 裁剪正面头像：头层（layer1）与帽层（layer2）在 8×8 画布上叠加合成，再放大到目标尺寸。
    /// 32×32 旧格式没有帽层，直接用头层。
    /// 尺寸口径与 `validateSkin(at:)` 一致：只接受 64×64 / 64×32（128×128 属基岩版格式，两处都拒绝）。
    /// 任何一步失败都**抛错**（本文件不返回可选值），错误文案会直接展示给用户。
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
        // CGImage/CIImage 的像素行顺序与 Minecraft 皮肤贴图一致：row 0 = 顶部。
        // 因此 Minecraft 坐标 (x, y) 直接对应裁剪 rect (x, y, 8, 8)，无需翻转。
        let layer1Rect = CGRect(x: 8, y: 8, width: 8, height: 8)
        guard let layer1 = cgImage.cropping(to: layer1Rect) else {
            throw LauncherError.skinValidationFailed("无法裁剪第一层")
        }
        if height == 32 {
            return try zoomImage(layer1, to: targetSize)
        }
        // 帽层（layer2）在贴图右侧 x=40 处 —— 与头层同 y，只有 x 不同。
        // ⚠️ 这个坐标属于「图层体系」，与上面 HeadDirection 的「取景方向体系」不是一回事。
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
        // 先画头层再画帽层：后者覆盖前者，半透明像素自然混合 —— 这就是「消除半透明」的做法。
        // 顺序不能反，反过来帽子会被头盖住。
        context.draw(layer1, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        context.draw(layer2, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let finalHead = context.makeImage() else {
            throw LauncherError.skinValidationFailed("无法合成头像")
        }
        return try zoomImage(finalHead, to: targetSize)
    }

    /// 最近邻缩放到目标尺寸（保持像素风格，不做平滑）。
    /// ⚠️ 用的是 `lockFocus` / `unlockFocus` 这条较老的 API：它依赖「当前 NSGraphicsContext」，
    /// 在非主线程调用并不安全 —— 调用方需自行保证线程（本类型未标注 nonisolated）。
    private static func zoomImage(_ cgImage: CGImage, to targetSize: NSSize) throws -> NSImage {
        let finalImage = NSImage(size: targetSize)
        finalImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cgImage, size: targetSize).draw(in: NSRect(origin: .zero, size: targetSize))
        finalImage.unlockFocus()
        return finalImage
    }
}
