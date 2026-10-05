//
//  MicrosoftLoginCardView.swift
//  微软账号登录的设备码覆盖层卡片 + 启动页账号行。
//
//  出现时机：用户点了启动页的「微软账号登录」按钮，
//  `MicrosoftLoginViewModel` 已从 MSA 拿到设备码（状态 `.waitingForCode`）。
//
//  职责边界：本视图是**纯展示组件** —— 只订阅 `viewModel.phase` 渲染，
//  不查网络、不读持久化、不拼文案。状态迁移与副作用全在
//  `MicrosoftLoginViewModel`（Features/Account/MicrosoftLoginViewModel.swift）；
//  本视图唯一的自身动作是「打开浏览器验证页」与「复制设备码」两个
//  AppKit 交互（NSWorkspace / NSPasteboard，视图层职责）。
//
//  视觉语言刻意**向皮肤补丁卡对齐**（见 Features/Skin/SkinPatchCardView.swift）：
//  圆角 16 + `secondary 6%` 底 + 居中覆盖层；设备码用等宽字体大号展示，
//  强调「这串码要输入到 microsoft.com/link」。
//
//  布局（自上而下）：标题行（图标 + 标题 + 关闭）→ 步骤说明 → 设备码大字 →
//  验证页地址 → 操作按钮行（打开页面 / 复制代码）。
//

import SwiftUI
import AppKit

/// 微软登录设备码卡片。
struct MicrosoftLoginCardView: View {
    /// 登录状态机与副作用编排者。本视图**只读** `phase`，改写一律经它的方法。
    @ObservedObject var viewModel: MicrosoftLoginViewModel

    /// 入场动画开关：初值 false（缩放 0.85 + 全透明），`onAppear` 之后置 true 触发弹入。
    /// ⚠️ 初值必须为 false，否则没有可动画的起始态。
    @State private var showContent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── 标题行
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34, alignment: .center)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("微软账号登录")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer(minLength: 8)
                        // 关闭按钮恒在（右上角）——任何状态都必须能退出这张卡片
                        Button(action: { viewModel.cancelLogin() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // ── 步骤说明
            Text("请在浏览器打开下面地址，输入卡片上的代码完成授权。授权后本启动器会自动登录并保存账号。")
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // ── 设备码大字
            if let code = viewModel.currentDeviceCode {
                Text(code.userCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)

                // ── 验证页地址
                Text(code.verificationURI)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .textSelection(.enabled)
            }

            // ── 等待中的轮询进度
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            // ── 操作按钮行
            HStack(spacing: 10) {
                if let code = viewModel.currentDeviceCode {
                    Button(action: { openVerificationPage(code.verificationURI) }) {
                        Label("打开页面", systemImage: "safari")
                    }
                    Button(action: { copyUserCode(code.userCode) }) {
                        Label("复制代码", systemImage: "doc.on.doc")
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { viewModel.cancelLogin() }
            }
            .font(.system(size: 13))
        }
        .padding(20)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(radius: 12)
        // 缩放弹入：初值 0.85 + 透明 → onAppear 后 1.0 + 不透明
        .scaleEffect(showContent ? 1.0 : 0.85)
        .opacity(showContent ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showContent = true
            }
        }
    }

    // MARK: - AppKit 交互（视图层职责）

    private func openVerificationPage(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyUserCode(_ userCode: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(userCode, forType: .string)
    }
}