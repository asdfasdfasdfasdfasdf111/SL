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

    enum SliceState {
        case downloading   // 运行中
        case resumed       // 运行中（断点续传）
        case done          // 已完成
        case failed        // 失败（保留部分数据，可续传）
    }

    final class Slice {
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

    enum FileState {
        case waiting, loading, merging, done, failed
    }

    final class FileRecord {
        let id = UUID()
        let file: SLNetFile
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

        init(_ file: SLNetFile) {
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
}
