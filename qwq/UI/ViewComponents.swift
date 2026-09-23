import SwiftUI
import AppKit
import CoreGraphics

struct SkinLayerView: View {
    /// 预裁成品（后台裁剪缓存），主线程渲染路径零 CoreImage
    let image: NSImage?
    let width: CGFloat
    let height: CGFloat

    init(image: NSImage?, width: CGFloat, height: CGFloat) {
        self.image = image
        self.width = width
        self.height = height
    }

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: width, height: height)
            } else {
                // 数据无效时兜底透明，不阻塞布局
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

struct BlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .contentBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

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
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func writePNG(to url: URL) throws {
        guard let data = pngData() else {
            throw LauncherError.skinValidationFailed("无法转换为 PNG")
        }
        try data.write(to: url, options: .atomic)
    }
}
