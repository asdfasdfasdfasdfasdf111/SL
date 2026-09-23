import SwiftUI

/// 「个性化」页：选择强调色（8 个色块，点一下即生效）。
/// 本视图**不持久化**任何东西 —— 写入由 ThemeManager 转发给 AppSettingsStore 统一落盘。
struct ColorPickerView: View {
    @ObservedObject var theme = ThemeManager.shared
    /// 候选色。用元组数组而非枚举：这里只需要「显示名 + 颜色值」两件事，
    /// 顺序即界面顺序（4 列 × 2 行）。
    let colorOptions: [(name: String, color: Color)] = [
        ("蓝色", .blue), ("紫色", .purple), ("粉色", .pink), ("红色", .red),
        ("橙色", .orange), ("黄色", .yellow), ("绿色", .green), ("灰色", .gray)
    ]
    // 结构：大标题 → 说明文字 → 色块网格（居中限宽）→ 弹簧撑开剩余空间。
    var body: some View {
        VStack(spacing: 32) {
            Text("选择强调色").font(.largeTitle.bold()).padding(.top, 40)
            Text("将用于分类高亮和按钮").font(.title3).foregroundColor(.secondary)
            // 固定 4 列 → 8 个色块排成 4×2。
            // 原为 `GridItem(.adaptive(minimum: 100))`，列数随可用宽度浮动：在 900pt 宽的窗口里
            // 正好塞下 7 列，第 8 个「灰色」被挤到第二行单独成块（评审第 5 条：分组应当完整、
            // 可预期，避免「差一个换行」的排布）。固定列数后任意窗口宽度下都不会出现孤块。
            // 另加 maxWidth 上限：窗口很宽时不让 4 个格子被拉得过开。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 32), count: 4), spacing: 32) {
                ForEach(colorOptions, id: \.name) { option in
                    ColorOptionButton(color: option.color, name: option.name)
                }
            }
            // 限宽 560：窗口很宽时不让 4 个色块被拉得过开（配合上面固定列数）。
            .frame(maxWidth: 560)
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.clear)
    }
}

/// 单个色块：圆形色点 + 名字，点中即写入全局主题色。
/// ⚠️ 选中态是**算出来的**（`theme.accentColor == color`），不是本地状态 ——
/// 因此多个实例之间天然互斥，无需外部协调。
struct ColorOptionButton: View {
    let color: Color; let name: String
    @ObservedObject var theme = ThemeManager.shared
    @State private var animationScale: CGFloat = 1.0
    /// 选中判据是「颜色值相等」。⚠️ 依赖 `Color` 的 `==`：只有同一种构造方式得到的
    /// Color 才相等。若将来改成从 RGB 或资源色取色，这里可能永远判不相等（高亮全部消失）。
    private var isSelected: Bool { theme.accentColor == color }
    var body: some View {
        // 点一下直接改全局主题色：没有「确定」按钮，也没有撤销。
        Button(action: { theme.accentColor = color }) {
            VStack(spacing: 12) {
                Circle().fill(color).frame(width: 60, height: 60)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: isSelected ? 4 : 0))
                    .shadow(color: color.opacity(0.5), radius: 8)
                    .scaleEffect(animationScale)
                    .animation(.exaggeratedSpring, value: animationScale)
                Text(name).font(.headline).foregroundColor(.primary)
            }
        }.buttonStyle(.plain)
        // 选中 / 取消选中各播一次不同的弹跳（选中放大到 1.2、取消缩到 0.8）——
        // 让「谁被选中了」除了描边之外还有动效提示。
        .onChange(of: isSelected) { newValue in
            if newValue {
                withAnimation(.punchySpring) { animationScale = 1.2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.punchySpring) { animationScale = 1.0 }
                }
            } else {
                withAnimation(.punchySpring) { animationScale = 0.8 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.punchySpring) { animationScale = 1.0 }
                }
            }
        }
    }
}

/// 分类选择器：一排「图标 + 名字」按钮，选中项下面有一块会**滑动**的高亮背景。
/// 高亮块的位置来自各按钮上报的 frame（GeometryReader），靠 `.position` 定位 + 动画过渡。
/// ⚠️ 上报的是 `.global` 绝对坐标，使用时必须减去容器自身的 global 原点（见最后那个 background）。
struct AnimatedCategoryPicker: View {
    @Binding var selectedCategory: Category
    let categories: [Category]
    @ObservedObject var theme = ThemeManager.shared
    @Environment(\.colorScheme) var colorScheme
    @Namespace private var namespace
    @State private var frames: [Category: CGRect] = [:]
    /// 高亮块颜色：深色模式下提高不透明度（0.2 → 0.3），
    /// 否则深色底上那块颜色会淡到看不见。
    private var highlightColor: Color {
        colorScheme == .light ? theme.accentColor.opacity(0.2) : theme.accentColor.opacity(0.3)
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
                .foregroundColor(selectedCategory == category ? theme.accentColor : .secondary)
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