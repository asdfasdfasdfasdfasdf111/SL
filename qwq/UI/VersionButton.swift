//
//  VersionButton.swift
//  版本选择列表里的一行（胶囊卡片）。纯展示 + 一个回调，不持有业务状态。
//
//  外观：`Text(title)` 撑满可用宽度并左对齐，圆角 12 的毛玻璃底 + 1pt 阴影；
//  选中时叠一圈 2pt 强调色描边（未选中用 `Color.clear` 保住同一套层级，避免出现/消失描边导致的抖动）。
//
//  按压反馈：按下瞬间缩到 1.08，0.12s 后回到 1.0（`punchySpring`）；
//  回弹由下方可取消的 `.task(id:)` 驱动（不再用 `DispatchQueue.main.asyncAfter`）。
//
//  说明：原先的 `DispatchQueue.main.asyncAfter` 闭包不可取消，会在视图释放后仍回写 `@State`，
//  是本工程 UAF 的成因之一；现已与 `TaskPill` / `LaunchButton` 统一为可取消的 `Task` 约定。
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
    /// 按压反馈的缩放系数（1.0 = 静止）。其写回由下方 `.task(id:)` 驱动，随视图销毁可取消。
    @State private var animationScale: CGFloat = 1.0
    /// 点击计数：每次点击 +1，作为下方 `.task(id:)` 的触发标识。
    /// 用「计数变化」而非「普通 `.task`」：普通 `.task` 只在视图出现时跑一次、点击不会重跑；
    /// 计数变化才能让每次点击都重启回弹计时，且随视图销毁自动取消（无不可取消闭包）。
    @State private var clickCount: Int = 0

    var body: some View {
        Button(action: {
            // 先放大给出即时反馈，立即执行真正的动作；回弹由下方 `.task(id:)` 负责（可取消）。
            withAnimation(.punchySpring) { animationScale = 1.08 }
            action()
            clickCount += 1
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
        // 回弹：点击后 0.12s 复位到 1.0。`.task(id:)` 在 id（点击计数）变化时重启、视图销毁时取消，
        // 取代原先 `DispatchQueue.main.asyncAfter` 的不可取消闭包（视图释放后仍写 `@State` → UAF 隐患）。
        // 首次出现时 clickCount 为 0，直接跳过以免把静止态误弹一下。
        // ⚠️ 睡眠必须用 `do/catch + return`，**不能写 `try?`**：视图销毁时 `.task` 会被取消，
        // `Task.sleep` 立刻抛 `CancellationError`；若用 `try?` 吞掉，代码会继续往下执行
        // `withAnimation { animationScale = 1.0 }`，等于「取消之后仍然回写 @State」——
        // 正是本组件要根治的那个 UAF 隐患。catch 后直接 return 才是真正的「取消即不动状态」。
        // macOS 12.0+，本工程部署 13.0，无需可用性守卫。
        .task(id: clickCount) {
            guard clickCount > 0 else { return }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return // 被取消（视图销毁 / 再次点击重启计时）：放弃本次回写
            }
            withAnimation(.punchySpring) { animationScale = 1.0 }
        }
    }
}