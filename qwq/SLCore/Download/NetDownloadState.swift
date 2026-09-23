//
//  NetDownloadState.swift
//  SL启动器
//
//  NetManager 的内部状态模型：分片、文件记录及其派生量。
//  自 NetDownloader.swift 按职责物理拆出，原第 152-231 行，逻辑与注释均未改动。
//  这些类型原为 NetManager 内的私有嵌套类型，跨文件拆分后放宽为 internal（不再加更严的访问级别），
//  对外仍不可见，公开 API 未变化。
//  - Slice / SliceState：单个 Range 分片的进度与状态
//  - FileRecord / FileState：单个下载文件的分片集合、源记账与进度
//

import Foundation

extension NetManager {
    // MARK: 内部状态

    /// 单个分片的生命周期。注意 `downloading` 与 `resumed` **语义上都是「正在跑」**，
    /// 区分它们只为日志与展示（首次下载还是断点续传）；判定「活跃分片」时两者必须一起算
    /// （见 FileRecord.activeSliceCount）。
    enum SliceState {
        case downloading   // 运行中
        case resumed       // 运行中（断点续传）
        case done          // 已完成
        case failed        // 失败（保留部分数据，可续传）
    }

    /// 一个 Range 分片。`start` 与 `done` 表达「已下到哪」，
    /// 而**结束位置不落字段**，由 `end(of:)` 按同一文件内其它分片实时推出 ——
    /// 这样调整分片数量时无需回填任何边界值。
    final class Slice {
        let id = UUID()
        let start: Int64
        var done: Int64 = 0
        var sourceIndex: Int
        var state: SliceState = .downloading
        /// 本片临时文件地址（断点续传要复用它）；nil 表示尚未分配。
        var tempURL: URL?

        init(start: Int64, sourceIndex: Int) {
            self.start = start
            self.sourceIndex = sourceIndex
        }

        /// 本片结束位置 = 下一片起点 - 1；最后一片 = 文件大小 - 1（参照上游 PCL2 的 DownloadEnd）
        /// ⚠️ 每次调用都会对全部分片排序 + 线性查找（O(n log n)），而 `undone` 又依赖它 ——
        /// 在进度刷新这类高频路径上属于可避免的开销。
        /// 另外分片表里找不到自己时会**返回文件末尾**（兜底），于是「分片表不同步」
        /// 这个错误会被伪装成「这片要下到文件尾」，不会报错但结论错。
        func end(of record: FileRecord) -> Int64 {
            let sorted = record.slices.sorted { $0.start < $1.start }
            guard let idx = sorted.firstIndex(where: { $0.id == id }) else { return record.fileSize - 1 }
            if idx + 1 < sorted.count { return sorted[idx + 1].start - 1 }
            return record.fileSize - 1
        }

        /// 剩余字节 = End + 1 - (Start + Done)（参照上游 PCL2 的 DownloadUndone）
        /// `fileSize == -1`（大小未知）时返回 -1 表示「不限」，调用方需特判；
        /// ⚠️ `fileSize == -2`（尚未获取大小）**没有特判**，会经 `max(0, ·)` 得到 0，
        /// 表现为「这片已经没有剩余」—— 不会崩但结论是错的（正常流程先取大小，故暂不可达）。
        func undone(of record: FileRecord) -> Int64 {
            if record.fileSize == -1 { return -1 } // 未知大小：不限
            return max(0, end(of: record) + 1 - (start + done))
        }
    }

    /// 单个文件的生命周期。`merging`（各分片已下完、正在拼成最终文件）**不是终止态** ——
    /// 合并失败会回到 `failed`，所以收尾时必须等它走完。
    /// 终止判定统一走 `FileRecord.isTerminal`，不要在别处硬写 `== .done`。
    enum FileState {
        case waiting, loading, merging, done, failed
    }

    /// 单个下载文件的全部状态：分片集合、每个源的失败记账、进度与完成回调。
    /// 生命周期由 NetManager 持有并推进；本类型自身**不加锁**，
    /// 并发安全依赖 NetManager 的串行调度（见 NetDownloader.swift）。
    final class FileRecord {
        let id = UUID()
        let file: SLNetFile
        var fileSize: Int64 = -2        // -2 未获取；-1 未知；>0 已知
        var state: FileState = .waiting
        var slices: [Slice] = []
        /// 键为 `Slice.id`：各分片对应的下载任务，供取消与等待使用。
        var sliceTasks: [UUID: Task<Void, Never>] = [:]
        /// 记为「只能整份下、不能 Range 续传」的源下标（once = 一次到底）。
        /// 一旦某源被记进来，它就不再算作可用重试对象（见 isAllSourcesFailed）。
        var sourcesOnce: Set<Int> = []  // 不支持断点续传的源
        /// 每个源（下标）累计的失败次数，用于判定**单个源**是否已判死。
        var sourceFails: [Int: Int] = [:]
        /// 整个文件的失败次数（跨源累计）。与 `sourceFails` 是不同粒度：
        /// 这个决定「还要不要整体重试」，那个决定「某个源还能不能用」。
        var failCount = 0
        /// 最后一次失败的原因文本，**会被直接展示给用户**，因此是面向用户的文案。
        var failReason = ""
        /// 进度回调（0~1）。仅在有新进展时调用；下载任务不在主线程上跑，
        /// 实现里若要碰 UI 必须自己切回主线程。
        var progressHandler: ((Double) -> Void)?
        /// 完成回调（**不带参数**）：成功还是失败要靠 `state` 自行判断，
        /// 回调本身不携带结果。
        var completion: (() -> Void)?

        init(_ file: SLNetFile) {
            self.file = file
        }

        /// 是否已到终止态。`.merging` 刻意不算 —— 合并还在跑，取消时不能跳过它。
        var isTerminal: Bool { state == .done || state == .failed }
        /// 正在跑的分片数（首次下载与续传都算）。每次访问都全表 filter，属高频路径上的开销。
        var activeSliceCount: Int { slices.filter { $0.state == .downloading || $0.state == .resumed }.count }

        func slice(_ id: UUID) -> Slice? {
            slices.first { $0.id == id }
        }

        /// 0~1 的完成度。
        /// - `.done` 直接返回 1，不依赖分片累计 —— 否则最后一片的 done 尚未回填时，
        ///   界面会停在一个到不了 100% 的数字上。
        /// - 大小还未知（`fileSize <= 0`）时返回 0，而不是拿负数去做除法。
        var progressValue: Double {
            if state == .done { return 1 }
            if fileSize <= 0 { return 0 }
            let done = slices.reduce(Int64(0)) { $0 + $1.done }
            return min(1, Double(done) / Double(fileSize))
        }

        /// 是否所有源都已判死：每一个源要么被记进 `sourcesOnce`（不支持续传），
        /// 要么失败次数已达 `maxFail`。只要还剩一个「可用且没超限」的源就返回 false。
        /// ⚠️ 分界是 `<`：失败次数**恰好等于** `maxFail` 时已算判死。
        func isAllSourcesFailed(_ maxFail: Int) -> Bool {
            for i in 0..<file.urls.count {
                if !sourcesOnce.contains(i) && sourceFails[i, default: 0] < maxFail { return false }
            }
            return true
        }
    }
}
