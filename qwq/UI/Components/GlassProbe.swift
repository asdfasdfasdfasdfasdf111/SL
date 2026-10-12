//
//  GlassProbe.swift
//  浮层「背后有没有毛玻璃」的运行时几何探测。
//
//  为什么需要它（用户定稿 2026-10-12）：
//  浮层压在毛玻璃之上时会**两层玻璃叠影**（更白、糊视野）。以前的解法是给每个
//  浮层硬编码「要不要垫背景」——一旦面板挪位置、改尺寸，硬编码就失效。
//  用户要求的规则：**浮层出现的瞬间，几何检测它背后有没有毛玻璃；触碰面积
//  达到 5% 就垫一块背景把下面整块盖住，否则不垫**。
//
//  判定对象：全 App 唯一的 NSVisualEffectView 真毛玻璃是 HomeHeader
//  （见 UI/Shell/HomeHeader.swift，它挂了同名 coordinateSpace）。
//  其余「玻璃」都是 SwiftUI 半透明白填充，不参与本判定 —— 它们本来就会被
//  浮层的不透明底盖住，没有叠影问题。
//
//  阈值 5% 的依据：完全压住（100%）与擦个边（<5%）是两种场景；5% 意味着
//  「确实压在玻璃上且占了一块可见面积」，此时不垫就会看到叠影。
//

import SwiftUI

/// 浮层背后毛玻璃的几何探测器。
///
/// 用法：给浮层套 `.modifier(GlassProbeModifier(enabled:))`，
/// 或在 `GeometryReader` 里直接调 `GlassProbe.overlapRatio(_:in:)`。
enum GlassProbe {

    /// HomeHeader 挂载的坐标空间名（探测的锚点）。
    static let spaceName = "SLGlassProbeSpace"

    /// 触碰面积占比阈值：达到就启用「垫背景」。
    static let threshold: CGFloat = 0.05

    /// 计算 `rect` 与毛玻璃（HomeHeader）的触碰面积占 `rect` 自身的比例。
    ///
    /// - Parameters:
    ///   - rect: 浮层在 `space` 坐标系里的矩形
    ///   - proxy: 能读出毛玻璃 frame 的 GeometryProxy（通常是浮层所在的容器）
    /// - Returns: 0...1 的占比；探测不到毛玻璃（未挂 coordinateSpace）时返回 0
    static func overlapRatio(_ rect: CGRect, in proxy: GeometryProxy) -> CGFloat {
        // `frame(in:)` 返回 CGRect：坐标空间存在时是真实矩形；不存在时是 .zero
        // （SwiftUI 对未知 coordinateSpace 返回 .zero 而非崩溃），用 .zero 兜底即可。
        let glass = proxy.frame(in: .named(spaceName))
        guard glass.width > 0, glass.height > 0,
              rect.width > 0, rect.height > 0 else { return 0 }
        let intersection = rect.intersection(glass)
        guard !intersection.isNull else { return 0 }
        let touchArea = intersection.width * intersection.height
        return touchArea / (rect.width * rect.height)
    }
}

/// 把「背后有毛玻璃就垫背景」套到任意浮层上。
///
/// 实现要点：
/// - 用 `GeometryReader` 在**布局之后**读自己的 frame（SwiftUI 保证 onAppear 时
///   frame 已可用，所以「浮层出现的那一刻」= onAppear + 首次布局）；
/// - 只在「占比跨越阈值」时写 `@State`，不会每帧重算（避免布局抖动）；
/// - `enabled = false` 时整体不生效（给不需要此行为的浮层用）。
struct GlassProbeModifier: ViewModifier {
    /// 是否启用探测（浮层自己决定要不要参与）
    var enabled: Bool
    /// 触碰面积占比 ≥ 阈值时要替换成的背景（不透明底 + tint）
    var backdrop: AnyView

    @State private var overlapsGlass = false

    func body(content: Content) -> some View {
        if enabled {
            GeometryReader { proxy in
                content
                    .background(overlapsGlass ? backdrop : nil)
                    .onAppear {
                        let rect = proxy.frame(in: .named(GlassProbe.spaceName))
                        overlapsGlass = GlassProbe.overlapRatio(rect, in: proxy) >= GlassProbe.threshold
                    }
            }
        } else {
            content
        }
    }
}

extension View {
    /// 浮层通用：探测背后有没有毛玻璃，触碰面积 ≥5% 就垫一块不透明背景盖住下层。
    /// - Parameters:
    ///   - enabled: 是否启用探测
    ///   - shape: 背景形状（与浮层外形一致）
    ///   - tint: 玻璃面提亮（各浮层的定稿数值）
    func glassProbeBackdrop<S: SwiftUI.Shape>(enabled: Bool = true,
                                              shape: S,
                                              tint: Color) -> some View {
        modifier(GlassProbeModifier(
            enabled: enabled,
            backdrop: AnyView(FloatingGlass(shape: shape, tint: tint))
        ))
    }
}
