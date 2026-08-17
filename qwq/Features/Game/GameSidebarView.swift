import SwiftUI

// MARK: - 游戏分类侧边栏（自 DownloadCategoryView 拆出）
// 纯展示组件：section 高亮、游戏子分类展开列表、子项弹入动画均由外部传入状态控制。

struct GameSidebarView: View {
    let theme: ThemeManager
    @Binding var selectedSection: GameSidebarSection
    @Binding var selectedSubCategory: GameSubCategory?
    @Binding var subItemOpacity: [GameSubCategory: Double]
    @Binding var sectionHighlightY: CGFloat
    let onSelect: (GameSidebarSection, GameSubCategory?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(.game, expanded: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(GameSubCategory.allCases.enumerated()), id: \.element.id) { i, sub in
                    subItem(sub, idx: 1 + i)
                }
            }

            ForEach(Array(GameSidebarSection.allCases.dropFirst().enumerated()), id: \.element.id) { i, section in
                sectionHeader(section, expanded: false)
            }

            Spacer()
        }
        .padding(.vertical, 12)
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

    private func sectionHeader(_ section: GameSidebarSection, expanded: Bool) -> some View {
        Button(action: {
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

    private func subItem(_ sub: GameSubCategory, idx: Int) -> some View {
        Button(action: { onSelect(.game, sub) }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor)
                    .frame(width: 3, height: 14)
                    .opacity(selectedSubCategory == sub ? 1 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: selectedSubCategory)
                Text(sub.rawValue)
                    .font(.system(size: 12))
                    .foregroundColor(selectedSubCategory == sub ? .primary : .secondary)
                Spacer()
            }
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
