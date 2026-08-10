//
//  CategorySearchBar.swift
//  模块化拆分：从 GameViews.swift 拆出（原 searchBarRow）
//  纯视图组件：分类页标题 + 搜索输入框（放大镜图标、清空按钮、毛玻璃底），
//  搜索文本 @Binding 外置，卡片内边距传入，不含任何数据/网络逻辑。
//

import SwiftUI

/// 分类页顶部「标题 + 搜索框」行
struct CategorySearchBar: View {
    let title: String
    @Binding var searchText: String
    let cardPadding: CGFloat

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.primary)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("搜索\(title)...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 160)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
            )
        }
        .padding(.top, cardPadding)
    }
}
