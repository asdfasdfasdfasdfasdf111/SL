//
//  SettingsPageView.swift
//  应用内「设置」页（分类标签第 5 页，2026-10-11 取代原「赞助」页）。
//
//  区块：① 账号 · 微软登录（Azure 应用 id 配置，逻辑与 ⌘, 窗口的
//  AccountSettingsView 同源——同一绑定键 UDK.microsoftClientID，填完即生效）；
//  ② 关于（当前版本 + 手动检查更新）；③ 赞助（原赞助页的卡片整体迁入）。
//
//  风格：与其余分类页一致的白 9% 玻璃面板（圆角 24 + 阴影），不做挖洞——
//  本页各面板都是**第一层**玻璃（底下没有别的玻璃面板），无堆叠问题。
//

import SwiftUI

struct SettingsPageView: View {
    /// 主题来源由调用方注入（与其余分类页签名一致）
    let theme: ThemeManager
    @ObservedObject private var settings = LauncherSettings.shared

    /// client id 配置自检结果（nil = 尚未验证）
    @State private var checkMessage: String?
    @State private var isChecking = false

    private let azurePortalURL = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                accountPanel
                aboutPanel
                sponsorPanel
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 面板底材（与其余分类页同一玻璃语言）

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        )
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - ① 账号 · 微软登录

    private var accountPanel: some View {
        panel {
            Label("微软登录 · 应用 ID", systemImage: "person.crop.circle")
                .font(.headline)
                .foregroundColor(.primary)
            TextField("留空 = 内置 PrismLauncher 公开 id", text: $settings.microsoftClientID)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.14))
                )
            HStack(spacing: 12) {
                actionButton(isChecking ? "验证中…" : "验证配置") { checkConfiguration() }
                    .disabled(isChecking || settings.microsoftClientID.isEmpty)
                actionButton("恢复内置默认") { settings.microsoftClientID = "" }
                    .disabled(settings.microsoftClientID.isEmpty)
                actionButton("打开发应用注册页") { openAzurePortal() }
            }
            if let checkMessage {
                Text(checkMessage)
                    .font(.caption)
                    .foregroundColor(checkMessage.hasPrefix("✅") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("设备码登录需要一个微软侧注册过的应用 id：留空用内置公开 id（随时可能被下线），"
                 + "自己注册一个免费的即可长期稳定。填写后立即生效，无需重启。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 用当前生效的 client id 真发一次设备码请求（与 ⌘, 窗口的 AccountSettingsView 同一逻辑）：
    /// 成功即配置可用，设备码用完即弃、自行过期，不留任何会话。
    private func checkConfiguration() {
        isChecking = true
        checkMessage = nil
        Task {
            do {
                let code = try await MicrosoftAuthService.startDeviceCode()
                checkMessage = "✅ 配置可用：已成功获取设备码（\(code.userCode)），可以正常登录。"
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                checkMessage = "⚠️ 验证失败：\(text)"
            }
            isChecking = false
        }
    }

    private func openAzurePortal() {
        if let url = URL(string: azurePortalURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - ② 关于

    private var aboutPanel: some View {
        panel {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SL启动器").font(.headline).foregroundColor(.primary)
                    Text("版本 \(AppUpdateService.currentVersion())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                actionButton("检查更新…") {
                    Task { await AppUpdateCoordinator.shared.checkAndPromptIfNeeded(force: true) }
                }
            }
        }
    }

    // MARK: - ③ 赞助

    private var sponsorPanel: some View {
        panel {
            Label("赞助", systemImage: "heart")
                .font(.headline)
                .foregroundColor(.primary)
            HStack(spacing: 20) {
                SponsorCard(imageName: "sponsor1", title: "赞助方式一")
                SponsorCard(imageName: "sponsor2", title: "赞助方式二")
                ThanksCard()
            }
        }
    }
}
