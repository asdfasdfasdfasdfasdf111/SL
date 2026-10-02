//
//  ModInstallSelectionView.swift
//  模块化拆分：从 ModInstallViews.swift 拆出「模组安装目标选择」弹窗组件。
//  数据与回调全外部传入（modName/modVersion/instances + onConfirm/onCancel），
//  选中状态 selectedIds 为组件局部 @State（弹窗生命周期内有效）。
//  2026-10-02：脚手架（标题行/卡片/入场动画/按钮行）收敛到共享骨架
//  `UI/Shell/PopupCardScaffold.swift`（审计判据 B #4），本文件只留差异部分。
//

import SwiftUI

/// 模组安装目标选择弹窗（把一个模组装进哪些游戏实例）。
///
/// **自包含**：数据与回调全部由外部传入，本视图不读任何全局状态（主题除外）。
/// ⚠️ `selectedIds` 是 `@State`，弹窗关闭即销毁 —— 每次打开都是全新的空选择。
struct ModInstallSelectionView: View {
    /// 模组名，仅用于展示。
    let modName: String
    /// 该模组要求的 Minecraft 版本（展示用，如 `1.20.1`）。
    let modVersion: String
    /// 候选游戏实例（调用方已按版本筛过，本视图不再过滤）。
    let instances: [GameInstance]
    /// 确认回调 —— 参数是**选中的那些实例**（已从 `instances` 里过滤出来）。
    let onConfirm: ([GameInstance]) -> Void
    let onCancel: () -> Void

    /// 选中的实例 id 集合（用 id 而不是实例本身，避免值语义/引用语义带来的比较麻烦）。
    /// 为空时「安装」按钮禁用。
    @State private var selectedIds: Set<UUID> = []

    /// 主题色订阅：`accentColor` 随用户设置变化，视图会随之重绘。
    @ObservedObject var theme = ThemeManager.shared

    // 结构自上而下（标题区与按钮行由骨架提供）：副文案 → 可滚动的实例列表。
    var body: some View {
        PopupCardScaffold(
            icon: "puzzlepiece.extension.fill",
            title: "模组安装",
            cardWidth: 420,
            confirmTitle: "安装 (\(selectedIds.count))",
            confirmWidth: 100,
            isConfirmEnabled: !selectedIds.isEmpty,
            onConfirm: {
                // 用 instances 的顺序过滤，保证回调拿到的顺序与界面展示一致
                //（而不是 Set 的无序顺序）。
                onConfirm(instances.filter { selectedIds.contains($0.id) })
            },
            onCancel: onCancel,
            header: {
                Text("模组「\(modName)」需要 Minecraft \(modVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text("已检测到多个同版本游戏，请选择要加入此 mod 的版本：")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            },
            content: {
                // 实例多时只滚列表区，标题与按钮始终可见（按钮不会跟着滚走）。
                ScrollView {
                    VStack(spacing: 0) {
                        // 直接用 GameInstance 的 Identifiable id 作为列表 identity。
                        ForEach(instances) { instance in
                            Button(action: {
                                // 点整行即切换勾选（下面用 contentShape 把空白区域也纳入点击范围）。
                                if selectedIds.contains(instance.id) {
                                    selectedIds.remove(instance.id)
                                } else {
                                    selectedIds.insert(instance.id)
                                }
                            }) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(selectedIds.contains(instance.id) ? theme.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                                            .frame(width: 18, height: 18)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(selectedIds.contains(instance.id) ? theme.accentColor.opacity(0.15) : Color.clear)
                                            )
                                        if selectedIds.contains(instance.id) {
                                            // 勾选图标只在选中时插入 —— 未选中时这个 ZStack 里只有方框。
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(theme.accentColor)
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(instance.version)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text(instance.rootPath)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                // 撑满整行可点：否则只有文字本身可点，大片空白点不动。
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // 最后一行后面不画分隔线（否则底部会多出一条悬空的线）。
                            if instance.id != instances.last?.id {
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                }
                // 高度随条目数自适应，但**封顶 300**：候选很多时改为内部滚动，
                // 不让弹窗长到超出屏幕（每行约 50pt，20pt 是上下留白）。
                .frame(maxHeight: min(CGFloat(instances.count) * 50 + 20, 300))
            }
        )
        // ⚠️ 单实例自动选中：onAppear 处于视图更新事务中，同步写 @State 会触发
        // "Modifying state during view update"（UAF 前兆），延迟到渲染事务外执行。
        // 入场动画已由骨架统一处理，这里只做本视图自己的初始化。
        .onAppear {
            if instances.count == 1, let first = instances.first {
                let singleId = first.id
                DispatchQueue.main.async {
                    selectedIds = [singleId]
                }
            }
        }
    }
}