//
//  PopupCardScaffold.swift
//  弹窗卡片骨架：标题行 + 毛玻璃卡片 + 入场动画 + 底部按钮行。
//
//  为什么要有它：`ModInstallSelectionView` 与 `ModpackFolderPickerView` 同源自
//  `ModInstallViews.swift`，脚手架（标题行 / Divider / 毛玻璃卡片 / 入场动画 /
//  取消按钮）逐段复制（审计判据 B #4）。本骨架把这些同构部分收为一份，
//  `header`（副文案区）与 `content`（中间区）由调用方提供，差异自然留在调用方。
//
//  合并沿革与入场动画的演进见 `docs/ARCHAEOLOGY-NOTES.md`（本文件只保留当前约束）。
//  约束：入场动画的 `onAppear` 由骨架统一 dispatch 到主队列下一 tick 再动画，
//  调用方若有额外 onAppear 逻辑（如单实例自动选中）挂在自己的视图上即可。
//

import SwiftUI

/// 弹窗卡片骨架。
///
/// 结构自上而下：标题行 → 副文案区（调用方 header）→ Divider → 内容区（调用方 content）
/// → Divider → 按钮行（取消 + 确认）。
/// - 卡片固定宽度 `cardWidth`，高度随内容自适应；毛玻璃 + 外阴影由骨架统一绘制。
/// - 入场动画初始态为「缩小 + 全透明」，onAppear 后弹簧动画到 `1`。
struct PopupCardScaffold<Header: View, Content: View>: View {
    /// 标题行左侧图标（SF Symbol 名）。
    let icon: String
    /// 标题文案。
    let title: String
    /// 卡片固定宽度。
    let cardWidth: CGFloat
    /// 确认按钮文案。
    let confirmTitle: String
    /// 确认按钮宽度（取消按钮固定 80）。
    let confirmWidth: CGFloat
    /// 确认按钮是否可点（false 时置灰禁用）。
    let isConfirmEnabled: Bool
    /// 确认回调。
    let onConfirm: () -> Void
    /// 取消回调（右上角关闭按钮与底部「取消」共用）。
    let onCancel: () -> Void
    /// 副文案区（标题行之下）。
    @ViewBuilder let header: Header
    /// 中间内容区（两个 Divider 之间）。
    @ViewBuilder let content: Content

    /// 入场动画开关：初值 false（缩放 0.85 + 全透明），onAppear 之后置 true 触发弹入。
    @State private var showContent: Bool = false
    /// 主题色订阅：`accentColor` 随用户设置变化，视图会随之重绘。
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // 标题行：左图标 + 标题 + 右侧关闭按钮（Spacer 把关闭按钮推到最右）。
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)
                    Text(title)
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
                header
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().padding(.horizontal, 20)

            content

            Divider().padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 80, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text(confirmTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: confirmWidth, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isConfirmEnabled ? theme.accentColor : theme.accentColor.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isConfirmEnabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: cardWidth)
        // 毛玻璃卡片 + 外阴影：本弹窗不是系统 sheet，背景需要自己画。
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        )
        // 入场动画初始态：缩小 + 全透明，onAppear 后动画到 1 —— 故初值必须为 false。
        .scaleEffect(showContent ? 1 : 0.85)
        .opacity(showContent ? 1 : 0)
        // ⚠️ 入场弹入必须 dispatch 到主队列下一个 tick：onAppear 处于视图更新事务中，
        // 同步写 @State 会触发 "Modifying state during view update"（UAF 前兆）
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showContent = true
                }
            }
        }
    }
}