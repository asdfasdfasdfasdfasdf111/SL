//
//  VersionButton.swift
//  版本选择列表里的一行（胶囊卡片）。纯展示 + 一个回调，不持有业务状态。
//
//  外观：`Text(title)` 撑满可用宽度并左对齐，圆角 12 的毛玻璃底 + 1pt 阴影；
//  选中时叠一圈 2pt 强调色描边（未选中用 `Color.clear` 保住同一套层级，避免出现/消失描边导致的抖动）。
//
//  按压反馈：按下瞬间缩到 1.08，0.12s 后回到 1.0（`punchySpring`）。
//
//  ⚠️ 已知缺陷（记录在案，本次未改动）：这段反馈用的是
//  `DispatchQueue.main.asyncAfter`，其闭包**不可取消**，且它回写的是 `@State`。
//  若视图在这 0.12s 内被销毁（连点其它版本、返回上一页、切换分类），
//  闭包仍会执行并写已释放的 State storage —— 这正是本工程多处 UAF 的成因。
//  同一约定下 `TaskPill`（见其 `.task` 处注释）与 `LaunchButton` 都已改成可取消的 `Task`，
//  本组件是遗留的例外。改为 `.task { sleep; withAnimation { scale = 1 } }` 即可消除。
//
//  使用点：`VersionPickerCard.swift:37`（游戏版本选择卡片列表）。
//

import SwiftUI

/// 单选式版本行。选中态由外部传入（`isSelected`），本视图不做选择决策。
struct VersionButton: View {
    /// 显示文本（版本号，如 "1.21.8"）
    let title: String
    /// 是否为当前选中项；决定是否画强调色描边
    let isSelected: Bool
    /// 主题来源由调用方注入：本视图不持有对象，仅订阅其 @Published 变化
    @ObservedObject var theme: ThemeManager
    /// 点击回调。调用方负责真正切换选中项，本视图只负责转发与反馈动画。
    let action: () -> Void
    /// 按压反馈的缩放系数（1.0 = 静止）。见文件头关于其写回时机的缺陷说明。
    @State private var animationScale: CGFloat = 1.0

    var body: some View {
        Button(action: {
            // 先放大给出即时反馈，再执行真正的动作；0.12s 后复位
            withAnimation(.punchySpring) { animationScale = 1.08 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { animationScale = 1.0 }
            }
        }) {
            Text(title)
                .font(.body)
                .foregroundColor(.primary)
                // 撑满宽度 + 左对齐：让同一列里的多行文本起点一致、点击热区等宽
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).shadow(radius: 1))
                // 未选中时刻意使用 `Color.clear` 而不是去掉 overlay：
                // 保持描边图层恒定存在，选中/取消选中之间不会因图层增删而重排。
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? theme.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .scaleEffect(animationScale)
    }
}