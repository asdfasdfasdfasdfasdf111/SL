import SwiftUI
import AppKit
import CoreGraphics

struct PixelArtImageView: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: size, height: size)
    }
}

struct SkinLayerView: View {
    let imageData: Data
    let startX: CGFloat
    let startY: CGFloat
    let width: CGFloat
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: width, height: height)
            } else {
                Color.clear
            }
        }
        .onAppear {
            // ⚠️ self.image 是 @State：onAppear 处于视图更新事务中，同步写会触发
            // "Modifying state during view update"（UAF 前兆）。本组件正属皮肤头像裁剪链
            // （0x26fffc2cb 崩溃地址内容为 ARGB 像素值），必须延迟到渲染事务外写
            DispatchQueue.main.async {
                if var ciImage = CIImage(data: imageData) {
                    let yOffset: CGFloat = ciImage.extent.height == 32 ? 0 : 32
                    ciImage = ciImage.cropped(to: CGRect(x: startX, y: startY + yOffset, width: 8, height: 8))
                    let context = CIContext(options: nil)
                    let extent = ciImage.extent
                    guard let cgImage = context.createCGImage(ciImage, from: extent) else { return }
                    self.image = NSImage(cgImage: cgImage, size: ciImage.extent.size)
                }
            }
        }
    }
}

struct LogView: View {
    @Binding var logs: [String]
    @State private var scrollTarget: Int?
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(logs.indices, id: \.self) { idx in
                        Text(logs[idx])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .frame(width: 260, height: 300)
            .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial).shadow(radius: 4))
            .onChange(of: logs.count) { _ in
                // ⚠️ onChange 处于视图更新事务中，同步 scrollTo 会强制 layout，
                // 触发 AppKit "It's not legal to call -layoutSubtreeIfNeeded..." 布局递归警告；
                // 延迟到渲染事务外滚动
                DispatchQueue.main.async {
                    withAnimation(.exaggeratedSpring) {
                        proxy.scrollTo(logs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
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
    @ObservedObject var theme = ThemeManager.shared
    
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
    @ObservedObject var theme = ThemeManager.shared
    
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

struct ComingSoonCardView: View {
    let title: String
    var body: some View {
        VStack {
            Spacer()
            Text(title).font(.title2).foregroundColor(.secondary)
            Text("待开发").font(.headline).foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(width: 280, height: 200)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial).shadow(radius: 4))
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
        try data.write(to: url)
    }
}