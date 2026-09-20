//
//  HomeHeader.swift
//  模块化收口：把根视图主内容顶部的「标题行 + 分类导航 + 底部分隔线」抽为独立视图，
//  ContentView 只保留「头部 / 内容区」两段结构。
//
//  布局约束（改动即视觉变化）：
//  1. 整个头部（标题行 + 分类行）共享同一层毛玻璃背景，与早期版本一致；
//     背景由内层 VStack 携带并向上忽略安全区（ignoresSafeArea(edges: .top)）。
//  2. 分类导航带 zIndex(20)，用于压住下方内容区，取值与抽取前一致。
//  3. 标题行与分类行的内边距数值、分类选择器的绑定来源均逐字保留。
//  4. 外层由 Group 承载，不引入新的容器视图：在宿主 VStack（alignment: .leading,
//     spacing: 0）中被展平为同级子视图，因此头部与分隔线之间的间距、对齐不变。
//

import SwiftUI

/// 主内容区头部：应用大标题、分类导航与底部分隔线。
struct HomeHeader: View {

    /// 当前选中的分类（点击导航项时由 AnimatedCategoryPicker 回写）
    @Binding var selectedCategory: Category
    /// 全部分类（顺序即导航项顺序，与画布横向顺序一致）
    let categories: [Category]

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                // 第一行：应用大标题 + 右侧留白，左侧对齐，顶部留出窗口可拖拽区域空间
                HStack {
                    Text("SL启动器")
                        .font(.largeTitle.bold())
                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 6)
                // 第二行：分类导航靠左对齐
                AnimatedCategoryPicker(selectedCategory: $selectedCategory, categories: categories)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .zIndex(20)
            }
            .background(BlurView(material: .contentBackground, blendingMode: .withinWindow).ignoresSafeArea(edges: .top))

            // 头部与内容区之间的分隔线
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5).padding(.horizontal, 32)
        }
    }
}
