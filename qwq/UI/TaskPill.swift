//
//  TaskPill.swift
//  「发生了一件事」的统一形状：窗口内浮出的一颗圆角毛玻璃药丸。
//
//  为什么把它抽成一个组件（而不是让第二个弹窗照抄一遍样式）：
//  原先启动器里有两种「通知」——下载 / 安装 / Java 状态走这颗药丸，启动失败走系统 `.alert`。
//  系统 alert 是 macOS 原生模态，和界面整体的毛玻璃语言不搭；于是要给失败也用药丸。
//  但**照抄一遍样式参数**是迟早会漂移的做法（改一处忘一处，两边差几 pt 谁也发现不了）。
//  这里把药丸做成唯一实现，两个入口都渲染同一个类型，样式与动画**由代码保证相同**。
//
//  两个入口：
//    - 任务状态（下载开始 / 安装中 / 下载完成 / Java 选择）→ `LaunchPanelState.presentMessage`
//      → `showJavaPopup` / `javaPopupMessage`，停留 1.5s
//    - 启动与下载失败 → `LaunchPanelState.presentError`
//      → `showLaunchAlert` / `launchErrorMessage`，停留 6s
//
//  **唯一的差异只有上面那个停留时长**（`duration`）：失败提示是用户唯一能看到的失败原因，
//  1.5s 一闪而过等于没提示，所以给长一点。样式、位置、入场与退场曲线全部共用。
//

import SwiftUI

struct TaskPill: View {

    /// 正文。唯一来源分别是 `LauncherSettings.javaPopupMessage` / `.launchErrorMessage`
    let message: String
    /// 开关。药丸播完退场动画后写回 false（与两个状态源原有的「自我关闭」语义一致）
    @Binding var isPresented: Bool
    /// 停留时长（秒）。默认 1.5s = 任务状态气泡的历史行为，改它会影响所有调用点
    var duration: TimeInterval = 1.5

    var body: some View {
        if isPresented {
            TaskPillContent(message: message, isPresented: $isPresented, duration: duration)
                // ⚠️ 必须以 `message` 作为身份，否则「同一通道上后一条消息顶替前一条」会出事。
                // 两个状态源（`LaunchPanelState.presentMessage` / `presentError`）都是
                // 「写正文 + 置开关为 true」，**正文变化时开关一直是 true**，于是前后两棵子树
                // 落在视图树的同一位置、同一个类型 → 被判定为「同一个视图在更新」：
                //   1. `onAppear` 不再触发 → 新消息的入场弹入动画不播（沿用上一条留下的状态）；
                //   2. 停留计时不会被重排 → 新消息沿用一个**已经开始倒计时**的计时器。
                // 第 2 条是真正会伤人的：同一通道在停留期内再来一条消息（失败提示 6s、
                // 任务状态 1.5s，连点下载 / 连续报错都是），第二条只显示「第一条剩余的时间」，
                // 极端情况下**只闪零点几秒就消失**——而 `RootOverlays.mistakePillDuration`
                // 之所以设成 6s，注释写得很明白：「失败提示通常是用户能看到的唯一失败原因，
                // 1.5s 一闪而过等于没提示」。此处恰好把它抵消掉。
                // 绑上 message 之后：旧内容移除、新内容插入，入场动画与停留计时都随新消息重新开始。
                .id(message)
        }
    }
}

/// 药丸的可见内容。
///
/// 单独成类型（而不是把 `opacity` / `scale` 留在 `TaskPill` 上）是上面 `.id(message)` 生效的前提：
/// 换身份只重建「被 `.id` 标记的这棵子树」，其 `@State` 随之回到初值（`opacity = 0` / `scale = 0.5`）；
/// 若状态留在 `TaskPill` 上，换消息时它会被原地保留，入场动画依然不会播。
private struct TaskPillContent: View {
    let message: String
    @Binding var isPresented: Bool
    let duration: TimeInterval

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.5

    var body: some View {
        Text(message)
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，
                // 同步写 @State 会触发 "Modifying state during view update" → UAF 前兆）
                DispatchQueue.main.async {
                    withAnimation(.exaggeratedSpring) {
                        opacity = 1
                        scale = 1
                    }
                }
            }
            // 停留 + 退场：用 `.task` 取代原来的 `DispatchQueue.main.asyncAfter`。
            // 原写法有两处问题：
            //  1. `asyncAfter` 的闭包**不可取消**——视图已销毁（切换分类、外部把开关置回 false、
            //     新消息顶替旧消息）时它仍会执行，并回写 `@State`（opacity / scale）与
            //     `@Binding`（isPresented）。本工程已多次因「回调晚于视图销毁仍写 State storage」
            //     触发 UAF，隔壁 `LaunchButton` 正是为此改成了可取消 Task（见其文件头注释），
            //     本组件此前是同一约定下的唯一例外。
            //  2. 计时无法随消息变化重排（见 `TaskPill` 里 `.id(message)` 的说明）。
            // `.task` 随视图出现启动、随视图消失自动取消，语义与「停留 duration 后退场」一致。
            // 自 macOS 12.0 起可用，本工程部署目标 13.0，无需可用性守卫。
            .task {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.explosiveSpring) {
                    opacity = 0
                    scale = 0.5
                }
                // 退场动画留给渲染事务出帧后再关开关（与原来 0.3s 后写回的节奏一致）
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                // 药丸自己把开关写回 false（与两个状态源原有的「自我关闭」语义一致）
                isPresented = false
            }
    }
}
