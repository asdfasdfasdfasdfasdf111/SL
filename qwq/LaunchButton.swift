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
                if launchPhase == .downloading || launchPhase == .installing {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.6))
                        .frame(width: buttonWidth * CGFloat(lightProgress), height: 50)
                        .animation(.exaggeratedSpring, value: lightProgress)
                }
                if launchPhase == .launching {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.85))
                        .frame(width: buttonWidth * CGFloat(darkProgress), height: 50)
                        .animation(.exaggeratedSpring, value: darkProgress)
                }
                RoundedRectangle(cornerRadius: 25)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 25).fill(.ultraThinMaterial))
                ZStack {
                    if launchPhase == .idle {
                        Text("启动游戏")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                    if launchPhase == .preparing {
                        // 启动前准备（皮肤资源包应用等，此前按钮变灰却无文案反馈）
                        Text("准备中…")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if launchPhase == .downloading {
                        Text("Java 下载中")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if launchPhase == .installing {
                        Text("Java 安装中")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if launchPhase == .launching {
                        Text("启动中")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: launchPhase)
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
        .onDisappear {
            scaleTask?.cancel()
        }
    }
}
