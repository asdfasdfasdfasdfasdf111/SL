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
    @ObservedObject var theme = ThemeManager.shared
    @State private var scale: CGFloat = 1.0
    // 入场动画：卡片首次出现在网格中时缩放+淡入弹入（LazyVGrid 复用/滚动时重建会再次触发，
    // 符合「进入可视区弹入」的预期；拆分重构时 searchPopInIds 动画丢失导致「有时没有动画」）
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
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
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
    static func == (lhs: ContentCard, rhs: ContentCard) -> Bool {
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.cardWidth == rhs.cardWidth &&
        lhs.tags == rhs.tags
    }
}

