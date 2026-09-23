//
//  DetailPageHeader.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 头部：返回+标题+副标题+标签）
//  纯视图组件：详情页页头（返回按钮 / 名称大标题 / 翻译副标题 / 横向标签胶囊），
//  数据与回调全部外部传入（onBack 返回、tags 用 ModrinthTagMap 翻译），纯展示无状态。
//

//
//  DetailPageHeader.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 头部：返回+标题+副标题+标签）
//  纯视图组件：详情页页头（返回按钮 / 名称大标题 / 翻译副标题 / 横向标签胶囊），
//  数据与回调全部外部传入（onBack 返回、tags 用 ModrinthTagMap 翻译），纯展示无状态。
//
//  ⚠️ 标签行**无论有没有标签都会占 24pt 底距**（见 tagRow 的三个分支），
//  目的是让页头总高恒定 —— 无标签的模组不会让下方内容整体上移，切换详情页时页面不跳。
//

import SwiftUI

/// 详情页页头：返回按钮 + 标题 + 副标题 + 标签胶囊
struct DetailPageHeader: View {
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值
    @ObservedObject var theme: ThemeManager
    /// 大标题（项目名）。
    let title: String
    /// 副标题，通常是作者或被翻译过的简介。
    let subtitle: String
    /// 原始标签（如 `["optimization", "fabric"]`），由本视图翻译成中文再显示。
    let tags: [String]
    /// 返回回调 —— 返回按钮的唯一行为。
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

    /// 标签行。三层判断刻意分开：
    /// ① 原始 tags 为空 → 只占位；
    /// ② 有 tags 但一条都翻译不出来（不在 ModrinthTagMap 里）→ 同样只占位，
    ///    避免显示一堆英文 slug；
    /// ③ 有可翻译的 → 横向滚动展示。
    @ViewBuilder
    private var tagRow: some View {
        if !tags.isEmpty {
            // compactMap：查不到译名的标签**直接丢弃**（回落显示原文会让界面中英混杂）。
            let translated = tags.compactMap { ModrinthTagMap[$0] }
            if !translated.isEmpty {
                // 标签多时横向滚动、不显示滚动条；标签本身不可点（纯展示，没有 onTap）。
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
                // 有标签但全无译名 —— 用零高视图补上同样的底距，保持页头总高不变。
                Color.clear.frame(height: 0).padding(.bottom, 24)
            }
        } else {
            // 无标签：同上，只为占住底距。
            Color.clear.frame(height: 0).padding(.bottom, 24)
        }
    }
}
