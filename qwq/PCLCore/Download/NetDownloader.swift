//
//  NetDownloader.swift
//  PCL.Mac
//
//  对标 PCL2 (ModNet.vb) 移植的多线程分片下载引擎的协调层。
//  本文件只保留 actor 声明、资源参数、实例状态、公开入口与终态等待：
//  - Config：全局分片上限、最小分割粒度、多分片门槛、速度下限、单源失败阈值、调度周期
//  - download / downloadAll：单文件与批量入口（含预检跳过分支的进度回调、取消时的分片与临时文件清理）
//  - find / waitForCompletion：记录查找与终态等待（100ms 轮询 + Task 取消检查）
//  其余实现按职责拆分在同目录，逻辑、常量与文案均与原实现逐字一致（仅物理搬移）：
//  - NetFileChecker.swift        四合一校验（ActualSize / MinSize / Hash / IsJson）
//  - NetDownloadTypes.swift      PCLNetFile / NetDownloadError
//  - NetDownloadState.swift      Slice / FileRecord 等内部状态模型
//  - NetFilePreflight.swift      覆盖策略（.skip/.replace/.throw）与校验预检
//  - NetScheduling.swift         40ms tick 调度循环与速度统计
//  - NetProgressReporting.swift  单文件进度上报与批量进度聚合
//  - NetSliceAllocation.swift    分片分配（首片 / 续传 / 最大碎片分割）
//  - NetSliceFetcher.swift       分片执行、状态回调与 actor 边界接口
//  - NetSourceSelecting.swift    源选择、源失败记账与连接层错误判定
//  - NetMerger.swift             分片合并与下载后校验
//  - NetCleanup.swift            取消与临时分片清理
//

import Foundation

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

    // MARK: - 实例状态（状态模型定义见 NetDownloadState.swift）
    var records: [FileRecord] = []
    var activeSlices = 0
    var tickTask: Task<Void, Never>?
    var tickCount = 0
    var totalBytes: Int64 = 0
    var lastTotalBytes: Int64 = 0
    var lastSpeedTime = Date()
    var recentSpeed: Double = 0

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
        // 已确认的**不可达**分支，保留作防御（不改行为）。
        // 依据：waitForCompletion 在 allTerminal 成立时，只要任一记录 state == .failed 就必抛
        // NetDownloadError.fileFailed（本文件 :154-160）；而 FileRecord.isTerminal 只包含 .done / .failed
        // （NetDownloadState.swift:75），所以它正常返回 ⇒ 本记录 state == .done。
        // 另一条逃生路径「找不到记录 → continue」也不成立：记录 id 为 UUID 且各批次互斥，
        // 本记录的移除点只有本方法自己的 removeAll（downloadAll 的收尾只移除自己 pending 里的 id）。
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

    // MARK: - 工具

    func find(_ id: UUID) -> FileRecord? {
        records.first { $0.id == id }
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
}
