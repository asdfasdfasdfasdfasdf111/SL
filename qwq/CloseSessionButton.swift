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
    let isLaunching: Bool
    let hasRunningSessions: Bool
    let onTap: () -> Void

    @State private var closeButtonScale: CGFloat = 0.01
    @State private var closeButtonGlow: CGFloat = 0
    @State private var popTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLaunching || hasRunningSessions {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
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

    private func stopPopAnimation() {
        popTask?.cancel()
    }
}
