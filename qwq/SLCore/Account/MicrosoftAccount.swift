//
//  MicrosoftAccount.swift
//  微软账号：`Account` 协议的真实实现（替代原桩实现）。
//
//  背景：`AnyAccount.microsoft` 原先用 `OfflineAccount` 承载（桩），
//  登录流程不存在、运行期按离线账号处理。本文件把它换成真实实现：
//  持有 Minecraft access token（启动注入）与 MSA refresh_token（续期用），
//  并提供「刷新令牌链」能力（MSA refresh → XBL → XSTS → MC，见
//  `MicrosoftAuthService`（SLCore/Account/MicrosoftAuthService.swift））。
//
//  职责：**只描述账号的状态与刷新**。网络认证全在 `MicrosoftAuthService`；
//  持久化经 `AnyAccount` / `AccountManager`（SLCore/Account/AnyAccount.swift）。
//  刷新成功后经 `AccountManager.upsert(_:)` 回写持久化（CodableAppStorage
//  每次读都重新解码 UserDefaults，直接原地改实例不会落盘）。
//
//  并发：本类型不显式标注隔离。工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
//  未标注类默认主 actor 隔离；与 `OfflineAccount`（同目录）的既有写法保持一致。
//  刷新是 async，实际网络在 `MicrosoftAuthService`（nonisolated）完成。
//
//  注释引用约定：一律写「文件 + 符号/场景」，不写行号。
//

import Foundation

/// 微软账号（**真实实现**，非桩）。
/// 使用方：
///  - `AnyAccount.microsoft(_:)` 的关联值类型（SLCore/Account/AnyAccount.swift）；
///  - 启动桥 `SLLaunchBridge`（选中微软账号时以 `ms.name` / `ms.uuid` / 令牌构造
///    `LaunchOptions`，见「账号选择」分支）；
///  - 启动用例层 `MinecraftInstanceLaunchService`（启动前 `refreshIfNeeded()` 刷新令牌）；
///  - UI 层 `MicrosoftLoginViewModel`（登录完成后构造本类型并 upsert 到 AccountManager）。
public final class MicrosoftAccount: Account {
    /// 账号实例 id（随机；`getAccount()` 的匹配依据，与 MC 档案 uuid 是两回事）
    public let id: UUID
    /// MC 档案 UUID（带连字符的标准格式，来自 profile.id 32 位 hex）
    public var uuid: UUID
    /// MC 用户名（来自 profile.name）
    public var name: String
    /// MSA refresh_token（续期 MSA access_token 用；被刷新令牌链消费）
    public var msaRefreshToken: String
    /// Minecraft access token（启动时注入 `LaunchOptions.accessToken`）
    public var accessToken: String
    /// accessToken 的过期时刻
    public var accessTokenExpiry: Date

    public init(
        id: UUID = UUID(),
        uuid: UUID,
        name: String,
        msaRefreshToken: String,
        accessToken: String,
        accessTokenExpiry: Date
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.msaRefreshToken = msaRefreshToken
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
    }

    // MARK: - Account

    /// 启动前令牌注入：离线账号注入「UUID 本身」（PCL2 规则），
    /// 微软账号注入**真实的 Minecraft access token**。
    public func putAccessToken(options: LaunchOptions) {
        options.accessToken = accessToken
    }

    // MARK: - 可用性判定

    /// 是否具备启动所需的身份信息（有用户名、有令牌）。
    /// 使用方：`SLLaunchBridge`（账号选择分支）、`MinecraftInstanceLaunchService`（启动前刷新判定）。
    public var isUsable: Bool {
        !name.isEmpty && !accessToken.isEmpty
    }

    /// 令牌是否临近过期 / 缺失（过期前 5 分钟即视为需刷新）。
    public var needsRefresh: Bool {
        accessToken.isEmpty || Date() >= accessTokenExpiry.addingTimeInterval(-5 * 60)
    }

    // MARK: - 刷新

    /// 令牌临近过期时刷新整条链（MSA refresh → XBL → XSTS → MC → 档案）。
    /// 刷新成功后原地更新字段并回写 `AccountManager` 持久化。
    /// 使用方：`MinecraftInstanceLaunchService.launch`（启动前）、
    /// `MicrosoftLoginViewModel`（登录后主动刷新）。
    public func refreshIfNeeded() async throws {
        guard needsRefresh else { return }
        try await refresh()
    }

    /// 强制刷新整条令牌链。refresh_token 失效时抛
    /// `MicrosoftAuthError.refreshTokenInvalid`，调用方应引导用户重新走设备码登录。
    public func refresh() async throws {
        guard let refreshed = try await MicrosoftAuthService.refreshMSAToken(refreshToken: msaRefreshToken) else {
            throw MicrosoftAuthError.refreshTokenInvalid
        }
        let chain = try await MicrosoftAuthService.completeLogin(
            msaAccessToken: refreshed.accessToken,
            msaRefreshToken: refreshed.refreshToken
        )
        msaRefreshToken = refreshed.refreshToken
        accessToken = chain.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(chain.expiresIn))
        uuid = MicrosoftAccount.uuid(fromProfileID: chain.profile.id)
        name = chain.profile.name
        AccountManager.shared.upsert(.microsoft(self))
    }

    // MARK: - profile.id → UUID

    /// profile.id 是 32 位 hex（无连字符），转成标准 8-4-4-4-12 UUID 字符串。
    /// 与 `OfflineAccount.formatUuid` 是同一格式化逻辑，但语义不同源
    /// （一个是离线算法产物、一个是微软档案字段），故不跨文件复用。
    public static func uuid(fromProfileID hex: String) -> UUID {
        let h = hex.lowercased()
        if h.count != 32 { return UUID() }
        let parts = [
            String(h.prefix(8)),
            String(h.dropFirst(8).prefix(4)),
            String(h.dropFirst(12).prefix(4)),
            String(h.dropFirst(16).prefix(4)),
            String(h.dropFirst(20).prefix(12))
        ]
        return UUID(uuidString: parts.joined(separator: "-")) ?? UUID()
    }
}