import SwiftUI
import AppKit
import CoreGraphics

/// 皮肤贴图的**单层**渲染（头 / 帽各用一个实例，叠起来才是完整头像）。
/// ⚠️ `image` 是可选：裁剪失败时为 nil，此时渲染成透明占位而**不是跳过该层** ——
/// 这样上下层图层的尺寸与位置不受影响（有头无帽时头像不会歪）。
struct SkinLayerView: View {
    /// 预裁成品（后台裁剪缓存），主线程渲染路径零 CoreImage。
    let image: NSImage?
    /// 目标尺寸，由调用方按比例算好（本视图不做等比计算）。
    let width: CGFloat
    let height: CGFloat

    /// 显式写出 init（与合成的签名相同）：让「三个参数都必填、都按声明顺序」这件事
    /// 在代码里可见。
    init(image: NSImage?, width: CGFloat, height: CGFloat) {
        self.image = image
        self.width = width
        self.height = height
    }

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    // ⚠️ `.interpolation(.none)` 必须保留：皮肤是 8×8 像素贴图，
                    // 默认插值在任意缩放下都会把它糊掉，关掉才是清晰的像素风。
                    .interpolation(.none)
                    .resizable()
                    .frame(width: width, height: height)
            } else {
                // 数据无效时兜底透明，不阻塞布局 —— 用 Color.clear 占位而不是 EmptyView，
                // 保证本层在布局里仍有尺寸（否则叠放的头 / 帽会跑位）。
                Color.clear
            }
        }
    }

    /// 后台调用的静态裁剪：yOffset 兼容 64 高（带帽层）与 32 高（旧版无帽）两种贴图
    ///
    /// 显式 `nonisolated`：工程启用 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不标注会被
    /// 推断为主 actor 隔离；调用方 `LaunchAvatarSkinViewModel.refreshSkinData()` 在
    /// `Task.detached` 里同步调用本方法，隔离不匹配会产生
    /// 「main actor-isolated static method called from outside of the actor」告警
    ///（Swift 6 语言模式下是错误），且会让本方法承诺的「后台裁剪、主线程零 CoreImage」落空
    /// —— 被隔离的方法无法在非隔离上下文里真正跑在后台。
    /// 函数体只用 CIImage / CIContext / NSImage，不触碰任何主 actor 状态（纯计算），
    /// 因此标注 nonisolated 是语义正确的，不是为了消除告警的妥协。
    nonisolated static func cropped(imageData: Data, startX: CGFloat, startY: CGFloat) -> NSImage? {
        guard var ciImage = CIImage(data: imageData) else { return nil }
        let h = ciImage.extent.height
        let yOffset: CGFloat = (h == 32 || h == 64) ? (h == 32 ? 0 : 32) : 0
        ciImage = ciImage.cropped(to: CGRect(x: startX, y: startY + yOffset, width: 8, height: 8))
        let context = CIContext(options: nil)
        let extent = ciImage.extent
        guard let cgImage = context.createCGImage(ciImage, from: extent) else { return nil }
        return NSImage(cgImage: cgImage, size: extent.size)
    }
}

/// 在 SwiftUI 里用 AppKit 的毛玻璃（`NSVisualEffectView`）。
/// ⚠️ 只做「创建时设一次 + 更新时同步两个属性」，**不处理**主题/外观变化 ——
/// `state` 恒为 `.active`（窗口失焦时毛玻璃不会跟着变灰）。
struct BlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .contentBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.active` = 始终按活跃窗口渲染毛玻璃，不随窗口失焦变灰。
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// 赞助方式卡片：180×180 固定方块，上方图片 + 下方标题。
/// 图片资源缺失时**降级成灰底 + 「图片缺失」文案**而非留空 —— 便于一眼看出是资源问题。
struct SponsorCard: View {
    let imageName: String
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            if let image = NSImage(named: imageName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
                    .cornerRadius(0)
                    .shadow(radius: 2)
            } else {
                // 资源缺失的降级占位，高度与真实图片一致（120）以免卡片高度跳变。
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 120)
                    .overlay(Text("图片缺失").foregroundColor(.secondary))
            }
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
        }
        .padding()
        .frame(width: 180, height: 180)
        .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial).shadow(radius: 6))
    }
}

/// 致谢卡片：与 SponsorCard 同尺寸、同底材，只有内容不同（一段固定文案）。
struct ThanksCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("致谢")
                .font(.largeTitle.bold())
                .foregroundColor(.primary)
                .padding(.top, 20)
            
            Text("感谢所有给我这个不成熟启动器作者一些赞助的赞助者，谢谢你们，真的感谢！")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            
            Spacer()
        }
        .padding()
        .frame(width: 180, height: 180)
        .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial).shadow(radius: 6))
    }
}

extension NSImage {
    /// 转 PNG 字节。**任何一步失败都返回 nil**（无 tiff 表示 / 建不出位图 / 编码失败）。
    /// ⚠️ 中途经 TIFF 再转 PNG：对带 alpha 的图片无损，但会丢掉 NSImage 的「尺寸」元信息
    /// —— 皮肤校验只关心像素数据，够用。
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 写 PNG 到磁盘。与 `pngData()` 的「返回 nil」不同，这里**抛错**：
    /// 转换失败抛 `skinValidationFailed("无法转换为 PNG")`、写盘失败抛 IO 错误 ——
    /// 调用方能区分「图有问题」与「盘有问题」。`.atomic` 避免留下半截文件。
    func writePNG(to url: URL) throws {
        guard let data = pngData() else {
            throw LauncherError.skinValidationFailed("无法转换为 PNG")
        }
        try data.write(to: url, options: .atomic)
    }
}
