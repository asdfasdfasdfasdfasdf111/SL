//
//  HomeHeader.swift
//  模块化收口：把根视图主内容顶部的「标题行 + 分类导航 + 底部分隔线」抽为独立视图，
//  ContentView 只保留「头部 / 内容区」两段结构。
//
//  ⚠️ 本地改动（2026-10-06）：整条头部改为**矩形毛玻璃 + 柔和阴影**（照天气 App
//  侧栏的观感）。原实现用 BlurView(.contentBackground, .withinWindow) 做背景——
//  那是系统自带材质的「贴底」效果，用户反馈「不透明、不像玻璃」。现改为：
//  - 外层 `RoundedRectangle(18).fill(.ultraThinMaterial)`：透明毛玻璃矩形；
//  - 细描边 `primary 8%`：玻璃边缘的高光层（天气 App 卡片同款）；
//  - 阴影 `black 15% / r15 / y10`：悬浮感（天气 App 卡片阴影同款参数）。
//  头部由此从「贴底的条」变成「浮在内容上的一块玻璃」。
//
//  布局约束（改动即视觉变化）：
//  1. 整个头部（标题行 + 分类行）共享同一块玻璃背景。
//  2. 分类导航带 zIndex(20)，用于压住下方内容区，取值与抽取前一致。
//  3. 标题行与分类行的内边距数值、分类选择器的绑定来源均逐字保留。
//
import SwiftUI

/// 主内容区头部：应用大标题、分类导航，整体为矩形毛玻璃卡片。
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
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
        )
        // 用户：只要阴影、不要颜色 —— 描边去掉，阴影照抄天气 App 左栏卡片
        // （ModuleRow 同款：black 28% / r10 / y3）。
        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}
