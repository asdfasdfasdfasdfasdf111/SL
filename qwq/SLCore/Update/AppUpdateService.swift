//
//  AppUpdateService.swift
//  SL 启动器的自动更新基础设施（更新服务器 apple.ct.ws）。
//
//  检查更新 = GET https://apple.ct.ws/api/latest.php，服务器端由 GitHub Actions
//  （发布 release 时自动触发 publish.php）同步最新版本与 dmg 安装包；本端点返回
//  GitHub releases/latest 同形的 JSON：tag_name 供版本比较，dmg（zip 兜底）资产
//  供下载换装。本文件只做「取数、判版本、下载」；解包/换装/重启由
//  Features/Update/AppUpdateCoordinator 编排（不在这里触碰应用生命周期）。
//  服务器对所有请求下发 slowAES 挑战页，所有请求须先过
//  ChallengeResolver.attachChallengeCookie（见 ChallengeResolver.swift）。
//

import Foundation

nonisolated enum AppUpdateService {

    /// 更新服务器检查端点：服务器端由发布流程（GitHub Actions → publish.php）保持
    /// 最新，App 检查时读到的是已就位的最新版本与安装包（本地 URL → 快速下载）。
    private static let latestReleaseAPI =
        "https://apple.ct.ws/api/latest.php"

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

    /// 拉取最新版本信息（服务器 apple.ct.ws 已由发布流程同步好）。
    /// 找不到 dmg/zip 资产视为「没有可用更新」——发版必须带上打包好的安装包。
    static func latestRelease() async -> AppRelease? {
        guard let url = URL(string: latestReleaseAPI) else { return nil }
        var request = URLRequest(url: url)
        request.setLaunchUserAgent()
        request.timeoutInterval = 45   // 干净网络下秒回；兜底给足时间，失败由调用方提示
        do {
            try await request.attachChallengeCookie()
            let (data, _) = try await AppContext.shared.apiSession.data(for: request)
            return parseLatestRelease(data)
        } catch {
            return nil
        }
    }

    /// 解析 releases/latest 的响应（纯函数，供单测）：取 tag_name、说明正文与安装包资产。
    /// dmg 优先（.app 分发首选：保留权限/符号链接/代码签名），zip 回退。
    static func parseLatestRelease(_ data: Data) -> AppRelease? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let packageURL = assets.compactMap { asset -> URL? in
            guard let name = asset["name"] as? String,
                  name.hasSuffix(".dmg") || name.hasSuffix(".zip"),
                  let urlString = asset["browser_download_url"] as? String else { return nil }
            return URL(string: urlString)
        }.first
        guard let downloadURL = packageURL else { return nil }
        return AppRelease(tagName: tagName,
                          notes: (json["body"] as? String) ?? "",
                          downloadURL: downloadURL)
    }

    /// 多线程 Range 分块下载：先取 Content-Length 与 Accept-Ranges，若服务器支持
    /// Range 就并发拉取若干分段再按偏移拼装（免费静态主机下载慢，多连接可成倍提速）；
    /// 不支持 Range（返回整份 200）则退化为单流下载。每 ≥5% 回调一次进度。
    static func download(_ source: URL,
                         to destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        // ① 探测：GET 首段，拿到总大小 + 是否支持 Range
        var probe = URLRequest(url: source)
        probe.setLaunchUserAgent()
        probe.timeoutInterval = 30
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        try await probe.attachChallengeCookie()
        let (_, probeResponse) = try await URLSession.direct.data(for: probe)
        let total = probeResponse.expectedContentLength
        let supportsRange: Bool
        if let http = probeResponse as? HTTPURLResponse {
            // 206 = Range 生效；200 带完整体 = 忽略 Range（须回退单流）
            supportsRange = http.statusCode == 206 && total > 0
        } else {
            supportsRange = false
        }
        if !supportsRange || total <= 0 {
            try await downloadSingle(source, to: destination, knownTotal: total > 0 ? total : nil, progress: progress)
            return
        }

        // ② 分块：<8MB 单线程即可；越大并发越多（8MB→4 路，16MB→6 路，上限 8 路）
        let chunkCount = total < 8 << 20 ? 1
            : total < 16 << 20 ? 4
            : total < 32 << 20 ? 6 : 8
        if chunkCount == 1 {
            try await downloadSingle(source, to: destination, knownTotal: total, progress: progress)
            return
        }

        try await downloadParallel(source, to: destination, total: total, chunkCount: chunkCount, progress: progress)
    }

    /// 单流下载（不支持 Range / 小文件）：缓冲写盘，每 ≥5% 回调进度。
    private static func downloadSingle(_ source: URL,
                                       to destination: URL,
                                       knownTotal: Int64?,
                                       progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: source)
        request.setLaunchUserAgent()
        request.timeoutInterval = 120
        try await request.attachChallengeCookie()
        let (bytes, response) = try await URLSession.direct.bytes(for: request)
        let total = knownTotal ?? response.expectedContentLength
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
        progress(1)
    }

    /// 并发 Range 分块下载：每块一个独立请求、写独立临时文件（无共享可变状态，
    /// 天然满足 Swift 并发检查），全部完成后按序合并，最后校验总量。
    private static func downloadParallel(_ source: URL,
                                         to destination: URL,
                                         total: Int64,
                                         chunkCount: Int,
                                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let workDir = destination.deletingLastPathComponent()
        let chunkSize = (total + Int64(chunkCount) - 1) / Int64(chunkCount)

        // ① 并行下载各块到独立文件：各 chunk 独立写，无锁无竞争
        let chunkURLs: [(index: Int, url: URL)] = await withTaskGroup(of: (Int, URL?).self) { group in
            var results = Array<(Int, URL?)>(repeating: (0, nil), count: chunkCount)
            for index in 0..<chunkCount {
                let start = Int64(index) * chunkSize
                let end = min(start + chunkSize, total) - 1
                let chunkFile = workDir.appendingPathComponent(".chunk-\(index)-\(UUID().uuidString)")
                group.addTask {
                    do {
                        try await Self.fetchRange(source, from: start, to: end, to: chunkFile)
                        return (index, chunkFile)
                    } catch {
                        try? FileManager.default.removeItem(at: chunkFile)
                        return (index, nil)
                    }
                }
            }
            for await (index, url) in group {
                results[index] = (index, url)
            }
            var collected: [(index: Int, url: URL)] = []
            for (index, url) in results {
                if let url { collected.append((index, url)) }
            }
            return collected
        }

        // ② 任一失败 → 清理并抛错
        guard chunkURLs.count == chunkCount else {
            for item in chunkURLs { try? FileManager.default.removeItem(at: item.url) }
            throw UpdateDownloadError.rangeRejected
        }

        // ③ 按序合并到目标文件（按分块 index 排序）
        defer { for item in chunkURLs { try? FileManager.default.removeItem(at: item.url) } }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var merged: Int64 = 0
        for item in chunkURLs.sorted(by: { $0.index < $1.index }) {
            let data = try Data(contentsOf: item.url)
            try out.write(contentsOf: data)
            merged += Int64(data.count)
        }

        // ④ 总量校验：防止服务器返回字节数不符（如某 Range 被截断）
        guard merged == total else {
            throw UpdateDownloadError.sizeMismatch(expected: total, actual: merged)
        }
        progress(1)
    }

    /// 拉取 [start, end] 区间流式写入文件，自动跟随重定向。
    private static func fetchRange(_ source: URL, from start: Int64, to end: Int64, to chunkFile: URL) async throws {
        var request = URLRequest(url: source)
        request.setLaunchUserAgent()
        request.timeoutInterval = 120
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        try await request.attachChallengeCookie()
        let (bytes, response) = try await URLSession.direct.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw UpdateDownloadError.rangeRejected
        }
        FileManager.default.createFile(atPath: chunkFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: chunkFile)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }

    private enum UpdateDownloadError: LocalizedError {
        case rangeRejected
        case sizeMismatch(expected: Int64, actual: Int64)

        var errorDescription: String? {
            switch self {
            case .rangeRejected: return "服务器未按 Range 响应分段请求"
            case .sizeMismatch(let expected, let actual):
                return "下载校验失败：期望 \(expected) 字节，实际 \(actual) 字节"
            }
        }
    }
}
