//
//  ContentCard.swift
//  模块化拆分：从 GameViews.swift 拆出（原文件 2776 行，拆分后职责单一、可读性提升）
//

import SwiftUI
import AppKit

struct ContentCard: View {
    let title: String
    let subtitle: String
    let cardWidth: CGFloat
    var tags: [String] = []
    var action: (() -> Void)? = nil
    /// 本卡是否属于「刚由联网搜索响应写回的那一批结果」（已接线的搜索结果弹入开关）。
    /// 数据来源：`DownloadCategoryViewModel.searchPopInIds`
    /// （在 `applyFilter` 的联网搜索写回处填充）→ `GameViews.swift` → `CategoryResultsGrid`
    /// 按 `contains(item.id)` 逐卡透传，见 `CategoryResultsGrid.swift:41` 的构造点。
    var isSearchPopIn: Bool = false
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值
    @ObservedObject var theme: ThemeManager
    @State private var scale: CGFloat = 1.0
    // 入场动画：卡片首次出现在网格中时缩放+淡入弹入（LazyVGrid 复用/滚动时重建会再次触发，
    // 符合「进入可视区弹入」的预期；拆分重构时 searchPopInIds 动画丢失导致「有时没有动画」）
    //
    // 搜索结果弹入（已接线；原设计见提交 5d5769d，读取点与入参丢失于提交 7bf4044）：
    // 原设计用 `.onChange(of: isSearchPopIn)` 观察入参翻转，把缩放置 0.6、透明度置 0 后以
    // `.interpolatingSpring(mass: 0.8, stiffness: 200, damping: 12, initialVelocity: 4)` 收敛回 1.0。
    // 本视图不持有 item id（id 由 `CategoryResultsGrid` 以 `.id(item.id)` 施加，修饰符不回传值），
    // 因此判定必须在构造点完成——由 `CategoryResultsGrid` 传入 `isSearchPopIn`，本视图只消费结果。
    // 触发时机不需要 `.onChange`：搜索结果写回后本批卡片是新的 identity（`.id(item.id)` 随结果
    // 集合变化），首次渲染即走 `.onAppear`，起始值在该帧已就绪。
    //
    // 单条动画路径（避免与入场动画叠加播放两次）：本视图不新增第二个动画状态，而是复用下文的
    // `appearScale` / `appearOpacity`——`isSearchPopIn` 为真时把起始缩放取 0.6、收敛动画取上述
    // interpolatingSpring；为假时维持 0.92 与 `.spring(response: 0.45, dampingFraction: 0.75)`。
    // 起始缩放的写入位于 `DispatchQueue.main.async` 内、`withAnimation` 之前：此刻
    // `appearOpacity` 仍为 0（卡片不可见），中途改写起始缩放不会产生可见跳变。
    //
    // 不得以结果网格的 `.id()` 触发重建来间接出动画（会重置状态、重跑卡片 `.task`，已回退）。
    // 依据条目：SwiftUI《Animation》interpolatingSpring(mass:stiffness:damping:initialVelocity:)
    //   可用版本 iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 6.0+，本工程部署目标 macOS 13.0 可用。
    // 官方链接：https://developer.apple.com/documentation/swiftui/animation/interpolatingspring(mass:stiffness:damping:initialvelocity:)
    @State private var appearScale: CGFloat = 0.92
    @State private var appearOpacity: Double = 0

    private var translatedTags: [String] {
        tags.compactMap { ModrinthTagMap[$0] }
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { scale = 1.06 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { scale = 1.0 }
            }
            action?()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .contentTransitionOpacityCompat()
                if !translatedTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(translatedTags.prefix(6), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(theme.accentColor.opacity(0.8))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(theme.accentColor.opacity(0.12))
                                    )
                            }
                        }
                    }
                    .scrollBounceIfAvailable()
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: cardWidth, height: cardWidth * 0.55)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .animation(.spring(response: 0.4, dampingFraction: 0.5), value: scale)
        // 入场弹入：延迟一个 runloop 确保 withAnimation 在 onAppear 之后的渲染帧生效，
        // 避免数据已就绪时首次构建直接显示、动画被吞（「有时没有动画」的根因）
        .scaleEffect(appearScale)
        .opacity(appearOpacity)
        .onAppear {
            // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，同步写 @State 会触发
            // "Modifying state during view update" → UAF 前兆；本组件在分类网格中会成批触发，
            // 正是刷屏警告的主力来源），同时保证 withAnimation 在渲染帧之后生效
            DispatchQueue.main.async {
                // 搜索结果弹入的起始态：先改写起始缩放（必须在 withAnimation 之前），
                // 再一次性收敛回 1.0。此处 appearOpacity 仍为 0，卡片不可见，
                // 故把起始缩放由 0.92 改为 0.6 不产生可见跳变。
                if isSearchPopIn {
                    appearScale = 0.6
                }
                withAnimation(isSearchPopIn
                    ? .interpolatingSpring(mass: 0.8, stiffness: 200, damping: 12, initialVelocity: 4)
                    : .spring(response: 0.45, dampingFraction: 0.75)) {
                    appearScale = 1.0
                    appearOpacity = 1.0
                }
            }
        }
    }
}

extension ContentCard: Equatable {
    /// 仅比较值类型字段；忽略 action 闭包与内部 @State/主题，
    /// 使翻译完成时只有「真正变化」的卡片被重渲染，避免整列刷新导致的滚动卡顿。
    ///
    /// `isSearchPopIn` 必须纳入比较：`.equatable()` 的语义是「新旧值相等则跳过子视图更新」，
    /// 若漏掉该字段，搜索结果写回时（同一批卡片因翻译回写等原因被重新构造）本字段的变化会被
    /// 判为「未变化」而丢弃，弹入参数停留在旧值上，动画不生效。
    /// 依据条目：SwiftUI《View / equatable()》——Prevents the view from updating its child view
    ///   when its new value is the same as its old value；可用版本 macOS 10.15+。
    /// 官方链接：https://developer.apple.com/documentation/swiftui/view/equatable()
    static func == (lhs: ContentCard, rhs: ContentCard) -> Bool {
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.tags == rhs.tags &&
        lhs.isSearchPopIn == rhs.isSearchPopIn
    }
}

