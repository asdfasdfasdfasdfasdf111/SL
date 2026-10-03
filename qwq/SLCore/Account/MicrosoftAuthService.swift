//
//  MicrosoftAuthService.swift
//  微软账号登录的全链路认证服务（设备码流程 + MSA→XBL→XSTS→MC 令牌链）。
//
//  背景：Minecraft 启动器的微软登录**不需要注册自有 Azure 应用**。
//  PCL2 / HMCL / BakaXL 等第三方启动器均复用微软官方 Minecraft Launcher 的
//  公开 client id `00000000402b5328`（public client，无 client secret），
//  走 OAuth 2.0 **设备码流程**（Device Code Flow）：应用拿到一串设备码，
//  用户在浏览器里打开 microsoft.com/link 输入该码完成授权，应用轮询拿到令牌。
//
//  令牌链（一步都不能省，PCL2 ModLogin 等价流程）：
//    1. MSA 设备码 → 轮询 token 端点 → MSA access_token + refresh_token
//    2. MSA token → user.auth.xboxlive.com 换 Xbox Live user token + uhs
//    3. XBL token → xsts.auth.xboxlive.com 换 XSTS token（rp: api.minecraftservices.com）
//    4. XSTS token → api.minecraftservices.com/authentication/login_with_xbox 换 MC token
//    5. MC token → /minecraft/profile 拿用户名 + UUID（建档）
//
//  职责：**本文件只做网络认证**，不碰持久化、不碰 UI。
//  `MicrosoftAccount`（SLCore/Account/MicrosoftAccount.swift）是认证结果的承载，
//  持久化在 `AnyAccount` / `AccountManager`（SLCore/Account/AnyAccount.swift）。
//
//  并发：本服务是无状态纯函数集，全部方法 `nonisolated`，
//  不依赖 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 的默认隔离。
//  网络层刻意**不复用** `AppContext.shared.apiSession`：
//  设备码轮询的时间语义（interval/expires_in）由端点返回，轮询间隔可达数秒，
//  与 apiSession 的 10s 请求超时 / 4 并发语义无关，独立会话更清晰。
//
//  注释引用约定：一律写「文件 + 符号/场景」，不写行号。
//

import Foundation

// MARK: - 端点与常量

/// 微软登录相关常量。client id 为微软官方 Minecraft Launcher 的公开 client id
///（public client），第三方启动器合法复用，无需注册 Azure 应用、无 client secret。
public enum MicrosoftAuthConstants {
    /// 微软官方 Minecraft Launcher 的公开 client id
    public static let clientID = "00000000402b5328"
    /// 设备码流程需要的 scope：`XboxLive.signin` 换取 XBL 资格，`offline_access` 拿 refresh_token
    public static let scope = "XboxLive.signin offline_access"
    /// 消费级账号（消费者租户）的 OAuth2 端点
    public static let deviceCodeURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")!
    public static let tokenURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
    /// XBL / XSTS / Minecraft 服务端点
    public static let xblAuthenticateURL = URL(string: "https://user.auth.xboxlive.com/user/authenticate")!
    public static let xstsAuthorizeURL = URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!
    public static let minecraftLoginURL = URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!
    public static let minecraftProfileURL = URL(string: "https://api.minecraftservices.com/minecraft/profile")!
}

// MARK: - 错误

/// 微软登录过程中的错误。`errorDescription` 直接面向用户展示。
/// 枚举刻意**不用** `AccountError`（那条枚举语义是「能力尚未实现」，
/// 本枚举是「已实现但认证失败」，两者语义相反，见 AnyAccount.swift 的语义约定）。
public enum MicrosoftAuthError: LocalizedError, Equatable {
    /// 网络/HTTP 层错误
    case network(String)
    /// 服务端返回了无法解析的响应
    case badResponse(String)
    /// 设备码已过期（expired_token）——需要重新发起设备码流程
    case deviceCodeExpired
    /// 用户在浏览器里拒绝了授权（access_denied）
    case userDenied
    /// 该微软账号没有 Xbox Live 资格（XSTS 拒绝）
    case noXboxLiveAccount(String)
    /// 该账号的 Xbox 身份已被占用
    case minecraftClaimed(String)
    /// 该账号没有 Minecraft 正版资格（login_with_xbox 拒绝）
    case noMinecraftLicense(String)
    /// 拉取 Minecraft 档案失败（profile 404 / 无档案）
    case noMinecraftProfile
    /// refresh_token 失效，需要重新走设备码登录
    case refreshTokenInvalid
    /// 用户主动取消（UI 层的取消令牌触发）
    case cancelled
    /// 令牌链中途某一步返回了非预期状态码（带端点与状态码）
    case unexpectedStatus(endpoint: String, code: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .network(let message):
            return "网络错误：\(message)"
        case .badResponse(let message):
            return "微软服务器返回了无法解析的数据：\(message)"
        case .deviceCodeExpired:
            return "设备码已过期，请重新发起登录。"
        case .userDenied:
            return "你已在浏览器中取消授权。"
        case .noXboxLiveAccount(let detail):
            return "该微软账号没有可用的 Xbox Live 档案（\(detail)）。请先在 xbox.com 完成注册。"
        case .minecraftClaimed(let detail):
            return "该微软账号的 Xbox 身份已被占用（\(detail)）。"
        case .noMinecraftLicense(let detail):
            return "该微软账号没有 Minecraft 正版资格（\(detail)）。请先在微软商店购买 Minecraft。"
        case .noMinecraftProfile:
            return "该账号没有可用的 Minecraft 档案。"
        case .refreshTokenInvalid:
            return "登录已失效（refresh token 无效），请重新登录。"
        case .cancelled:
            return "登录已取消。"
        case .unexpectedStatus(let endpoint, let code, let body):
            return "认证请求失败（HTTP \(code)）：\(endpoint) \(body.prefix(200))"
        }
    }
}

// MARK: - 设备码

/// 设备码流程第一步（POST devicecode）的返回。
/// `nonisolated` 是**必需**的：本类型在 `MicrosoftAuthService`（nonisolated）里
/// 被 `JSONDecoder().decode` 消费；工程默认 MainActor 隔离会把未标注的 Codable
/// 一致性一起隔离（"main actor-isolated conformance of 'X' to 'Decodable'…"，见
/// xcodebuild-in-sandbox skill 的隔离一致性条目），nonisolated 上下文使用即告警。
nonisolated public struct MicrosoftDeviceCode: Codable, Equatable {
    /// 轮询 token 端点时使用的设备码（与应用内流转，不展示给用户）
    public let deviceCode: String
    /// 展示给用户的短码（8 位，用户在 microsoft.com/link 输入）
    public let userCode: String
    /// 用户在浏览器打开的验证页
    public let verificationURI: String
    /// 设备码有效秒数
    public let expiresIn: Int
    /// 轮询间隔秒数
    public let interval: Int
    /// 服务端给的展示文案（可为空）
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
        case message
    }
}

// MARK: - 轮询结果

/// 设备码轮询 token 端点的一次结果。
public enum MicrosoftPollResult: Equatable {
    /// 拿到了 MSA 令牌
    case success(accessToken: String, refreshToken: String, expiresIn: Int)
    /// 用户还没在浏览器里完成授权，`interval` 秒后再轮询
    case pending(interval: Int)
    /// 用户在浏览器里拒绝了授权
    case denied
    /// 设备码过期，必须重新发起流程
    case expired
    /// 服务端要求放慢轮询速度
    case slowDown(interval: Int)
}

// MARK: - 令牌链中间结果

/// XBL / XSTS 或 MC login 返回的通用结构：令牌 + 用户哈希（uhs，用于拼接 identityToken）。
/// `nonisolated` 理由同 `MicrosoftDeviceCode`（在 nonisolated 服务里被 decode）。
private nonisolated struct XboxTokenResponse: Codable {
    struct DisplayClaims: Codable {
        struct XUI: Codable {
            let uhs: String?
        }
        let xui: [XUI]
    }
    let token: String?
    let displayClaims: DisplayClaims?

    enum CodingKeys: String, CodingKey {
        case token = "Token"
        case displayClaims = "DisplayClaims"
    }
}

/// MSA token 端点（token 端点）的响应。`nonisolated` 理由同上。
private nonisolated struct MicrosoftTokenResponse: Codable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case error
        case errorDescription = "error_description"
    }
}

/// Minecraft 档案（profile）。`nonisolated` 理由同 `MicrosoftDeviceCode`。
nonisolated public struct MinecraftProfile: Codable, Equatable {
    /// MC 档案 UUID（无连字符的 32 位 hex）
    public let id: String
    /// MC 用户名
    public let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}

// MARK: - 认证服务

/// 微软登录全链路认证服务。无状态、`nonisolated`，可被任意并发上下文调用。
public enum MicrosoftAuthService {

    // MARK: 1. 设备码流程

    /// 发起设备码流程：向 MSA 申请一组设备码 + 用户码。
    /// 调用方应把 `userCode` 与 `verificationURI` 展示给用户（UI 层负责），
    /// 然后以 `interval` 为间隔调用 `pollForToken(deviceCode:)`。
    public static func startDeviceCode() async throws -> MicrosoftDeviceCode {
        var components = URLComponents(url: MicrosoftAuthConstants.deviceCodeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: MicrosoftAuthConstants.clientID),
            URLQueryItem(name: "scope", value: MicrosoftAuthConstants.scope)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.badResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MicrosoftAuthError.unexpectedStatus(endpoint: "devicecode", code: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(MicrosoftDeviceCode.self, from: data)
        } catch {
            throw MicrosoftAuthError.badResponse("devicecode 响应解析失败: \(error.localizedDescription)")
        }
    }

    /// 轮询 token 端点一次。返回 `pending` 时应等 `interval` 秒后重调；
    /// 返回 `success` 即拿到了 MSA 令牌，可进入角色链。
    public static func pollForToken(deviceCode: MicrosoftDeviceCode) async throws -> MicrosoftPollResult {
        let form = [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": MicrosoftAuthConstants.clientID,
            "device_code": deviceCode.deviceCode
        ]
        let (data, response) = try await postForm(MicrosoftAuthConstants.tokenURL, form: form)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.badResponse("非 HTTP 响应")
        }

        // 400 是设备码流程的**正常**等待态（authorization_pending / slow_down / access_denied / expired_token）
        if http.statusCode == 400 {
            let decoded = (try? JSONDecoder().decode(MicrosoftTokenResponse.self, from: data))
                ?? MicrosoftTokenResponse(accessToken: nil, refreshToken: nil, expiresIn: nil, error: "unknown", errorDescription: nil)
            switch decoded.error {
            case "authorization_pending":
                return .pending(interval: deviceCode.interval)
            case "slow_down":
                return .slowDown(interval: deviceCode.interval + 5)
            case "access_denied":
                return .denied
            case "expired_token":
                return .expired
            default:
                throw MicrosoftAuthError.unexpectedStatus(
                    endpoint: "token(device_code)", code: http.statusCode,
                    body: decoded.errorDescription ?? decoded.error ?? "未知错误")
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MicrosoftAuthError.unexpectedStatus(endpoint: "token(device_code)", code: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(MicrosoftTokenResponse.self, from: data)
        guard let accessToken = decoded.accessToken else {
            throw MicrosoftAuthError.badResponse("token 响应缺少 access_token")
        }
        return .success(
            accessToken: accessToken,
            refreshToken: decoded.refreshToken ?? "",
            expiresIn: decoded.expiresIn ?? 3600
        )
    }

    /// 等待用户在浏览器完成授权：阻塞轮询直到成功 / 拒绝 / 过期。
    /// 供 UI 层的 ViewModel 使用（它在后台任务里等结果，主线程只展示状态）。
    /// `checkCancelled` 每轮询一次被调用一次，返回 true 时抛 cancellationError。
    public static func waitForAuthorization(
        deviceCode: MicrosoftDeviceCode,
        checkCancelled: @escaping () -> Bool = { false },
        cancellationError: Error
    ) async throws -> (accessToken: String, refreshToken: String) {
        var interval = deviceCode.interval
        let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expiresIn))
        while Date() < deadline {
            if checkCancelled() { throw cancellationError }
            // 轮询间隔由服务端下发（devicecode 响应的 interval 字段）：微软明确要求
            // 按该间隔轮询 token 端点，过快会返回 slow_down。此处时长**不是本工程自选**，
            // 而是沿用端点给定的秒数（slow_down 时 +5 再等），到期后立即重询 token。
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let result = try await pollForToken(deviceCode: deviceCode)
            switch result {
            case .success(let accessToken, let refreshToken, _):
                return (accessToken, refreshToken)
            case .pending(let nextInterval):
                interval = nextInterval
            case .slowDown(let nextInterval):
                interval = max(nextInterval, interval + 5)
            case .denied:
                throw MicrosoftAuthError.userDenied
            case .expired:
                throw MicrosoftAuthError.deviceCodeExpired
            }
        }
        throw MicrosoftAuthError.deviceCodeExpired
    }

    // MARK: 2. 补齐完整令牌链

    /// 由 MSA 令牌补齐 Xbox→XSTS→MC→档案 全链路，产出完整 MicrosoftAccount。
    public static func completeLogin(
        msaAccessToken: String,
        msaRefreshToken: String
    ) async throws -> (accessToken: String, profile: MinecraftProfile, expiresIn: Int) {
        // 2. MSA → XBL
        let xbl = try await authenticateXboxLive(msaToken: msaAccessToken)
        guard let xblToken = xbl.token else {
            throw MicrosoftAuthError.badResponse("XBL 响应缺少 Token")
        }
        guard let uhs = xbl.displayClaims?.xui.first?.uhs else {
            throw MicrosoftAuthError.badResponse("XBL 响应缺少 uhs")
        }

        // 3. XBL → XSTS
        let xsts = try await authorizeXSTS(userToken: xblToken)
        guard let xstsToken = xsts.token else {
            throw MicrosoftAuthError.badResponse("XSTS 响应缺少 Token")
        }

        // 4. XSTS → MC access token
        let identityToken = "XBL3.0 x=\(uhs);\(xstsToken)"
        let mcToken = try await loginWithXbox(identityToken: identityToken)

        // 5. 拉档案
        let profile = try await fetchProfile(accessToken: mcToken.accessToken)

        return (accessToken: mcToken.accessToken, profile: profile, expiresIn: mcToken.expiresIn)
    }

    // MARK: 3. 续期

    /// 刷新令牌：用 MSA refresh_token 换一组新的 MSA access_token + refresh_token。
    /// 返回 nil 表示 refresh_token 已失效（服务端返回 invalid_grant），
    /// 调用方应转向「重新设备码登录」。
    public static func refreshMSAToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String)? {
        let form = [
            "grant_type": "refresh_token",
            "client_id": MicrosoftAuthConstants.clientID,
            "scope": MicrosoftAuthConstants.scope,
            "refresh_token": refreshToken
        ]
        let (data, response) = try await postForm(MicrosoftAuthConstants.tokenURL, form: form)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.badResponse("非 HTTP 响应")
        }

        if http.statusCode == 400 {
            let decoded = (try? JSONDecoder().decode(MicrosoftTokenResponse.self, from: data))
                ?? MicrosoftTokenResponse(accessToken: nil, refreshToken: nil, expiresIn: nil, error: "unknown", errorDescription: nil)
            if decoded.error == "invalid_grant" {
                return nil
            }
            throw MicrosoftAuthError.unexpectedStatus(
                endpoint: "token(refresh)", code: http.statusCode,
                body: decoded.errorDescription ?? decoded.error ?? "未知错误")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MicrosoftAuthError.unexpectedStatus(endpoint: "token(refresh)", code: http.statusCode, body: body)
        }
        let decoded = try JSONDecoder().decode(MicrosoftTokenResponse.self, from: data)
        guard let accessToken = decoded.accessToken else {
            throw MicrosoftAuthError.badResponse("refresh 响应缺少 access_token")
        }
        return (accessToken, decoded.refreshToken ?? refreshToken)
    }

    // MARK: 内部 HTTP 实现

    /// XBL user token：POST user.auth.xboxlive.com/user/authenticate
    private static func authenticateXboxLive(msaToken: String) async throws -> XboxTokenResponse {
        let payload: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": msaToken
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT"
        ]
        let (data, response) = try await postJSON(MicrosoftAuthConstants.xblAuthenticateURL, json: payload)
        _ = response
        return try decodeOrThrow(XboxTokenResponse.self, data: data, endpoint: "xbl")
    }

    /// XSTS token：POST xsts.auth.xboxlive.com/xsts/authorize
    /// 401 是「账号没有 Xbox Live / 已被占用」的常见返回，需转成用户可读错误。
    private static func authorizeXSTS(userToken: String) async throws -> XboxTokenResponse {
        let payload: [String: Any] = [
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [userToken]
            ],
            "RelyingParty": "rp://api.minecraftservices.com/",
            "TokenType": "JWT"
        ]
        let (data, response) = try await postJSON(MicrosoftAuthConstants.xstsAuthorizeURL, json: payload)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.badResponse("非 HTTP 响应")
        }
        if http.statusCode == 401 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if let xErr = extractXErr(from: body) {
                throw MicrosoftAuthError.noXboxLiveAccount("XErr=\(xErr)")
            }
            throw MicrosoftAuthError.noXboxLiveAccount("HTTP 401")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MicrosoftAuthError.unexpectedStatus(endpoint: "xsts", code: http.statusCode, body: body)
        }
        return try decodeOrThrow(XboxTokenResponse.self, data: data, endpoint: "xsts")
    }

    /// MC access token：POST api.minecraftservices.com/authentication/login_with_xbox
    private static func loginWithXbox(identityToken: String) async throws -> (accessToken: String, expiresIn: Int) {
        let payload: [String: Any] = [
            "identityToken": identityToken
        ]
        let (data, response) = try await postJSON(MicrosoftAuthConstants.minecraftLoginURL, json: payload)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.badResponse("非 HTTP 响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MicrosoftAuthError.noMinecraftLicense("HTTP \(http.statusCode) \(body.prefix(120))")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MicrosoftAuthError.unexpectedStatus(endpoint: "login_with_xbox", code: http.statusCode, body: body)
        }
        // `nonisolated` 理由同 `MicrosoftDeviceCode`（nonisolated 服务里 decode）
        nonisolated struct Response: Codable {
            let accessToken: String?
            let expiresIn: Int?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let accessToken = decoded.accessToken else {
            throw MicrosoftAuthError.badResponse("login_with_xbox 响应缺少 access_token")
        }
        return (accessToken, decoded.expiresIn ?? 86400)
    }

    /// MC 档案：GET api.minecraftservices.com/minecraft/profile
    private static func fetchProfile(accessToken: String) async throws -> MinecraftProfile {
        var request = URLRequest(url: MicrosoftAuthConstants.minecraftProfileURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MicrosoftAuthError.badResponse("非 HTTP 响应")
        }
        if http.statusCode == 404 {
            throw MicrosoftAuthError.noMinecraftProfile
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MicrosoftAuthError.unexpectedStatus(endpoint: "minecraft/profile", code: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(MinecraftProfile.self, from: data)
        } catch {
            throw MicrosoftAuthError.badResponse("profile 解析失败: \(error.localizedDescription)")
        }
    }

    /// 从 XSTS 错误体里提取 XErr 错误码（如 `{"XErr":"2148916238"}`）。
    private static func extractXErr(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let xErr = json["XErr"] as? String else {
            return nil
        }
        return xErr
    }

    // MARK: - HTTP 工具（私有）

    private static func postForm(_ url: URL, form: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = form
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        return try await URLSession.shared.data(for: request)
    }

    private static func postJSON(_ url: URL, json: [String: Any]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await URLSession.shared.data(for: request)
    }

    private static func decodeOrThrow<T: Decodable>(_ type: T.Type, data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MicrosoftAuthError.badResponse("\(endpoint) 响应解析失败: \(error.localizedDescription)")
        }
    }
}