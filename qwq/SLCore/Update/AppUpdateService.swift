//
//  AppUpdateService.swift
//  SL 启动器的自动更新基础设施（GitHub Releases）。
//
//  仓库公开（asdfasdfasdfasdfasdf111/SL），Releases API 匿名可读：检查更新 =
//  GET releases/latest 取 tag_name 与 zip 资产，版本比较为纯数值逐段比较。
//  本文件只做「取数与判 version」；下载后的解包/换装/重启由
//  Features/Update/AppUpdateCoordinator 编排（不在这里触碰应用生命周期）。
//

import Foundation

nonisolated enum AppUpdateService {

    /// 仓库公开是整条自动更新链路的前提：匿名才能读到 Releases 与资产下载地址
    private static let latestReleaseAPI =
        "https://api.github.com/repos/asdfasdfasdfasdfasdf111/SL/releases/latest"

    struct AppRelease: Sendable {
        let tagName: String
        let notes: String
        let downloadURL: URL
    }

    /// 当前 App 版本（CFBundleShortVersionString）。
    /// `SL_FORCE_VERSION` 仅用于更新链路的开发验证：设置后顶替真实版本号，
    /// 让本机「旧版本」对上一个线上 Release，走完整提示/下载/换装流程
    /// （与 SnapshotHarness 同一约定：仅环境变量触发，产品功能不依赖它）。
    static func currentVersion() -> String {
        if let forced = ProcessInfo.processInfo.environment["SL_FORCE_VERSION"], !forced.isEmpty {
            return forced
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 版本比较：剥掉可选的 v 前缀后逐段数值比较（"v1.10.0" > "v1.9.9"），
    /// 段数不齐按 0 补齐（"1.6" == "1.6.0"）。相等返回 false（不算新版本）。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = numericComponents(candidate)
        let currentParts = numericComponents(current)
        let width = max(candidateParts.count, currentParts.count)
        for index in 0..<width {
            let c = index < candidateParts.count ? candidateParts[index] : 0
            let cur = index < currentParts.count ? currentParts[index] : 0
            if c != cur { return c > cur }
        }
        return false
    }

    private static func numericComponents(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.split(separator: ".").map { component in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
    }

    /// 拉取最新 Release（预发布不参与：`releases/latest` 本身只回正式版）。
    /// 找不到 zip 资产视为「没有可用更新」——发版必须带上打包好的 zip。
    static func latestRelease() async -> AppRelease? {
        guard let url = URL(string: latestReleaseAPI) else { return nil }
        var request = URLRequest(url: url)
        request.setLaunchUserAgent()
        request.timeoutInterval = 15
        guard let (data, _) = try? await AppContext.shared.apiSession.data(for: request) else { return nil }
        return parseLatestRelease(data)
    }

    /// 解析 releases/latest 的响应（纯函数，供单测）：取 tag_name、说明正文与首个 zip 资产。
    static func parseLatestRelease(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zipURL = assets.compactMap { asset -> URL? in
            guard let name = asset["name"] as? String, name.hasSuffix(".zip"),
                  let urlString = asset["browser_download_url"] as? String else { return nil }
            return URL(string: urlString)
        }.first
        guard let downloadURL = zipURL else { return nil }
        return AppRelease(tagName: tagName,
                          notes: (json["body"] as? String) ?? "",
                          downloadURL: downloadURL)
    }

    /// 流式下载（缓冲写盘），每 ≥5% 回调一次进度。
    static func download(_ source: URL,
                         to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: source)
        request.setLaunchUserAgent()
        request.timeoutInterval = 60
        let (bytes, response) = try await AppContext.shared.apiSession.bytes(for: request)
        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if total > 0 {
                let fraction = Double(received) / Double(total)
                if fraction - lastReported >= 0.05 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }
}
