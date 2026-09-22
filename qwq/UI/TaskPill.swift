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

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.5

    var body: some View {
        if isPresented {
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                        withAnimation(.explosiveSpring) {
                            opacity = 0
                            scale = 0.5
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            isPresented = false
                        }
                    }
                }
        }
    }
}
