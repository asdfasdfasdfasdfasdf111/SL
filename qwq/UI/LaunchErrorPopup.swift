//
//  LaunchErrorPopup.swift
//  启动 / 下载失败弹窗（样式对齐既有「任务气泡」JavaSelectionPopup）。
//
//  为什么不再用系统 `.alert("启动失败")`：
//  系统 alert 是 macOS 的原生模态，与本启动器整体的毛玻璃语言不一致；而用户对「失败」
//  已经有一个熟悉的形状——下载 / 安装期间浮出的那颗圆角毛玻璃气泡。失败提示沿用同一套
//  视觉语言（同材料、同圆角、同描边、同弹簧曲线），界面里就只剩一种「发生了一件事」的形状。
//
//  与 JavaSelectionPopup 的唯一差异在**语义**，不是样式：
//  气泡是瞬时通知（1.5s 自动消失、不拦点击），本弹窗是必须被确认的失败——
//  不自隐、半透明遮罩拦截全部点击，避免用户在错误未处理时继续点启动。
//

import SwiftUI

struct LaunchErrorPopup: View {

    /// 失败正文（唯一文案来源仍是 `LauncherSettings.launchErrorMessage`）
    let message: String
    /// 确认（或点击遮罩）后回调，由 `LaunchPanelState.dismissError()` 清状态
    let onDismiss: () -> Void

    @State private var cardScale: CGFloat = 0.85
    @State private var cardOpacity: Double = 0
    @State private var backdropOpacity: Double = 0

    var body: some View {
        ZStack {
            // 遮罩：同时承担「视觉聚焦」与「拦截点击」两个职责。
            // 显式 contentShape：Color 铺满时默认命中区域已覆盖全窗，这里只是把意图写明，
            // 后续若把 Color 换成非铺满图形也不会静默失去拦截能力。
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("启动失败")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)

                Button(action: dismiss) {
                    Text("确定")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.16))
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 15, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .scaleEffect(cardScale)
            .opacity(cardOpacity)
        }
        .onAppear {
            // 与 JavaSelectionPopup 同因：onAppear 处于视图更新事务中，
            // 同步写 @State 会触发 "Modifying state during view update"（UAF 前兆），
            // 延迟到渲染事务外执行
            DispatchQueue.main.async {
                withAnimation(.exaggeratedSpring) {
                    cardScale = 1
                    cardOpacity = 1
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    backdropOpacity = 0.28
                }
            }
        }
    }

    private func dismiss() {
        withAnimation(.explosiveSpring) {
            cardScale = 0.85
            cardOpacity = 0
        }
        withAnimation(.easeOut(duration: 0.2)) {
            backdropOpacity = 0
        }
        // 退场动画播完再复位状态：延时口径与 JavaSelectionPopup 的退场一致（0.3s）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}
