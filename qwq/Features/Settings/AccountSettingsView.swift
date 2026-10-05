//
//  AccountSettingsView.swift
//  「设置 → 账号」页：配置微软登录用的 Azure 应用 id（client id）。
//
//  为什么需要这一页：微软登录走 OAuth 2.0 设备码流程，**必须**有一个在微软侧
//  注册过的应用 id。本项目此前借用微软官方 Minecraft Launcher 的公开 id
//  `00000000402b5328`（PCL2 / HMCL 早年也这么做）；该 id 已被微软下线
//  （设备码端点返回 `AADSTS700016 应用不存在`，2026-10-05 实测），于是换成了
//  PrismLauncher 公开注册的那个 id —— 能用，但仍然是「借别人的应用注册」，
//  随时可能再次失效。所以把 id 做成用户可配置：注册一个免费的个人 Azure 应用
//  即可，无需 client secret、无需重定向 URI（设备码流程不使用重定向）。
//
//  现在各家启动器都改为**各自注册** Azure 应用（HMCL、PrismLauncher 的源码里
//  client id 都来自各自的构建配置/自有注册），因此本项目也把 id 交给用户配置：
//  注册一个免费的个人 Azure 应用即可，无需 client secret、无需重定向 URI
//  （设备码流程不使用重定向）。
//
//  存储：写入 `AppSettingsStore.microsoftClientID`（键 `UDK.microsoftClientID`）。
//  `MicrosoftAuthService.clientID` 是 nonisolated 的，直接从同一个 UserDefaults 键
//  读取，因此**填完立即生效**，不需要重启应用。
//

import SwiftUI
import AppKit

struct AccountSettingsView: View {
    @ObservedObject var settings = LauncherSettings.shared

    /// 配置自检的结果文案（nil = 尚未验证）。
    @State private var checkMessage: String?
    /// 自检是否在跑（按钮禁用 + 转圈）。
    @State private var isChecking = false

    /// 微软注册应用页（Azure 门户 → 应用注册）。
    private let azurePortalURL = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("微软账号登录")
                .font(.largeTitle.bold())
                .padding(.top, 32)

            Text("登录默认借用 PrismLauncher（开源）公开注册的应用 id，开箱即可用。"
                 + "但那是**别人的应用注册**，微软或对方随时可能让它失效 —— 本项目上一版借用的"
                 + "微软官方 Minecraft Launcher id 就是这样被下线的。"
                 + "想要长期稳定，请自己注册一个（免费、2 分钟、无需 client secret、无需重定向 URI），"
                 + "把「应用程序(客户端) ID」填在下面。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // ── client id 输入
            VStack(alignment: .leading, spacing: 8) {
                Text("应用程序(客户端) ID")
                    .font(.headline)
                TextField("例如 12345678-1234-1234-1234-123456789abc", text: $settings.microsoftClientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                Text("留空＝用内置的 PrismLauncher 公开 id（\(MicrosoftAuthConstants.fallbackClientID)）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ── 操作按钮
            HStack(spacing: 12) {
                Button("打开发应用注册页") { openAzurePortal() }
                Button(isChecking ? "验证中…" : "验证配置") { checkConfiguration() }
                    .disabled(isChecking || settings.microsoftClientID.isEmpty)
                Button("恢复内置默认") { settings.microsoftClientID = "" }
                    .disabled(settings.microsoftClientID.isEmpty)
            }

            if let checkMessage {
                Text(checkMessage)
                    .font(.callout)
                    .foregroundColor(checkMessage.hasPrefix("✅") ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 4)

            // ── 注册步骤（折叠文本，直接给可照做的动作）
            VStack(alignment: .leading, spacing: 6) {
                Text("怎么拿到这个 ID").font(.headline)
                Text("1. 点上面的「打开发应用注册页」，用任意微软账号登录（个人账号即可）。")
                Text("2. 「新注册」→ 名称随意（如 swim111-launcher）→ 受支持的账户类型选"
                     + "「仅此组织目录中的账户」以外的任一项 → 注册。")
                Text("3. 在应用概览页复制「应用程序(客户端) ID」，粘贴到上面的输入框。")
                Text("4. 点「验证配置」，出现 ✅ 即表示这个 id 可以走设备码流程了。")
            }
            .font(.callout)
            .foregroundColor(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 用当前生效的 client id 真发一次设备码请求：成功即配置可用（设备码用完即弃、
    /// 会自行过期，不会留下任何会话）。
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
}
