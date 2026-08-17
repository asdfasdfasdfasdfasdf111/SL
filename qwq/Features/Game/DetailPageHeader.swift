//
//  DetailPageHeader.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 头部：返回+标题+副标题+标签）
//  纯视图组件：详情页页头（返回按钮 / 名称大标题 / 翻译副标题 / 横向标签胶囊），
//  数据与回调全部外部传入（onBack 返回、tags 用 ModrinthTagMap 翻译），纯展示无状态。
//

import SwiftUI

/// 详情页页头：返回按钮 + 标题 + 副标题 + 标签胶囊
struct DetailPageHeader: View {
    @ObservedObject var theme = ThemeManager.shared
    let title: String
    let subtitle: String
    let tags: [String]
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .shadow(color: .black.opacity(0.08), radius: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.bottom, 10)

            Text(title)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(.bottom, 8)

            tagRow
        }
    }

    @ViewBuilder
    private var tagRow: some View {
        if !tags.isEmpty {
            let translated = tags.compactMap { ModrinthTagMap[$0] }
            if !translated.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(translated, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(theme.accentColor.opacity(0.1))
                                )
                        }
                    }
                }
                .scrollBounceIfAvailable()
                .padding(.bottom, 24)
            } else {
                Color.clear.frame(height: 0).padding(.bottom, 24)
            }
        } else {
            Color.clear.frame(height: 0).padding(.bottom, 24)
        }
    }
}
