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
    /// 兜底源：GitHub Releases。服务器端响应刻意保持 GitHub 同形（见
    /// update-server/api/latest.php 头注释），同一解析器零改动双吃。
    private static let fallbackReleaseAPI =
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

    /// 拉取最新版本信息（服务器 apple.ct.ws 已由发布流程同步好）。
    /// 找不到 dmg/zip 资产视为「没有可用更新」——发版必须带上打包好的安装包。
    ///
    /// 双源兜底（2026-10-10）：主源自建服务器（国内可达、本地毫秒级返回），
    /// 失败/超时回退 GitHub releases/latest —— 服务器端响应刻意保持 GitHub 同形
    /// （api/latest.php 头注释），同一解析器零改动双吃。依据：免费虚拟主机不保证
    /// 在线（2026-10-10 实测整站空响应），主机挂了更新检查不能跟着全灭。
    /// 主源超时压到 10s：健康的本地返回是毫秒级，挂着 45s 才走兜底等于把
    /// 「检查更新」卡成半分钟。
    static func latestRelease() async -> AppRelease? {
        if let release = await fetchRelease(from: latestReleaseAPI, timeout: 10) {
            return release
        }
        return await fetchRelease(from: fallbackReleaseAPI, timeout: 30)
    }

    private static func fetchRelease(from api: String, timeout: TimeInterval) async -> AppRelease? {
        guard let url = URL(string: api) else { return nil }
        var request = URLRequest(url: url)
        request.setLaunchUserAgent()
        request.timeoutInterval = timeout
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

    /// 每攒多少字节落盘一次并汇报一次进度（64KB）。**它决定进度条的粒度**：
    /// 攒太大（曾用 1MB → 18MB 的包每跳 5.5%）就是「一小段一小段跳」的伪进度条；
    /// 而提示卡按同 id 就地刷新（见 `NoticeCenter.update`），汇报密也不会重建卡片。
    static let reportChunkBytes = 64 * 1024

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
        let http = probeResponse as? HTTPURLResponse
        // ⚠️ 总长必须从 `Content-Range` 解析，**不能**用 `expectedContentLength`：
        // `Range: bytes=0-0` 的 206 响应里后者是**分片长度 1**，把它当资源总长会让
        // `received/total` 每收 1 字节就涨 1 —— 进度回调的 5% 门限形同失效，
        // 于是**每字节发一次通知**，主线程被 SwiftUI 重绘打满，下载表现为
        // 「卡在 0%、update.dmg 一直 0 字节、进程 CPU 100%」（2026-10-10 真机实测）。
        let total = Self.totalSize(fromContentRange: http?.value(forHTTPHeaderField: "Content-Range"))
            ?? probeResponse.expectedContentLength
        let supportsRange: Bool
        if let http {
            // 206 = Range 生效；200 带完整体 = 忽略 Range（须回退单流）
            supportsRange = http.statusCode == 206 && total > 0
        } else {
            supportsRange = false
        }
        if !supportsRange || total <= 0 {
            try await downloadSingle(source, to: destination, knownTotal: total > 0 ? total : nil, progress: progress)
            return
        }

        // ② 分块：<8MB 单连接即可；越大并发越多，但**收敛**（8MB→2 路，16MB→3 路，上限 4 路）。
        //
        // 为什么是「收敛」而不是「越多越快」—— 实测（2026-10-11，18.36MB 的包，同一进程内
        // 交替跑，目标就是那台免费主机 apple.ct.ws）：
        //   第①组：1 路 553 KB/s · 6 路 759 KB/s（≈1.4×）
        //   第②组：1 路 1586/1984 · 2 路 1739/3787 · 3 路 2277/3648 · 6 路 2593/5271 KB/s
        //   更早一次：1 路 1440 KB/s，而 **6 路只有 550 KB/s**（多连接比单连接还慢）
        // 结论：这台主机在**两种状态之间跳** —— 放开时 6 路最快，限速时多连接只是把同一份
        // 带宽切碎、还要多付建连/挑战解算/合并开销。没有单一最优值，故取**永不最差**的折中：
        // 18MB → 3 路（两组里都接近最优，最坏也就是单连接的水平）。
        // 参照 PCL：它对自家服务器/CDN/GitHub 干脆不开多线程（ModNet.vb 里直接 `Return Nothing`）。
        let chunkCount = total < 8 << 20 ? 1
            : total < 16 << 20 ? 2
            : total < 32 << 20 ? 3 : 4
        if chunkCount == 1 {
            try await downloadSingle(source, to: destination, knownTotal: total, progress: progress)
            return
        }

        try await downloadParallel(source, to: destination, total: total, chunkCount: chunkCount, progress: progress)
    }

    /// 从 206 响应的 `Content-Range` 头解析**资源总长**（纯函数，供单测）。
    ///
    /// 形如 `bytes 0-0/13586791` → `13586791`；总长未知时是 `bytes 0-0/*` → `nil`。
    /// 为什么单独成一个函数：这是「进度条会不会每字节发一次通知」的**唯一**判据，
    /// 而它只能靠真机 + 响应头才能验证（见 `download` 里的说明）。
    static func totalSize(fromContentRange header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let tail = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        guard tail != "*", let value = Int64(tail), value > 0 else { return nil }
        return value
    }

    /// 单流下载（不支持 Range / 小文件）：每 `reportChunkBytes` 落盘并汇报一次进度。
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
        buffer.reserveCapacity(Self.reportChunkBytes)
        var received: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            // 每 `reportChunkBytes`（64KB）落盘一次并**按字节里程碑汇报**进度。
            // 不用「涨够 1% 才报」：那在慢速链路上就是「憋一会儿蹦一格」的伪进度条观感。
            // 64KB 对 18MB 的包是 0.35% 一格，即使 1 秒才收到一格，肉眼也是连续爬动。
            if buffer.count >= Self.reportChunkBytes {
                let written = Int64(buffer.count)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                received += written
                if total > 0 {
                    // `min(1,…)` 是**防御**：只要 `total` 被低估（历史上就发生过——见 download 的说明），
                    // 未夹取的 fraction 会一路上涨，逐字节发通知会打满主线程。
                    let fraction = min(1.0, Double(received) / Double(total))
                    if fraction > lastReported {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            let written = Int64(buffer.count)
            try handle.write(contentsOf: buffer)
            received += written
            if total > 0 {
                let fraction = min(1.0, Double(received) / Double(total))
                if fraction > lastReported { progress(fraction) }
            }
        }
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

        // 各分片在自己的任务里累加字节，跨任务读改写由锁保护。
        // 为什么要有它：分块路径此前**只在全部合并完成时回调一次 `progress(1)`**，
        // 13 MB 的包在整个下载期间界面停在 0%（用户实测：以为卡死）。
        let aggregator = DownloadProgressAggregator(total: total, report: progress)

        // ① 并行下载各块到独立文件：各 chunk 独立写，无锁无竞争
        let chunkURLs: [(index: Int, url: URL)] = await withTaskGroup(of: (Int, URL?).self) { group in
            var results = Array<(Int, URL?)>(repeating: (0, nil), count: chunkCount)
            for index in 0..<chunkCount {
                let start = Int64(index) * chunkSize
                let end = min(start + chunkSize, total) - 1
                let chunkFile = workDir.appendingPathComponent(".chunk-\(index)-\(UUID().uuidString)")
                group.addTask {
                    do {
                        try await Self.fetchRange(source, from: start, to: end, to: chunkFile,
                                                  onBytes: { aggregator.add($0) })
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
    /// `onBytes`：每落盘一批就报告增量字节数（供分块下载汇总进度）。
    private static func fetchRange(_ source: URL, from start: Int64, to end: Int64, to chunkFile: URL,
                                   onBytes: (@Sendable (Int64) -> Void)? = nil) async throws {
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
        buffer.reserveCapacity(Self.reportChunkBytes)
        for try await byte in bytes {
            buffer.append(byte)
            // ⚠️ 这里决定进度条的**粒度**，不是写盘性能参数：每汇报一次就推进一次进度，
            // 攒 1MB 才汇报的话，18MB 的包每次跳 ~5.5%，1% 的门限形同虚设
            // —— 用户看到的就是「一小段一小段跳」的伪进度条（2026-10-11 实测反馈）。
            // 64KB 一报：18MB ≈ 280 次汇报，配合 1% 门限与 0.18s 线性动画即连续。
            if buffer.count >= Self.reportChunkBytes {
                let written = Int64(buffer.count)
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                onBytes?(written)
            }
        }
        if !buffer.isEmpty {
            let written = Int64(buffer.count)
            try handle.write(contentsOf: buffer)
            onBytes?(written)
        }
    }

    /// 分块下载的进度汇总：跨任务累加，**按字节里程碑**回调（每个分片每 64KB 调一次 `add`）。
    /// 不用「涨够 1% 才报」—— 那在慢速链路上就是憋一会儿蹦一格的伪进度条观感。
    /// `@unchecked Sendable` 的依据：唯一可变状态是 `received` / `lastReported`，
    /// 两者只在 `NSLock` 内读写；`report` 是 `@Sendable` 闭包。
    private final class DownloadProgressAggregator: @unchecked Sendable {
        private let lock = NSLock()
        private var received: Int64 = 0
        private var lastReported = 0.0
        private let total: Int64
        private let report: @Sendable (Double) -> Void

        init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
            self.total = max(1, total)
            self.report = report
        }

        func add(_ delta: Int64) {
            lock.lock()
            received += delta
            let fraction = min(1.0, Double(received) / Double(total))
            let advanced = fraction > lastReported          // 值没变就不必回报（防重复/防请求风暴）
            if advanced { lastReported = fraction }
            lock.unlock()
            if advanced { report(fraction) }
        }
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
