//
//  NetDownloader.swift
//  PCL.Mac
//
//  对标 PCL2 (ModNet.vb) 移植的多线程分片下载引擎：
//  - FileChecker 四合一校验（ActualSize / MinSize / Hash(自动判 MD5·SHA1·SHA256) / IsJson）
//  - NetManager 全局调度（40ms tick、全局分片上限、速度触发、慢速检测）
//  - 分片下载：Range 请求、失败断点续传、最大碎片尾部 40% 处分割、自适应超时
//  - 多源顺序失败切换 + 源黑名单（不支持断点续传的源只准单线程）
//  - 按序 Merge 拼接 .tmp 分片 + 下载后四合一校验
//

import Foundation
import CryptoKit

// MARK: - FileChecker（PCL2 ModBase.vb FileChecker 移植）

public struct FileChecker {
    public var actualSize: Int64 = -1
    public var minSize: Int64 = -1
    public var hash: String? = nil
    public var canUseExistsFile: Bool = true
    public var isJson: Bool = false

    public init(actualSize: Int64 = -1, minSize: Int64 = -1, hash: String? = nil, canUseExistsFile: Bool = true, isJson: Bool = false) {
        self.actualSize = actualSize
        self.minSize = minSize
        self.hash = hash
        self.canUseExistsFile = canUseExistsFile
        self.isJson = isJson
    }

    /// 检查文件。通过返回 nil，失败返回错误描述文本。
    public nonisolated func check(_ path: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return "文件不存在：\(path.lastPathComponent)"
        }
        if actualSize >= 0, actualSize != size {
            return "文件大小应为 \(actualSize) B，实际为 \(size) B"
        }
        if minSize >= 0, minSize > size {
            return "文件大小应大于 \(minSize) B，实际为 \(size) B"
        }
        if let hash, !hash.isEmpty {
            let actual: String
            if hash.count < 35 {
                actual = Self.md5OfFile(path) ?? ""
            } else if hash.count == 64 {
                actual = Self.sha256OfFile(path) ?? ""
            } else {
                actual = Self.sha1OfFile(path) ?? ""
            }
            guard actual.lowercased() == hash.lowercased() else {
                return "文件哈希校验失败：期望 \(hash)，实际 \(actual)"
            }
        }
        if isJson {
            guard let data = try? Data(contentsOf: path), !data.isEmpty else {
                return "读取到的文件为空"
            }
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return "不是有效的 json 文件"
            }
        }
        return nil
    }

    private nonisolated static func md5OfFile(_ path: URL) -> String? {
        var hasher = Insecure.MD5()
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func sha256OfFile(_ path: URL) -> String? {
        var hasher = SHA256()
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func sha1OfFile(_ path: URL) -> String? {
        var hasher = Insecure.SHA1()
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 下载文件描述（PCL2 NetFile 移植）

public final class PCLNetFile {
    public let urls: [URL]
    public let destination: URL
    public let checker: FileChecker?
    public let replaceMethod: ReplaceMethod

    public init(urls: [URL], destination: URL, checker: FileChecker? = nil, replaceMethod: ReplaceMethod = .skip) {
        self.urls = urls
        self.destination = destination
        self.checker = checker
        self.replaceMethod = replaceMethod
    }
}

public enum NetDownloadError: LocalizedError {
    case fileExists(String)
    case noAvailableSource(String)
    case sourceNoResumeSupport
    case slowSpeed
    case fileFailed(String)
    case mergeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileExists(let name):
            return "\(name) 已存在。"
        case .noAvailableSource(let name):
            return "\(name)：无可用下载源。"
        case .sourceNoResumeSupport:
            return "下载源不支持断点续传。"
        case .slowSpeed:
            return "由于速度过慢断开链接。"
        case .fileFailed(let reason):
            return "下载失败：\(reason)"
        case .mergeFailed(let reason):
            return "合并文件失败：\(reason)"
        }
    }
}

// MARK: - NetManager 全局调度器（PCL2 NetManagerClass 移植）

public actor NetManager {
    public static let shared = NetManager()

    public struct Config {
        public var maxSlices: Int = 16                       // 全局分片上限（NetTaskThreadLimit）
        public var pieceLimit: Int64 = 1024 * 1024           // 最小分割粒度（FilePieceLimit）：1MB 起才值得再开一片
        public var minMultiSliceSize: Int64 = 4 * 1024 * 1024 // 仅大于此大小的文件允许多分片：
                                                             // 海量小文件（MC 库文件多为几十 KB~几 MB）单线程直下，
                                                             // 避免抢占分片池导致大文件并发不足（整体吞吐反而更高）
        public var speedLimitLow: Int64 = 1024 * 1024        // 速度下限（NetTaskSpeedLimitLow）
        public var maxFailPerSource: Int = 3                 // 单源连续失败次数阈值
        public var tickIntervalNs: UInt64 = 40_000_000       // 调度周期 40ms
        public init() {}
    }
    public var config = Config()

    // MARK: 内部状态

    private enum SliceState {
        case downloading   // 运行中
        case resumed       // 运行中（断点续传）
        case done          // 已完成
        case failed        // 失败（保留部分数据，可续传）
    }

    private final class Slice {
        let id = UUID()
        let start: Int64
        var done: Int64 = 0
        var sourceIndex: Int
        var state: SliceState = .downloading
        var tempURL: URL?

        init(start: Int64, sourceIndex: Int) {
            self.start = start
            self.sourceIndex = sourceIndex
        }

        /// 本片结束位置 = 下一片起点 - 1；最后一片 = 文件大小 - 1（PCL2 DownloadEnd）
        func end(of record: FileRecord) -> Int64 {
            let sorted = record.slices.sorted { $0.start < $1.start }
            guard let idx = sorted.firstIndex(where: { $0.id == id }) else { return record.fileSize - 1 }
            if idx + 1 < sorted.count { return sorted[idx + 1].start - 1 }
            return record.fileSize - 1
        }

        /// 剩余字节 = End + 1 - (Start + Done)（PCL2 DownloadUndone）
        func undone(of record: FileRecord) -> Int64 {
            if record.fileSize == -1 { return -1 } // 未知大小：不限
            return max(0, end(of: record) + 1 - (start + done))
        }
    }

    private enum FileState {
        case waiting, loading, merging, done, failed
    }

    private final class FileRecord {
        let id = UUID()
        let file: PCLNetFile
        var fileSize: Int64 = -2        // -2 未获取；-1 未知；>0 已知
        var state: FileState = .waiting
        var slices: [Slice] = []
        var sliceTasks: [UUID: Task<Void, Never>] = [:]
        var sourcesOnce: Set<Int> = []  // 不支持断点续传的源
        var sourceFails: [Int: Int] = [:]
        var failCount = 0
        var failReason = ""
        var progressHandler: ((Double) -> Void)?
        var completion: (() -> Void)?

        init(_ file: PCLNetFile) {
            self.file = file
        }

        var isTerminal: Bool { state == .done || state == .failed }
        var activeSliceCount: Int { slices.filter { $0.state == .downloading || $0.state == .resumed }.count }

        func slice(_ id: UUID) -> Slice? {
            slices.first { $0.id == id }
        }

        var progressValue: Double {
            if state == .done { return 1 }
            if fileSize <= 0 { return 0 }
            let done = slices.reduce(Int64(0)) { $0 + $1.done }
            return min(1, Double(done) / Double(fileSize))
        }

        func isAllSourcesFailed(_ maxFail: Int) -> Bool {
            for i in 0..<file.urls.count {
                if !sourcesOnce.contains(i) && sourceFails[i, default: 0] < maxFail { return false }
            }
            return true
        }
    }

    private var records: [FileRecord] = []
    private var activeSlices = 0
    private var tickTask: Task<Void, Never>?
    private var tickCount = 0
    private var totalBytes: Int64 = 0
    private var lastTotalBytes: Int64 = 0
    private var lastSpeedTime = Date()
    private var recentSpeed: Double = 0

    private init() {
        // 分片文件统一写入应用缓存目录；首次运行该目录不存在时 createFile 会直接失败。
        try? FileManager.default.createDirectory(
            at: SharedConstants.shared.temperatureURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - 公开 API

    /// 下载单个文件（对标 PCL2 NetFile + LoaderDownload 单任务）
    public func download(_ file: PCLNetFile, progress: ((Double) -> Void)? = nil) async throws {
        let record = FileRecord(file)
        if let progress {
            record.progressHandler = { p in
                Task { @MainActor in progress(p) }
            }
        }
        switch precheck(record) {
        case .skip:
            await MainActor.run { progress?(1.0) }
            return
        case .throwError(let error):
            throw error
        case .download:
            break
        }
        records.append(record)
        startTickerIfNeeded()
        do {
            try await waitForCompletion([record.id])
        } catch {
            cancelRecords([record.id])
            records.removeAll { $0.id == record.id }
            throw error
        }
        records.removeAll { $0.id == record.id }
        if record.state == .failed {
            throw NetDownloadError.fileFailed(record.failReason)
        }
        await MainActor.run { progress?(1.0) }
    }

    /// 批量下载多个文件（对标 PCL2 LoaderDownload 多文件 + StartCopy 存在检查）
    public func downloadAll(
        _ files: [PCLNetFile],
        overallProgress: ((Double, Int) -> Void)? = nil,
        onFileCompleted: (() -> Void)? = nil
    ) async throws {
        var pending: [UUID] = []
        for file in files {
            let record = FileRecord(file)
            record.completion = onFileCompleted
            switch precheck(record) {
            case .skip:
                onFileCompleted?()
            case .throwError(let error):
                throw error
            case .download:
                records.append(record)
                pending.append(record.id)
            }
        }
        if pending.isEmpty {
            // skip 分支已经逐项回调完成计数；这里只补发批次进度，避免重复扣减。
            await MainActor.run { overallProgress?(1.0, files.count) }
            return
        }
        startTickerIfNeeded()

        let ids = pending
        let progressTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let (p, count) = await self.overallProgressValue(for: ids)
                await MainActor.run { overallProgress?(p, count) }
            }
        }
        defer {
            progressTask.cancel()
            cancelRecords(pending)
            records.removeAll { pending.contains($0.id) }
        }

        try await waitForCompletion(pending)
    }

    /// 取消仍在运行的分片任务并清理临时文件（失败/取消时避免孤儿任务）
    private func cancelRecords(_ ids: [UUID]) {
        for id in ids {
            guard let record = find(id) else { continue }
            for (_, task) in record.sliceTasks {
                task.cancel()
            }
            record.sliceTasks.removeAll()
            cleanupTemps(record)
        }
    }

    // MARK: - 预检（PCL2 FileChecker.CanUseExistsFile + ReplaceMethod 语义）

    private enum PrecheckResult {
        case skip, download, throwError(Error)
    }

    private func precheck(_ record: FileRecord) -> PrecheckResult {
        guard FileManager.default.fileExists(atPath: record.file.destination.path) else { return .download }
        switch record.file.replaceMethod {
        case .throw:
            return .throwError(NetDownloadError.fileExists(record.file.destination.lastPathComponent))
        case .replace:
            return .download
        case .skip:
            if let checker = record.file.checker, checker.canUseExistsFile {
                if checker.check(record.file.destination) == nil {
                    return .skip
                }
                // 存在但校验不过（如哈希不匹配）→ 删除重下
                try? FileManager.default.removeItem(at: record.file.destination)
                return .download
            }
            // 无校验要求：存在即跳过（PCL2 FileChecker.CanUseExistsFile 默认 true；无 checker 视为通过）
            return .skip
        }
    }

    // MARK: - 调度循环（PCL2 StartManager，40ms tick）

    private func startTickerIfNeeded() {
        guard tickTask == nil else { return }
        tickTask = Task.detached(priority: .utility) {
            let interval = await self.config.tickIntervalNs
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await self.tickOnce()
                let active = await self.hasActiveWork()
                if !active { break }
            }
            await self.tickerStopped()
        }
    }

    private func tickerStopped() {
        tickTask = nil
    }

    private func hasActiveWork() -> Bool {
        records.contains { $0.state == .waiting || $0.state == .loading || $0.state == .merging }
    }

    private func tickOnce() async {
        tickCount += 1
        if tickCount % 5 == 0 { reportProgress() }

        // 速度统计
        let now = Date()
        let dt = now.timeIntervalSince(lastSpeedTime)
        if dt >= 1 {
            recentSpeed = Double(totalBytes - lastTotalBytes) / dt
            lastTotalBytes = totalBytes
            lastSpeedTime = now
        }

        // 触发条件：速度低于下限，或存在等待中的文件，或存在待续传的失败分片（PCL2 Speed < NetTaskSpeedLimitLow OrElse FileRemain > NetTaskThreadLimit）
        let hasFailedSlice = records.contains { record in
            record.slices.contains { $0.state == .failed && $0.undone(of: record) > 0 }
        }
        let needMore = recentSpeed < Double(config.speedLimitLow)
            || records.contains { $0.state == .waiting }
            || hasFailedSlice
        guard needMore else { return }

        var budget = max(0, config.maxSlices - activeSlices)
        guard budget > 0 else { return }

        // 优先给等待中的文件开首线程，再给下载中的文件分割（PCL2 FilesWaiting → FilesLoading）
        for record in records where record.state == .waiting {
            guard budget > 0 else { break }
            if tryBeginSlice(record) {
                budget -= 1
                try? await Task.sleep(nanoseconds: config.tickIntervalNs)
            }
        }
        for record in records where record.state == .loading {
            guard budget > 0 else { break }
            if tryBeginSlice(record) {
                budget -= 1
                try? await Task.sleep(nanoseconds: config.tickIntervalNs)
            }
        }
    }

    private func reportProgress() {
        for record in records where record.progressHandler != nil && !record.isTerminal {
            let p = record.progressValue
            let handler = record.progressHandler!
            Task { @MainActor in handler(p) }
        }
    }

    private func overallProgressValue(for ids: [UUID]) -> (Double, Int) {
        var totalSize: Int64 = 0
        var doneSize: Int64 = 0
        var doneCount = 0
        for id in ids {
            guard let r = find(id) else { continue }
            if r.state == .done {
                doneCount += 1
                continue
            }
            if r.fileSize > 0 {
                totalSize += r.fileSize
                doneSize += r.slices.reduce(Int64(0)) { $0 + $1.done }
            }
        }
        let p = totalSize > 0 ? Double(doneSize) / Double(totalSize) : 0
        return (p, doneCount)
    }

    // MARK: - 分片分配（PCL2 TryBeginThread）

    private func tryBeginSlice(_ record: FileRecord) -> Bool {
        guard activeSlices < config.maxSlices else { return false }
        guard let sourceIndex = pickSource(record) else { return false }

        // ① 首线程（起点 0）
        if record.slices.isEmpty {
            record.state = .loading
            let slice = Slice(start: 0, sourceIndex: sourceIndex)
            record.slices.append(slice)
            startSliceTask(record, slice)
            return true
        }

        // 首线程失败且未取到文件大小（无有效数据）→ 重建首线程
        if record.fileSize == -2 {
            record.slices.removeAll { $0.state == .failed && $0.done == 0 }
            if record.slices.isEmpty {
                let slice = Slice(start: 0, sourceIndex: sourceIndex)
                record.slices.append(slice)
                startSliceTask(record, slice)
                return true
            }
        }

        // ② 失败分片断点续传（PCL2：从 DownloadStart + DownloadDone 继续）
        if let failed = record.slices.first(where: { $0.state == .failed && $0.undone(of: record) > 0 }) {
            let slice = Slice(start: failed.start + failed.done, sourceIndex: sourceIndex)
            slice.state = .resumed
            // 旧失败分片保留其已下数据（merge 时拼接），其 undone 因新分片插入自动归零
            record.slices.append(slice)
            record.slices.sort { $0.start < $1.start }
            startSliceTask(record, slice)
            return true
        }

        // ③ 禁多线程源（PCL2：pcl2-server / gitcode / github 仅单线程）
        let target = record.file.urls[sourceIndex].absoluteString
        if target.contains("pcl2-server") || target.contains("gitcode.net") || target.contains("github.com") {
            return false
        }

        // ④ 分割最大碎片：尾部 40% 处切开（PCL2：End - Undone * 0.4）
        //    仅对 >4MB 的大文件分割：MC 版本的库文件数以千计且普遍偏小，
        //    小文件多分片只会加剧连接池争抢，把分片让给真正的大文件收益更高。
        guard record.fileSize >= config.minMultiSliceSize else { return false }
        let candidates = record.slices.filter { $0.state == .downloading || $0.state == .resumed }
        guard let maxSlice = candidates.max(by: { $0.undone(of: record) < $1.undone(of: record) }),
              maxSlice.undone(of: record) >= config.pieceLimit else { return false }
        let cut = maxSlice.end(of: record) - Int64(Double(maxSlice.undone(of: record)) * 0.4)
        if cut <= maxSlice.start { return false }
        let slice = Slice(start: cut, sourceIndex: sourceIndex)
        record.slices.append(slice)
        record.slices.sort { $0.start < $1.start }
        startSliceTask(record, slice)
        return true
    }

    /// 选择可用源：按顺序跳过黑名单（不支持断点续传）与失败超阈值的源
    private func pickSource(_ record: FileRecord) -> Int? {
        for i in 0..<record.file.urls.count {
            if record.sourcesOnce.contains(i) { continue }
            if record.sourceFails[i, default: 0] >= config.maxFailPerSource { continue }
            return i
        }
        record.state = .failed
        record.failReason = "所有下载源均不可用"
        return nil
    }

    // MARK: - 分片执行（PCL2 NetThread）

    private func startSliceTask(_ record: FileRecord, _ slice: Slice) {
        activeSlices += 1
        let fileID = record.id
        let sliceID = slice.id
        let sourceIndex = slice.sourceIndex
        let urls = record.file.urls
        let start = slice.start
        let isFirst = record.fileSize == -2 && start == 0

        let task = Task.detached(priority: .utility) {
            do {
                try await Self.runSlice(manager: self, fileID: fileID, sliceID: sliceID, sourceIndex: sourceIndex, urls: urls, start: start, isFirst: isFirst)
                await self.sliceSucceeded(fileID: fileID, sliceID: sliceID)
            } catch {
                await self.sliceFailed(fileID: fileID, sliceID: sliceID, error: error)
            }
        }
        record.sliceTasks[sliceID] = task
    }

    private static func runSlice(manager: NetManager, fileID: UUID, sliceID: UUID, sourceIndex: Int, urls: [URL], start: Int64, isFirst: Bool) async throws {
        let url = urls[sourceIndex]
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("PCL.Mac/\(SharedConstants.shared.version)", forHTTPHeaderField: "User-Agent")
        // 显式禁用压缩：URLSession 默认自动发送 Accept-Encoding: gzip，
        // 服务器对压缩响应会忽略 Range 返回 200 全量（实测 piston-meta：gzip→200，identity→206），
        // 导致分片被误判为「源不支持断点续传」退化为单线程全量下载。PCL2 无此问题（.NET 默认 identity）。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if start > 0 {
            request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        }

        // 自适应超时：max(ConnectAverage=6s, 6s) * (1 + FailCount)，上限 30s（PCL2 1031 行）
        let failCount = await manager.sourceFailCount(fileID: fileID, sourceIndex: sourceIndex)
        request.timeoutInterval = min(30, 6 * Double(1 + failCount))

        // 统一直连会话（绕过系统代理）：系统代理对 bmclapi2 / mojang 的 TLS 转发失败时，
        // URLSession 会报 SecureConnectionFailed（curl 直连正常），这里改用 URLSession.direct
        // 直连，官方源被墙时由 pickSource 自动切镜像源。（详见 Requests.swift URLSession.direct）
        let (stream, response) = try await URLSession.direct.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NetDownloadError.fileFailed("无效的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetDownloadError.fileFailed("远程服务器返回了 \(http.statusCode)")
        }

        // 非首线程却返回 200（服务器忽略 Range 返回全量）→ 该源不支持断点续传（PCL2 1080-1088 行）
        if start > 0 && http.statusCode == 200 {
            await manager.sourceRejectsRange(fileID: fileID, sourceIndex: sourceIndex)
            throw NetDownloadError.sourceNoResumeSupport
        }

        // 首线程：确定文件大小并校验（PCL2 1044-1077 行）
        if isFirst {
            let length = http.expectedContentLength
            if length > 0 {
                try await manager.establishFileSize(fileID: fileID, size: length)
            } else {
                await manager.markUnknownSize(fileID: fileID)
            }
        }

        // 创建分片临时文件（目录可能被系统/用户清理，下载前再次确保存在）
        try FileManager.default.createDirectory(
            at: SharedConstants.shared.temperatureURL,
            withIntermediateDirectories: true
        )
        let tempURL = SharedConstants.shared.temperatureURL.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw NetDownloadError.fileFailed("无法创建临时文件")
        }
        await manager.sliceSetTemp(fileID: fileID, sliceID: sliceID, tempURL: tempURL)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var buffer = Data(capacity: 256 * 1024)
        var counter = 0
        var bytesSinceCheck: Int64 = 0
        var lastCheckTime = Date()

        for try await byte in stream {
            try Task.checkCancellation()
            buffer.append(byte)
            bytesSinceCheck += 1
            counter += 1

            // 慢速检测：间隔 > 1s 且速度 < 1KB/s 断开（PCL2 1158 行）
            if counter >= 1024 {
                counter = 0
                let now = Date()
                let dt = now.timeIntervalSince(lastCheckTime)
                if dt > 1.0 {
                    let speed = Double(bytesSinceCheck) / dt
                    if speed < 1024 {
                        throw NetDownloadError.slowSpeed
                    }
                    bytesSinceCheck = 0
                }
                lastCheckTime = now
            }

            if buffer.count >= 256 * 1024 {
                let remaining = await manager.sliceUndone(fileID: fileID, sliceID: sliceID)
                let toWrite: Int
                if remaining < 0 {
                    toWrite = buffer.count
                } else if remaining == 0 {
                    break
                } else {
                    toWrite = min(buffer.count, Int(remaining))
                }
                handle.write(Data(buffer.prefix(toWrite)))
                await manager.sliceAppend(fileID: fileID, sliceID: sliceID, bytes: toWrite)
                await SpeedMeter.shared.addBytes(toWrite)
                await manager.addBytes(Int64(toWrite))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        // 剩余缓冲
        if !buffer.isEmpty {
            let remaining = await manager.sliceUndone(fileID: fileID, sliceID: sliceID)
            let toWrite: Int
            if remaining < 0 {
                toWrite = buffer.count
            } else if remaining == 0 {
                toWrite = 0
            } else {
                toWrite = min(buffer.count, Int(remaining))
            }
            if toWrite > 0 {
                handle.write(Data(buffer.prefix(toWrite)))
                await manager.sliceAppend(fileID: fileID, sliceID: sliceID, bytes: toWrite)
                await SpeedMeter.shared.addBytes(toWrite)
                await manager.addBytes(Int64(toWrite))
            }
        }
    }

    // MARK: 分片状态回调

    private func sliceSucceeded(fileID: UUID, sliceID: UUID) async {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        activeSlices = max(0, activeSlices - 1)
        record.sliceTasks[sliceID] = nil
        // 服务器提前断流仍有剩余 → 视为失败，走断点续传（PCL2 1173 行）
        if record.fileSize != -1 && slice.undone(of: record) > 0 {
            slice.state = .failed
            record.failCount += 1
            return
        }
        slice.state = .done
        tryMergeIfPossible(record)
    }

    private func sliceFailed(fileID: UUID, sliceID: UUID, error: Error) async {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        activeSlices = max(0, activeSlices - 1)
        record.sliceTasks[sliceID] = nil
        slice.state = .failed
        record.failCount += 1
        record.sourceFails[slice.sourceIndex, default: 0] += 1
        // 连接层错误（SSL 握手失败 / 无法连接 / DNS / 连接中断）说明该源当前不可达，
        // 同源重试只会浪费时间（实测 SecureConnectionFailed 每源重试 3 次共耗 45s），
        // 直接把失败计数拉满，让 pickSource 立即跳过该源换下一个。
        if Self.isConnectionLevelError(error) {
            record.sourceFails[slice.sourceIndex] = config.maxFailPerSource
            record.failReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if record.isAllSourcesFailed(config.maxFailPerSource) {
            record.state = .failed
            record.failReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            cleanupTemps(record)
        }
    }

    /// 连接层错误判定：此类错误下同源重试无意义（PCL2 的源失败计数用于瞬时错误，这里单独提速）
    private static func isConnectionLevelError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .secureConnectionFailed,          // SSL/TLS 握手失败
             .cannotConnectToHost,             // 无法连接主机
             .cannotFindHost,                  // 主机名解析失败
             .dnsLookupFailed,                 // DNS 失败
             .networkConnectionLost,           // 连接中断
             .notConnectedToInternet,          // 无网络
             .timedOut:                        // 连接/请求超时
            return true
        default:
            return false
        }
    }

    // MARK: - 合并（PCL2 Merge，1295-1335 行）

    private func tryMergeIfPossible(_ record: FileRecord) {
        guard record.activeSliceCount == 0 else { return }
        let needsResume = record.slices.contains { $0.state == .failed && $0.undone(of: record) > 0 }
        guard !needsResume else { return }
        do {
            try merge(record)
            record.state = .done
            record.completion?()
        } catch {
            record.state = .failed
            record.failReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            cleanupTemps(record)
        }
    }

    private func merge(_ record: FileRecord) throws {
        let sorted = record.slices.sorted { $0.start < $1.start }
        let destination = record.file.destination
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            switch record.file.replaceMethod {
            case .replace, .skip:
                // 走到 merge 的 .skip 均为「需要重下」（哈希不匹配已删 / 禁用已有文件复用）→ 覆盖
                try FileManager.default.removeItem(at: destination)
            case .throw:
                throw NetDownloadError.fileExists(destination.lastPathComponent)
            }
        }

        let withData = sorted.filter { $0.tempURL != nil && $0.done > 0 }
        if withData.count == 1, let temp = withData[0].tempURL {
            // 单线程：直接移动
            try FileManager.default.moveItem(at: temp, to: destination)
        } else {
            // 多分片：按 start 顺序流式拼接
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw NetDownloadError.mergeFailed("无法创建目标文件")
            }
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            for slice in withData {
                guard let temp = slice.tempURL, let input = try? FileHandle(forReadingFrom: temp) else { continue }
                defer { try? input.close() }
                while let data = try? input.read(upToCount: 1 << 20), !data.isEmpty {
                    out.write(data)
                }
            }
        }
        // 清理分片临时文件
        cleanupTemps(record)

        // 下载后四合一校验（PCL2 FileChecker.Check）
        if let checker = record.file.checker {
            if let err = checker.check(destination) {
                try? FileManager.default.removeItem(at: destination)
                throw NetDownloadError.fileFailed(err)
            }
        }
    }

    // MARK: - 工具

    private func find(_ id: UUID) -> FileRecord? {
        records.first { $0.id == id }
    }

    private func cleanupTemps(_ record: FileRecord) {
        for slice in record.slices {
            if let temp = slice.tempURL {
                try? FileManager.default.removeItem(at: temp)
            }
        }
    }

    private func waitForCompletion(_ ids: [UUID]) async throws {
        while true {
            var failedReason: String?
            var allTerminal = true
            for id in ids {
                guard let r = find(id) else { continue }
                if !r.isTerminal { allTerminal = false }
                if r.state == .failed, failedReason == nil { failedReason = r.failReason }
            }
            if allTerminal {
                if let failedReason {
                    throw NetDownloadError.fileFailed(failedReason)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
        }
    }

    // MARK: 分片执行器内部接口

    private func sourceFailCount(fileID: UUID, sourceIndex: Int) -> Int {
        find(fileID)?.sourceFails[sourceIndex] ?? 0
    }

    private func sourceRejectsRange(fileID: UUID, sourceIndex: Int) {
        find(fileID)?.sourcesOnce.insert(sourceIndex)
    }

    private func establishFileSize(fileID: UUID, size: Int64) throws {
        guard let record = find(fileID) else { return }
        record.fileSize = size
        if let checker = record.file.checker {
            if checker.minSize > 0 && size < checker.minSize {
                throw NetDownloadError.fileFailed("文件大小不足，获取结果为 \(size) B，要求至少为 \(checker.minSize) B")
            }
            if checker.actualSize > 0 && size != checker.actualSize {
                throw NetDownloadError.fileFailed("文件大小不一致，获取结果为 \(size) B，要求必须为 \(checker.actualSize) B")
            }
        }
        // >50MB 磁盘空间预检（PCL2 1066-1077 行）
        if size > 50 * 1024 * 1024 {
            if let values = try? record.file.destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let capacity = values.volumeAvailableCapacityForImportantUsage,
               capacity < size + 5 * 1024 * 1024 {
                throw NetDownloadError.fileFailed("磁盘空间不足，需要至少 \(size + 5 * 1024 * 1024) B，当前仅剩余 \(capacity) B")
            }
        }
    }

    private func markUnknownSize(fileID: UUID) {
        find(fileID)?.fileSize = -1
    }

    private func sliceSetTemp(fileID: UUID, sliceID: UUID, tempURL: URL) {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        slice.tempURL = tempURL
    }

    private func sliceAppend(fileID: UUID, sliceID: UUID, bytes: Int) {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return }
        slice.done += Int64(bytes)
    }

    private func sliceUndone(fileID: UUID, sliceID: UUID) -> Int64 {
        guard let record = find(fileID), let slice = record.slice(sliceID) else { return -1 }
        if record.fileSize == -1 { return -1 }
        return slice.undone(of: record)
    }

    private func addBytes(_ n: Int64) {
        totalBytes += n
    }
}
