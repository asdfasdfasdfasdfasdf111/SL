//
//  ChallengeResolver.swift
//  SL 启动器的更新服务器挑战解算器（slowAES）。
//
//  apple.ct.ws（InfinityFree 免费档）对**所有**请求先发一段 JS 挑战页：
// 页面里带三个 16 字节 hex（a=key, b=iv, c=密文），要求浏览器执行
// slowAES.decrypt(c, 2, a, b)（AES-128-CBC、**无 padding**）算出 16 字节答案，
// 写进 cookie `__test` 后带 cookie 重访。
// URLSession 不执行 JS，所以必须在本进程用 CommonCrypto 解出同一答案，
// 缓存 6 小时（与页面 max-age 一致），之后所有请求带上 __test。
//
// 挑战页特征：响应体里有 `toNumbers(`；用这个特征判定「被挑战」，
// 避免把正常 JSON 误判。换主机后响应无挑战页 → 返回空 cookie，调用方照常请求。
//

import CommonCrypto
import Foundation

/// 更新服务器挑战的解算与缓存。线程安全；解算过一次后同一 host 直接命中。
enum ChallengeResolver {

    private static let lock = NSLock()
    private static var cache: [String: (value: String, fetchedAt: Date)] = [:]
    private static var inflight: [String: Task<String, Error>] = [:]

    /// 取某 host 的 `__test` cookie 值（不含头与分号）。失败抛错。
    static func cookieValue(for host: String) async throws -> String {
        let now = Date()
        if let cached = readCache(host: host, now: now) { return cached }
        return try await resolveAndCache(host: host, now: now)
    }

    // MARK: - 缓存

    private static func readCache(host: String, now: Date) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[host] else { return nil }
        guard now.timeIntervalSince(entry.fetchedAt) < 6 * 3600 else {
            cache[host] = nil
            return nil
        }
        return entry.value
    }

    private static func writeCache(host: String, value: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        cache[host] = (value, now)
    }

    // MARK: - 解算（单飞：并发请求共享同一次解算）

    private static func resolveAndCache(host: String, now: Date) async throws -> String {
        if let existing = inflight[host] {
            return try await existing.value
        }
        let task = Task<String, Error> {
            let value = try await performSolve(host: host)
            writeCache(host: host, value: value, now: Date())
            return value
        }
        inflight[host] = task
        defer { inflight[host] = nil }
        return try await task.value
    }

    // MARK: - 实际解算

    private static func performSolve(host: String) async throws -> String {
        let url = URL(string: "https://\(host)/")!
        var request = URLRequest(url: url)
        request.setLaunchUserAgent()
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.direct.data(for: request)
        guard let text = String(data: data, encoding: .utf8),
              text.contains("toNumbers(") else {
            return ""   // 服务器无挑战（换主机等），调用方按无 cookie 请求即可
        }
        func extract(_ label: String) -> String? {
            guard let range = text.range(of: label + "=toNumbers(\"") else { return nil }
            let rest = text[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let hex = String(rest[..<end])
            return hex.count == 32 ? hex : nil
        }
        guard let a = extract("a"), let b = extract("b"), let c = extract("c") else {
            throw ChallengeError.badPage
        }
        let key = Data(hex: a)
        let iv = Data(hex: b)
        let cipher = Data(hex: c)
        guard key.count == 16, iv.count == 16, cipher.count == 16 else {
            throw ChallengeError.badPage
        }
        let decrypted = try aes128CBCNoPadding(cipher, key: key, iv: iv)
        return decrypted.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-128-CBC **无 padding** 解密（等价 slowAES.decrypt(c, 2, a, b) =
    /// openssl enc -d -aes-128-cbc -nopad；页面给的就是 16 字节整块）。
    private static func aes128CBCNoPadding(_ data: Data, key: Data, iv: Data) throws -> Data {
        // 拷贝副本：避免 withUnsafeBytes 与 out 的排他访问冲突（Swift 6 报
        // "overlapping accesses to 'out'"——闭包内又读了 out.count）。
        let dataCopy = Data(data)
        let keyCopy = Data(key)
        let ivCopy = Data(iv)
        let cap = dataCopy.count + kCCBlockSizeAES128
        var out = Data(count: cap)
        var outLen = 0
        let status: CCStatus = dataCopy.withUnsafeBytes { dataPtr in
            keyCopy.withUnsafeBytes { keyPtr in
                ivCopy.withUnsafeBytes { ivPtr in
                    out.withUnsafeMutableBytes { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),                 // 无 padding
                            keyPtr.baseAddress, keyCopy.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, dataCopy.count,
                            outPtr.baseAddress, cap,
                            &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ChallengeError.decryptFailed }
        return out.prefix(outLen)
    }

    private enum ChallengeError: LocalizedError {
        case badPage
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .badPage: return "挑战页解析失败"
            case .decryptFailed: return "挑战解密失败"
            }
        }
    }
}

private extension Data {
    /// 32 位 hex 字符串 → 16 字节数据。
    init(hex: String) {
        var out = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let end = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[idx..<end], radix: 16) {
                out.append(byte)
            }
            idx = end
        }
        self = out
    }
}

extension URLRequest {
    /// 给请求附上更新服务器的挑战 cookie（__test）。
    /// InfinityFree 免费档对所有请求先发 slowAES 挑战页，URLSession 不能执行 JS，
    /// 必须在请求前用 ChallengeResolver 解出答案、带上 cookie 才能拿到真实内容。
    /// 调用点：AppUpdateService 的检查更新与下载（probe / 单流 / 分块）请求。
    mutating func attachChallengeCookie() async throws {
        guard let host = url?.host, !host.isEmpty else { return }
        let cookie = try await ChallengeResolver.cookieValue(for: host)
        guard !cookie.isEmpty else { return }   // 服务器无挑战（换主机等），照常请求
        setValue("__test=\(cookie)", forHTTPHeaderField: "Cookie")
    }
}