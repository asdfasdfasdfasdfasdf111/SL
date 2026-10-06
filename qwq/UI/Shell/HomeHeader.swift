//
//  HomeHeader.swift
//  模块化收口：把根视图主内容顶部的「标题行 + 分类导航」抽为独立视图，
//  ContentView 只保留「头部 / 内容区」两段结构。
//
//  ⚠️ 本地改动（2026-10-06）：顶部 Tab 不再自带独立玻璃卡片材质。
//  用户反馈：自带 ultraThinMaterial 卡片与内容区的 fullScreenUI 材质亮度不同，
//  交界处渲染成一条明暗分割线、而且「没看清玻璃」。整窗玻璃由
//  ContentView.mainContent 的 BlurView(fullScreenUI, withinWindow) 统一提供，
//  HomeHeader 保持透明、直接坐在同一块玻璃上 —— 亮度一致、无分界。
//  分类高亮块仍由 AnimatedCategoryPicker 提供（中性白 12%/20%）。
//
import SwiftUI

/// 主内容区头部：应用大标题与分类导航（透明，玻璃由整窗统一提供）。
struct HomeHeader: View {
    /// 当前选中的分类（点击导航项时由 AnimatedCategoryPicker 回写）
    @Binding var selectedCategory: Category
    /// 全部分类（顺序即导航项顺序，与画布横向顺序一致）
    let categories: [Category]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 第一行：应用大标题 + 右侧留白，左侧对齐，顶部留出窗口可拖拽区域空间
            HStack {
                Text("SL启动器")
                    .font(.largeTitle.bold())
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 第二行：分类导航靠左对齐
            AnimatedCategoryPicker(selectedCategory: $selectedCategory, categories: categories)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .zIndex(20)
        }
        .padding(.horizontal, 4)
        .background(Color.clear)
    }
}
