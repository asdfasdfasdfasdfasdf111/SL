//
//  AnimatedCategoryPicker.swift
//  分类 Tab 选择器（原住址：ColorPickerView.swift，个性化页已按用户要求删除，
//  此文件仅承载 Tab 选择器本体）。
//
//  高亮块颜色已中性化（2026-10-06）：不再用可配置强调色，改白/灰玻璃高亮。
//
import SwiftUI

/// 「个性化」页：选择强调色（8 个色块，点一下即生效）。
/// 本视图**不持久化**任何东西 —— 写入由 ThemeManager 转发给 AppSettingsStore 统一落盘。
struct AnimatedCategoryPicker: View {
    @Binding var selectedCategory: Category
    let categories: [Category]
    @Environment(\.colorScheme) var colorScheme
    @Namespace private var namespace
    @State private var frames: [Category: CGRect] = [:]
    /// 高亮块颜色：**中性玻璃高亮**（不再用可配置的强调色）。
    /// 深色模式提高不透明度（0.12 → 0.2），否则深色底上那块会淡到看不见。
    private var highlightColor: Color {
        Color.primary.opacity(colorScheme == .light ? 0.12 : 0.2)
    }
    var body: some View {
        HStack(spacing: 24) {
            ForEach(categories) { category in
                Button(action: {
                    withAnimation(.spring(response: 0.52, dampingFraction: 0.58, blendDuration: 0.12)) {
                        selectedCategory = category
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: category.systemImage).font(.body)
                        Text(category.name).font(.title3).fontWeight(.medium)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    // 用一个 `Color.clear` 的 GeometryReader 只**量尺寸**、不画东西：
                    // onAppear 与 frame 变化时把位置记进 frames 字典。
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                // 布局事务中改 @State 会触发 "Modifying state during view update"（UAF 前兆），
                                // 延迟到下一轮 runloop 再写，滑块位置晚一帧更新无感知
                                DispatchQueue.main.async { frames[category] = geo.frame(in: .global) }
                            }
                            .onChange(of: geo.frame(in: .global)) { newFrame in
                                // 布局事务中改 @State 会触发 "Modifying state during view update"（UAF 前兆），
                                // 延迟到下一轮 runloop 再写，滑块位置晚一帧更新无感知
                                DispatchQueue.main.async { frames[category] = newFrame }
                            }
                    })
                }
                .buttonStyle(.plain)
                .id(category.id)
                .foregroundColor(selectedCategory == category ? Color.primary : .secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        // 高亮块：按选中项记录的 frame 摆放。⚠️ `position(x:y:)` 用的是**父容器坐标系**，
        // 所以要把 global 坐标减去容器自身的 global 原点。拿不到选中项 frame 时
        //（还没测量到）整块不渲染 —— 宁可不画，也不画在错误的位置上。
        .background(
            GeometryReader { geo in
                if let selectedFrame = frames[selectedCategory] {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(highlightColor)
                        .frame(width: selectedFrame.width, height: selectedFrame.height)
                        .position(x: selectedFrame.midX - geo.frame(in: .global).minX,
                                  y: selectedFrame.midY - geo.frame(in: .global).minY)
                        // 动画只盯 selectedCategory：值一变就按弹簧过渡到新位置（滑动效果的来源）。
                        .animation(.spring(response: 0.52, dampingFraction: 0.58, blendDuration: 0.12), value: selectedCategory)
                }
            }
        )
    }
}