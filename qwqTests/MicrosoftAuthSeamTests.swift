//
//  MicrosoftAuthSeamTests.swift
//  qwqTests
//
//  令牌链接缝测试（外部审计 P2-8：「真出错时用户才遇到」的路径补接缝测试）。
//
//  覆盖 `SLCore/Account/MicrosoftAuthService.swift` 的 `completeLogin` 链：
//  MSA 令牌 → XBL → XSTS → MC login → profile。用 `URLProtocol.registerClass`
//  进程级拦截 `URLSession.shared`（Foundation 标准 mock 技术，**不改生产代码**）：
//  - canInit 只接管本测试登记的端点 URL，其余请求照常放行；
//  - 两条路径：XSTS 401 + XErr → 错误映射（审计点名）；全链路成功 → 解析。
//
//  ⚠️ 用例一律 async（工程纪律：同步用例释放 @MainActor 类实例会触发宿主 abort）。
//

import XCTest
@testable import qwq

// MARK: - URLProtocol mock

private final class MockAuthURLProtocol: URLProtocol {

    /// 端点 → (状态码, 响应体) 路由表。测试用例在 setUp 里按需登记。
    nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]
    /// 只拦截已登记 URL 的请求（scheme://host/path 作为 key）
    nonisolated(unsafe) static var allowedPaths: [String] = []
    /// 已到达 mock 的请求快照（URL / method / body）。用于断言**请求形状**本身
    /// （例如「client_id 必须在 POST body 里」这类契约），而不只是响应解析。
    nonisolated(unsafe) static var captured: [(url: String, method: String, body: String)] = []

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        let key = url.absoluteString
        return allowedPaths.contains { key.hasPrefix($0) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 取请求体文本。⚠️ `URLSession` 发出的请求在 `URLProtocol` 里通常**只有
    /// `httpBodyStream`、没有 `httpBody`**（body 被转成流），只读 `httpBody` 会永远得到空串、
    /// 让「body 里有没有 client_id」这类断言假通过 —— 因此这里两条路都走。
    private static func bodyText(of request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.captured.append((url.absoluteString, request.httpMethod ?? "GET", Self.bodyText(of: request)))
        let key = url.absoluteString
        let route = Self.routes.first { key.hasPrefix($0.key) }
        let (status, body) = route?.value ?? (500, "{\"error\":\"unmocked\"}")
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MicrosoftAuthSeamTests: XCTestCase {

    // MARK: - 常量（与生产 MicrosoftAuthConstants 对齐的端点前缀）

    private let xblURL = "https://user.auth.xboxlive.com/user/authenticate"
    private let xstsURL = "https://xsts.auth.xboxlive.com/xsts/authorize"
    private let mcLoginURL = "https://api.minecraftservices.com/authentication/login_with_xbox"
    private let profileURL = "https://api.minecraftservices.com/minecraft/profile"
    private let deviceCodeURL = "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode"

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockAuthURLProtocol.self)
        MockAuthURLProtocol.routes = [:]
        MockAuthURLProtocol.allowedPaths = []
        MockAuthURLProtocol.captured = []
    }

    override func tearDown() {
        MockAuthURLProtocol.routes = [:]
        MockAuthURLProtocol.allowedPaths = []
        MockAuthURLProtocol.captured = []
        URLProtocol.unregisterClass(MockAuthURLProtocol.self)
        super.tearDown()
    }

    // MARK: - 辅助

    /// 登记一批端点路由并启用拦截
    private func stub(_ routes: [String: (Int, String)]) {
        MockAuthURLProtocol.allowedPaths = Array(routes.keys)
        MockAuthURLProtocol.routes = Dictionary(
            uniqueKeysWithValues: routes.map { ($0.key, ($0.value.0, $0.value.1)) }
        )
    }

    private func xblOK() -> (Int, String) {
        (200, #"{"Token":"XBL_TOKEN","DisplayClaims":{"xui":[{"uhs":"UHS_VALUE"}]}}"#)
    }

    private func xstsOK() -> (Int, String) {
        (200, #"{"Token":"XSTS_TOKEN","DisplayClaims":{"xui":[{"uhs":"UHS_VALUE"}]}}"#)
    }

    private func mcLoginOK() -> (Int, String) {
        (200, #"{"access_token":"MC_ACCESS","expires_in":86400}"#)
    }

    private func profileOK() -> (Int, String) {
        (200, #"{"id":"0123456789abcdef0123456789abcdef","name":"Tester"}"#)
    }

    private func deviceCodeOK() -> (Int, String) {
        (200, #"{"device_code":"DEV_CODE","user_code":"ABCD-EFGH","verification_uri":"https://microsoft.com/link","verification_uri_complete":"https://microsoft.com/link?otp=ABCDEFGH","expires_in":900,"interval":5,"message":"请打开网页输入代码"}"#)
    }

    // MARK: - XSTS 拒绝：错误映射（审计点名场景）

    /// XSTS 401 + XErr=2148916238（无 Xbox 账户）→ 必须映射为 .noXboxLiveAccount
    func testXSTS401MapsToNoXboxLiveAccount() async {
        stub([
            xblURL: xblOK(),
            xstsURL: (401, #"{"XErr":"2148916238","Message":"No XBL account"}"#),
        ])

        do {
            _ = try await MicrosoftAuthService.completeLogin(
                msaAccessToken: "msa-token",
                msaRefreshToken: "refresh-token"
            )
            XCTFail("预期抛 MicrosoftAuthError.noXboxLiveAccount，实际成功")
        } catch let error as MicrosoftAuthError {
            guard case .noXboxLiveAccount(let detail) = error else {
                XCTFail("错误映射错误：期望 noXboxLiveAccount，实际 \(error)")
                return
            }
            XCTAssertTrue(detail.contains("2148916238"), "detail 应含 XErr 码，实际 \(detail)")
        } catch {
            XCTFail("期望 MicrosoftAuthError，实际 \(error)")
        }
    }

    /// XSTS 401 但响应体无 XErr → 仍映射 .noXboxLiveAccount（兜底文案）
    func testXSTS401WithoutXErrStillMapsNoXboxLiveAccount() async {
        stub([
            xblURL: xblOK(),
            xstsURL: (401, #"{"Message":"Unauthorized"}"#),
        ])

        do {
            _ = try await MicrosoftAuthService.completeLogin(
                msaAccessToken: "msa-token",
                msaRefreshToken: "refresh-token"
            )
            XCTFail("预期抛错，实际成功")
        } catch let error as MicrosoftAuthError {
            guard case .noXboxLiveAccount = error else {
                XCTFail("期望 noXboxLiveAccount，实际 \(error)")
                return
            }
        } catch {
            XCTFail("期望 MicrosoftAuthError，实际 \(error)")
        }
    }

    // MARK: - 全链路成功

    /// 四端点全部 200 → 成功解析 profile
    func testCompleteLoginSuccessResolvesProfile() async {
        stub([
            xblURL: xblOK(),
            xstsURL: xstsOK(),
            mcLoginURL: mcLoginOK(),
            profileURL: profileOK(),
        ])

        do {
            let (accessToken, profile, expiresIn) = try await MicrosoftAuthService.completeLogin(
                msaAccessToken: "msa-token",
                msaRefreshToken: "refresh-token"
            )
            XCTAssertEqual(accessToken, "MC_ACCESS")
            XCTAssertEqual(profile.id, "0123456789abcdef0123456789abcdef")
            XCTAssertEqual(profile.name, "Tester")
            XCTAssertEqual(expiresIn, 86400)
        } catch {
            XCTFail("全链路应成功，实际 \(error)")
        }
    }

    /// MC login 401/403（无 Minecraft 许可）→ .noMinecraftLicense
    func testMCLogin401MapsToNoMinecraftLicense() async {
        stub([
            xblURL: xblOK(),
            xstsURL: xstsOK(),
            mcLoginURL: (403, #"{"error":"Not entitled"}"#),
        ])

        do {
            _ = try await MicrosoftAuthService.completeLogin(
                msaAccessToken: "msa-token",
                msaRefreshToken: "refresh-token"
            )
            XCTFail("预期抛错，实际成功")
        } catch let error as MicrosoftAuthError {
            guard case .noMinecraftLicense = error else {
                XCTFail("期望 noMinecraftLicense，实际 \(error)")
                return
            }
        } catch {
            XCTFail("期望 MicrosoftAuthError，实际 \(error)")
        }
    }

    /// profile 404 → .noMinecraftProfile
    func testProfile404MapsToNoMinecraftProfile() async {
        stub([
            xblURL: xblOK(),
            xstsURL: xstsOK(),
            mcLoginURL: mcLoginOK(),
            profileURL: (404, "{}"),
        ])

        do {
            _ = try await MicrosoftAuthService.completeLogin(
                msaAccessToken: "msa-token",
                msaRefreshToken: "refresh-token"
            )
            XCTFail("预期抛错，实际成功")
        } catch let error as MicrosoftAuthError {
            guard case .noMinecraftProfile = error else {
                XCTFail("期望 noMinecraftProfile，实际 \(error)")
                return
            }
        } catch {
            XCTFail("期望 MicrosoftAuthError，实际 \(error)")
        }
    }

    // MARK: - 隔离性

    /// 未登记端点 → 500（不会误接真实网络）
    func testUnregisteredEndpointFailsFast() async {
        stub([
            xblURL: xblOK(),
            xstsURL: (500, #"{"error":"unmocked"}"#),
        ])
        do {
            _ = try await MicrosoftAuthService.completeLogin(
                msaAccessToken: "msa-token",
                msaRefreshToken: "refresh-token"
            )
            XCTFail("未 mock 的 XSTS 端点应抛 unexpectedStatus，实际成功")
        } catch let error as MicrosoftAuthError {
            guard case .unexpectedStatus(let endpoint, let code, _) = error else {
                XCTFail("期望 unexpectedStatus，实际 \(error)")
                return
            }
            XCTAssertEqual(endpoint, "xsts")
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("期望 MicrosoftAuthError，实际 \(error)")
        }
    }

    // MARK: - 设备码请求形状（2026-10-05 线上回归：点登录立刻失败）

    /// 设备码请求的参数**必须在 POST body 里**。
    /// 回归背景：此前写成「URL query + 空 body」，MSA 直接回
    /// `AADSTS900144: The request body must contain the following parameter: 'client_id'`，
    /// 表现为点「微软账号登录」立刻失败、连设备码卡片都出不来。
    func testDeviceCodeSendsParamsInBodyNotQuery() async {
        stub([deviceCodeURL: deviceCodeOK()])

        do {
            _ = try await MicrosoftAuthService.startDeviceCode()
        } catch {
            XCTFail("设备码请求不应失败：\(error)")
            return
        }

        guard let request = MockAuthURLProtocol.captured.first(where: { $0.url.hasPrefix(deviceCodeURL) }) else {
            XCTFail("mock 没有收到设备码请求")
            return
        }
        XCTAssertFalse(request.url.contains("?"), "参数不该再放在 query 里：\(request.url)")
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.body.contains("client_id="), "body 缺 client_id：\(request.body)")
        XCTAssertTrue(request.body.contains("scope="), "body 缺 scope：\(request.body)")
    }

    /// 服务端给了 `verification_uri_complete` 时必须能解析出来（用于免手输码地打开浏览器）。
    func testDeviceCodeDecodesPrefilledVerificationURL() async {
        stub([deviceCodeURL: deviceCodeOK()])

        do {
            let code = try await MicrosoftAuthService.startDeviceCode()
            XCTAssertEqual(code.userCode, "ABCD-EFGH")
            XCTAssertEqual(code.verificationURIComplete, "https://microsoft.com/link?otp=ABCDEFGH")
            XCTAssertEqual(code.preferredVerificationURL, "https://microsoft.com/link?otp=ABCDEFGH")
        } catch {
            XCTFail("设备码解析失败：\(error)")
        }
    }

    /// 「设置 → 账号」里填的自定义 client id 要覆盖内置回退值，并出现在请求 body 里。
    func testCustomClientIDOverridesBuiltinFallback() async {
        let key = MicrosoftAuthConstants.clientIDDefaultsKey
        let original = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set("my-own-azure-app-id", forKey: key)
        defer {
            // ⚠️ 必须还原：这个键是**真实的持久化配置**，漏还原会污染同机后续用例与手动运行
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        stub([deviceCodeURL: deviceCodeOK()])
        XCTAssertEqual(MicrosoftAuthService.clientID, "my-own-azure-app-id")

        do {
            _ = try await MicrosoftAuthService.startDeviceCode()
        } catch {
            XCTFail("设备码请求不应失败：\(error)")
            return
        }
        let body = MockAuthURLProtocol.captured.first(where: { $0.url.hasPrefix(deviceCodeURL) })?.body ?? ""
        XCTAssertTrue(body.contains("client_id=my-own-azure-app-id"), "body 未用自定义 id：\(body)")
    }

    /// 应用 id 未注册（AADSTS700016）是**配置问题**，要给可操作提示而不是干巴巴的 HTTP 400。
    func testUnregisteredAppIDMapsToClientIDNotRegistered() async {
        stub([
            deviceCodeURL: (400, #"{"error":"unauthorized_client","error_description":"AADSTS700016: Application with identifier 'x' was not found in the directory"}"#),
        ])

        do {
            _ = try await MicrosoftAuthService.startDeviceCode()
            XCTFail("预期抛 clientIDNotRegistered，实际成功")
        } catch let error as MicrosoftAuthError {
            guard case .clientIDNotRegistered = error else {
                XCTFail("期望 clientIDNotRegistered，实际 \(error)")
                return
            }
            let text = error.errorDescription ?? ""
            XCTAssertTrue(text.contains("设置"), "错误文案应指向「设置 → 账号」：\(text)")
        } catch {
            XCTFail("期望 MicrosoftAuthError，实际 \(error)")
        }
    }
}
