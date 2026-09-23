//
//  CloseSessionButton.swift
//  模块化拆分：从 CategoryContentView.swift 拆出（原 closeButtonOverlay 计算属性，约 84 行）
//  纯视图组件：右下角「关闭游戏 / 取消启动」电源按钮（圆环辉光 + 弹入动画），
//  可见性由 isLaunching / hasRunningSessions 传入，点击行为（NSAlert 确认/终止进程/
//  复位状态）通过回调外置；弹入动画用可取消 Task（onDisappear cancel），
//  组件销毁后不再写 State storage（UAF 防护）。
//

import SwiftUI

/// 右下角电源按钮：运行中有游戏时提示关闭，否则取消启动
struct CloseSessionButton: View {
    @ObservedObject var theme = ThemeManager.shared
    /// 是否正在启动（与 hasRunningSessions 一起决定按钮是否出现）。
    let isLaunching: Bool
    /// 是否还有游戏进程在跑（决定出现时的提示文案是「关闭」还是「取消」）。
    let hasRunningSessions: Bool
    /// 点击回调。⚠️ 本视图**不弹确认框、不杀进程** —— NSAlert 与终止逻辑都在外部
    ///（LaunchCoordinator.handlePowerTap）。
    let onTap: () -> Void

    /// 入场动画初值 0.01 而**不是 0**：`scaleEffect(0)` 会让命中测试完全失效，
    /// 留一个极小值既视觉不可见，又能正常参与布局与点击。
    @State private var closeButtonScale: CGFloat = 0.01
    @State private var closeButtonGlow: CGFloat = 0
    @State private var popTask: Task<Void, Never>?

    // 可见性只有一个条件：正在启动，或仍有游戏在跑。两者都不成立时整个按钮不渲染。
    var body: some View {
        Group {
            if isLaunching || hasRunningSessions {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        // 圆环 + 图标两层：圆环随 closeButtonGlow 淡出成为辉光，
                        // 图标固定在 44×44 的毛玻璃圆底上。
                        Button(action: onTap) {
                            ZStack {
                                Circle()
                                    .stroke(theme.accentColor.opacity(closeButtonGlow), lineWidth: 2.5)
                                    .frame(width: 44, height: 44)
                                    .scaleEffect(closeButtonScale * 1.8)
                                Image(systemName: "power")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(.regularMaterial).shadow(radius: 4))
                                    .scaleEffect(closeButtonScale)
                            }
                            .onAppear {
                                // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，
                                // 同步写 @State 会触发 "Modifying state during view update" → UAF 前兆）
                                DispatchQueue.main.async {
                                    playPopAnimation()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(20)
                        // tooltip 按状态给不同说法：有游戏在跑 = 关闭所有游戏；否则 = 取消启动。
                        .help(hasRunningSessions ? "关闭所有游戏" : "取消启动")
                    }
                }
            }
        }
    }

    /// 弹入动画（放大→回弹→复位）：可取消 Task，视图销毁后不再写 State storage
    private func playPopAnimation() {
        popTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
            closeButtonScale = 1.3
            closeButtonGlow = 0.8
        }
        popTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                closeButtonScale = 0.85
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                closeButtonScale = 1.0
                closeButtonGlow = 0
            }
        }
    }
}
