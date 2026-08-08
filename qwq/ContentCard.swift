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
                    .contentTransition(.opacity)
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

