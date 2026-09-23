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
    /// 搜索框占位文字。默认按标题生成「搜索<标题>...」。
    ///
    /// 当标题本身已是名词短语时会得到重复标题的占位文字（版本列表的标题是「正式版」，
    /// 默认占位就成了「搜索正式版...」，与左侧大标题重复），此时调用方可单独给出更准确的提示。
    /// ⚠️ 必须保留为**最后一个**带默认值的参数：现有调用点按「三参数」顺序传参，插到中间会编译不过。
    var placeholder: String? = nil

    private var resolvedPlaceholder: String { placeholder ?? "搜索\(title)..." }

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
                TextField(resolvedPlaceholder, text: $searchText)
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
