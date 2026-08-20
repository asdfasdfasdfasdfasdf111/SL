//
//  LaunchButton.swift
//  模块化拆分：从 CategoryContentView.swift 拆出（原 launchButton 方法，约 80 行）
//  纯视图组件：启动游戏按钮（阶段进度条 + 状态文案切换 + 点击弹跳动画），
//  启动编排逻辑（用户名校验 / 错误弹窗 / startLaunch）通过 onTap 回调外置，
//  点击动画用可取消 Task（onDisappear cancel），组件销毁后不再写 State storage（UAF 防护）。
//

import SwiftUI

/// 启动游戏按钮：多阶段进度条 + 状态文案 + 弹跳动画
struct LaunchButton: View {
    @ObservedObject var theme = ThemeManager.shared
    let buttonWidth: CGFloat
    let isLaunching: Bool
    let launchPhase: LaunchPhase
    let lightProgress: Double
    let darkProgress: Double
    let onTap: () -> Void

    @State private var buttonScale: CGFloat = 1.0
    @State private var scaleTask: Task<Void, Never>?

    // 「死动画」锁：动画播完前不响应新相位，排队到 pendingPhase，杜绝转场被中途打断
    @State private var displayedPhase: LaunchPhase = .idle
    @State private var pendingPhase: LaunchPhase?
    @State private var phaseTransitionActive = false
    @State private var phaseTransitionTask: Task<Void, Never>?

    private static let phaseSpring = Animation.spring(response: 0.5, dampingFraction: 0.7)

    private func schedulePhaseChange(to newPhase: LaunchPhase) {
        guard newPhase != displayedPhase else { return }
        guard !phaseTransitionActive else {
            pendingPhase = newPhase
            return
        }
        beginPhaseTransition(to: newPhase)
    }

    private func beginPhaseTransition(to phase: LaunchPhase) {
        phaseTransitionActive = true
        withAnimation(LaunchButton.phaseSpring) { displayedPhase = phase }
        // 锁定时长 = spring(0.5) 视觉完播时长，期间新相位排队，解锁后播最新目标
        phaseTransitionTask?.cancel()
        phaseTransitionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            phaseTransitionActive = false
            if let pending = pendingPhase {
                pendingPhase = nil
                beginPhaseTransition(to: pending)
            }
        }
    }

    var body: some View {
        Button(action: {
            // 点击弹跳动画（可取消 Task：视图销毁后不再写已释放的 State storage）
            scaleTask?.cancel()
            withAnimation(.punchySpring) { buttonScale = 1.15 }
            scaleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.punchySpring) { buttonScale = 1.0 }
            }
            onTap()
        }) {
            ZStack(alignment: .leading) {
                if displayedPhase == .downloading || displayedPhase == .installing {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.6))
                        .frame(width: buttonWidth * CGFloat(lightProgress), height: 50)
                        .animation(.exaggeratedSpring, value: lightProgress)
                }
                if displayedPhase == .launching {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.85))
                        .frame(width: buttonWidth * CGFloat(darkProgress), height: 50)
                        .animation(.exaggeratedSpring, value: darkProgress)
                }
                RoundedRectangle(cornerRadius: 25)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 25).fill(.ultraThinMaterial))
                ZStack {
                    if displayedPhase == .idle {
                        Text("启动游戏")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                    if displayedPhase == .preparing {
                        // 启动前准备（皮肤资源包应用等，此前按钮变灰却无文案反馈）
                        Text("准备中…")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if displayedPhase == .downloading {
                        Text("正在检查游戏完整性")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if displayedPhase == .installing {
                        Text("Java 安装中")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if displayedPhase == .launching {
                        Text("启动中")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                }
            }
            .frame(width: buttonWidth, height: 50)
            .mask(RoundedRectangle(cornerRadius: 25).frame(width: buttonWidth, height: 50))
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(buttonScale)
        .animation(.punchySpring, value: buttonScale)
        .disabled(isLaunching)
        .padding(.bottom, 30)
        .onChange(of: launchPhase) { newPhase in
            schedulePhaseChange(to: newPhase)
        }
        .onAppear {
            displayedPhase = launchPhase
        }
        .onDisappear {
            scaleTask?.cancel()
            phaseTransitionTask?.cancel()
        }
    }
}
