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
    /// 按钮宽度：进度条要按它算像素宽度，所以必须传进来（内层无法自适应）。
    let buttonWidth: CGFloat
    /// 是否正在启动。为 true 时按钮被 `.disabled` —— 这是唯一的防重复点击开关。
    let isLaunching: Bool
    /// 外部传入的**目标相位**。本视图不会立刻跟随它，而是经 schedulePhaseChange 排队。
    let launchPhase: LaunchPhase
    /// 浅色进度条（下载 / 安装阶段）的 0~1 进度。
    let lightProgress: Double
    /// 深色进度条（启动阶段）的 0~1 进度。
    let darkProgress: Double
    /// 点击回调 —— 真正的启动编排在外部（LaunchEntryViewModel）。
    let onTap: () -> Void

    /// 点击时放大到 1.15 再回弹。用可取消 Task 而非 DispatchQueue：视图销毁后不再写 State。
    @State private var buttonScale: CGFloat = 1.0
    /// 弹跳动画的持有者；onDisappear 会 cancel 它。
    @State private var scaleTask: Task<Void, Never>?

    // 「死动画」锁：动画播完前不响应新相位，排队到 pendingPhase，杜绝转场被中途打断
    @State private var displayedPhase: LaunchPhase = .idle
    @State private var pendingPhase: LaunchPhase?
    @State private var phaseTransitionActive = false
    @State private var phaseTransitionTask: Task<Void, Never>?

    /// 相位切换共用的一条弹簧曲线。`beginPhaseTransition` 里 0.8 秒的锁定时长
    /// 就是按它（response 0.5）的视觉完播时间估出来的。
    private static let phaseSpring = Animation.spring(response: 0.5, dampingFraction: 0.7)

    /// 相位调度：只在「空闲」时立刻切；动画进行中则**排队**（只保留最后一个目标）。
    /// 目标与当前显示相位相同则直接忽略，避免触发一次无意义的动画。
    private func schedulePhaseChange(to newPhase: LaunchPhase) {
        guard newPhase != displayedPhase else { return }
        guard !phaseTransitionActive else {
            pendingPhase = newPhase
            return
        }
        beginPhaseTransition(to: newPhase)
    }

    /// 真正执行一次相位切换：换相位 → 上锁 0.8 秒 → 解锁后若有排队目标则继续。
    /// ⚠️ 锁定时长是**固定估计值**（对应 spring(0.5) 的视觉完播时长），不是动画完成回调 ——
    /// 太短会让转场被下一相位打断，太长会让连续相位变化显得迟滞。
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
            // 点击弹跳动画（可取消 Task：视图销毁后不再写已释放的 State storage）。
            // 先 cancel 上一次的 Task —— 连点两次时后一次接管，不会有两个 Task 同时改 buttonScale。
            scaleTask?.cancel()
            withAnimation(.punchySpring) { buttonScale = 1.15 }
            scaleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.punchySpring) { buttonScale = 1.0 }
            }
            onTap()
        }) {
            // 图层自下而上：两条进度条 → 圆角底 → 文案。进度条只在对应相位才插入。
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
                    // 文案用一串 if 而非 switch，每个相位一段独立文案；
                    // idle 那段还带「从下方进、向上出」的转场（见下面的 transition）。
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
            // mask：把两条矩形进度条的直角裁成与按钮一致的圆角。必须在 frame 之后。
            .mask(RoundedRectangle(cornerRadius: 25).frame(width: buttonWidth, height: 50))
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(buttonScale)
        .animation(.punchySpring, value: buttonScale)
        .disabled(isLaunching)
        .padding(.bottom, 30)
        // ⚠️ 这里监听的是**外部**传入的 launchPhase，而界面渲染用的是内部 displayedPhase。
        // 两者由上面的排队机制解耦 —— 这是本组件「死动画」防护的核心。
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
