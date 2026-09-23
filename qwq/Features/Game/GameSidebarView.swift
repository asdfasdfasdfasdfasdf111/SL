import SwiftUI

// MARK: - 游戏分类侧边栏（自 DownloadCategoryView 拆出）
// 纯展示组件：section 高亮、游戏子分类展开列表、子项弹入动画均由外部传入状态控制。
//
// ⚠️ 它是**受控组件**：主题、选中项、子项透明度、高亮条位置全部来自外部，
// 自身不持有任何状态 —— 因此高亮与弹入动画的节奏完全由调用方驱动。

/// 游戏分类侧边栏。左侧是一级分类，其中「游戏」这一节额外展开出二级分类。
/// ⚠️ 高亮矩形画在 `.overlay` 里靠 `offset(y:)` 位移，**不是**给每个按钮加背景 ——
/// 这样切换选中项时它能连续滑动过去，而不是在两个位置之间跳变。
struct GameSidebarView: View {
    /// 主题。本视图只读 accentColor，因此不需要 `@ObservedObject` 订阅。
    let theme: ThemeManager
    /// 当前选中的一级分类。
    @Binding var selectedSection: GameSidebarSection
    /// 当前选中的二级分类；nil 表示停在了一级分类上（例如那些没有子项的分类）。
    @Binding var selectedSubCategory: GameSubCategory?
    /// 子项逐个淡入的透明度表。由调用方按索引错开赋值，本视图只负责消费 ——
    /// 于是「依次弹入」的时序逻辑不必写进视图。
    @Binding var subItemOpacity: [GameSubCategory: Double]
    /// 高亮条相对侧边栏顶部的 y 偏移，由调用方按选中行位置算好并驱动动画。
    @Binding var sectionHighlightY: CGFloat
    /// 选中回调。本视图**不自己改选中状态**，一律交回调用方（受控组件）。
    let onSelect: (GameSidebarSection, GameSubCategory?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 「游戏」这一节固定展开，其子项紧跟其后（见下面的 ForEach）。
            sectionHeader(.game, expanded: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(GameSubCategory.allCases) { sub in
                    subItem(sub)
                }
            }

            // dropFirst 跳过错开处理的 .game，其余分类一律不展开。
            ForEach(GameSidebarSection.allCases.dropFirst()) { section in
                sectionHeader(section, expanded: false)
            }

            Spacer()
        }
        .padding(.vertical, 12)
        // 高亮条：圆角矩形 + 细描边，靠 offset 位移到当前行；动画挂在 offset 上，
        // 因此只有「位置变化」会被动画，颜色变化不会。
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 0.5)
                )
                .padding(.horizontal, 6)
                .frame(height: 30)
                .offset(y: sectionHighlightY + 3)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: sectionHighlightY),
            alignment: .topLeading
        )
    }

    /// 一级分类的整行按钮。
    /// ⚠️ 参数 `expanded` **在函数体内没有被使用**（展开与否实际由调用处的 ForEach 结构决定）——
    /// 属遗留参数；改动前先确认没有别的调用点依赖它。
    private func sectionHeader(_ section: GameSidebarSection, expanded: Bool) -> some View {
        Button(action: {
            // 点「游戏」时默认落到 release 子分类（而不是 nil），
            // 避免侧边栏进入「一级已选、二级未选」的中间态。
            if section == .game { onSelect(section, .release) }
            else { onSelect(section, nil) }
        }) {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selectedSection == section ? theme.accentColor : .secondary)
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selectedSection == section ? .primary : .secondary)
                Spacer()
                // 只有「游戏」这节显示展开箭头。该节目前恒展开，所以箭头是静态装饰。
                if section == .game {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 二级分类行。选中态由「左侧 3pt 竖条 + 文字转主色」表达，而不是整行底色。
    /// 透明度由外部传入，故调用方可以做到「逐项依次淡入」。
    private func subItem(_ sub: GameSubCategory) -> some View {
        Button(action: { onSelect(.game, sub) }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor)
                    .frame(width: 3, height: 14)
                    // 竖条靠透明度切换而非增删视图 —— 保留占位宽度，选中时文字不会左右跳动。
                    .opacity(selectedSubCategory == sub ? 1 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: selectedSubCategory)
                Text(sub.rawValue)
                    .font(.system(size: 12))
                    .foregroundColor(selectedSubCategory == sub ? .primary : .secondary)
                Spacer()
            }
            // 42pt 左缩进 ≈ 一级分类的图标宽度 + 间距，视觉上体现层级关系。
            .padding(.leading, 42)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(subItemOpacity[sub] ?? 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: subItemOpacity[sub] ?? 0)
    }
}
