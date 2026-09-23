//
//  ModInstallSelectionView.swift
//  模块化拆分：从 ModInstallViews.swift 拆出「模组安装目标选择」弹窗组件。
//  数据与回调全外部传入（modName/modVersion/instances + onConfirm/onCancel），
//  选中状态 selectedIds 为组件局部 @State（弹窗生命周期内有效）。
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
    /// 入场动画开关：初值 false（缩放 0.85 + 全透明），onAppear 之后置 true 触发弹入。
    @State private var showContent: Bool = false
    /// 主题色订阅：`accentColor` 随用户设置变化，视图会随之重绘。
    @ObservedObject var theme = ThemeManager.shared

    // 结构自上而下：标题区 → 分隔线 → 可滚动的实例列表 → 分隔线 → 按钮行。
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)
                    Text("模组安装")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("模组「\(modName)」需要 Minecraft \(modVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text("已检测到多个同版本游戏，请选择要加入此 mod 的版本：")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 20)

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

            Divider().padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 80, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial)
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    // 用 instances 的顺序过滤，保证回调拿到的顺序与界面展示一致
                    //（而不是 Set 的无序顺序）。
                    let selected = instances.filter { selectedIds.contains($0.id) }
                    onConfirm(selected)
                }) {
                    Text("安装 (\(selectedIds.count))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 100, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedIds.isEmpty ? theme.accentColor.opacity(0.4) : theme.accentColor)
                        )
                }
                .buttonStyle(.plain)
                // 一个都没选时禁用（按钮同时置灰，见上方 fill 的三元表达式）。
                .disabled(selectedIds.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // 固定宽度 420，高度随列表自适应。
        .frame(width: 420)
        // 毛玻璃卡片 + 外阴影：本弹窗不是系统 sheet，背景需要自己画。
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        )
        // 入场动画初始态：缩小 + 全透明，onAppear 后动画到 1 —— 故初值必须为 false。
        .scaleEffect(showContent ? 1 : 0.85)
        .opacity(showContent ? 1 : 0)
        // onAppear 里的两件事都刻意 dispatch 到主队列下一个 tick 才做，原因见下方注释。
        .onAppear {
            // ⚠️ selectedIds 是 @State：onAppear 处于视图更新事务中，同步写会触发
            // "Modifying state during view update"（UAF 前兆），延迟到渲染事务外执行
            if instances.count == 1, let first = instances.first {
                let singleId = first.id
                DispatchQueue.main.async {
                    selectedIds = [singleId]
                }
            }
            // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，
            // 同步写 @State 会触发 "Modifying state during view update" → UAF 前兆）
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showContent = true
                }
            }
        }
    }
}
