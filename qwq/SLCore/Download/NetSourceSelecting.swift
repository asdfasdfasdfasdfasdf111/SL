//
//  NetSourceSelecting.swift
//  SL启动器
//
//  NetManager 的下载源选择与源失败记账：
//  - pickSource：按顺序跳过「不支持断点续传的源」与「失败次数超阈值的源」，全部不可用时置文件为失败
//    并清理本文件已产生的分片临时文件；
//  - isConnectionLevelError：连接层错误（SSL/无法连接/DNS/断流/无网络/超时）判定；
//  - sourceFailCount / sourceRejectsRange：分片任务读写源记账的 actor 边界接口。
//  自 NetDownloader.swift 按职责物理拆出，原第 525-535、722-737、837-843 行，判定顺序与阈值未改动。
//
//  本次修复（失败时不清理已产生的分片）：pickSource 是「所有源均不可用」的判定点，此前只置 state 与
//  failReason，自身产生的分片临时文件依赖外层 cancelRecords 兜底——而 cancelRecords 只在
//  download / downloadAll 的退出路径调用，单文件失败发生在批次中途时无法及时覆盖。现由本函数
//  复用既有的 cleanupTemps 完成清理。
//

import Foundation

extension NetManager {
    /// 查询可用源（**纯查询：不改任何状态**）。
    ///
    /// - Parameter needsRange: `true` 时跳过「只能整份下」的源（`sourcesOnce`）。
    ///   从 0 开始的整份下载**不需要** Range，所以那时它们仍然可用 —— 这一点是
    ///   2026-10-05 修「源不支持断点续传就整个文件失败」的关键：
    ///   源忽略 Range（返回 200 全量）只代表**不能分片/续传**，不代表它不能下这个文件。
    func availableSource(_ record: FileRecord, needsRange: Bool) -> Int? {
        for i in 0..<record.file.urls.count {
            if needsRange && record.sourcesOnce.contains(i) { continue }
            if record.sourceFails[i, default: 0] >= config.maxFailPerSource { continue }
            return i
        }
        return nil
    }

    /// 选定源；确实一个可用源都没有时才把文件判死（终态判定点，含分片临时文件清理）。
    func pickSource(_ record: FileRecord) -> Int? {
        if let index = availableSource(record, needsRange: false) { return index }
        markNoAvailableSource(record)
        return nil
    }

    /// 把文件置为「无可用源」终态。
    /// 失败路径自行清理已产生的分片临时文件：本函数是终态判定点，此处的清理不依赖
    /// 外层 cancelRecords（它仅在 download / downloadAll 退栈时调用，批次中途的单文件失败
    /// 不会经过该路径），避免残留 .tmp 占用缓存目录。
    func markNoAvailableSource(_ record: FileRecord) {
        record.state = .failed
        record.failReason = "所有下载源均不可用"
        record.failureKind = .noAvailableSource   // 结构化类别：让 NetDownloader 抛精确错误而非泛化 fileFailed
        cleanupTemps(record)
    }

    /// 连接层错误判定：此类错误下同源重试无意义（参照上游 PCL2：其源失败计数用于瞬时错误，这里单独提速）
    static func isConnectionLevelError(_ error: Error) -> Bool {
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

    /// 从抛出的错误反推结构化失败类别（2026-10-02）。
    /// 用于 `sliceFailed` 在错误落地为 `failReason` 文案的同一刻置位 `FileRecord.failureKind`，
    /// 使精确类别穿过「错误 → 文案 → 再抛出」的中转而不丢失（见 NetDownloaderDownloadEngine.map 注释）。
    static func failureKind(of error: Error) -> NetDownloadFailureKind? {
        guard let netError = error as? NetDownloadError else { return nil }
        switch netError {
        case .checksumMismatch:
            return .checksumMismatch
        case .diskFull:
            return .diskFull
        case .httpStatus(let code):
            return .httpStatus(code)
        case .timeout:
            return .timeout
        case .noAvailableSource:
            return .noAvailableSource
        default:
            return nil
        }
    }

    func sourceFailCount(fileID: UUID, sourceIndex: Int) -> Int {
        find(fileID)?.sourceFails[sourceIndex] ?? 0
    }

    func sourceRejectsRange(fileID: UUID, sourceIndex: Int) {
        find(fileID)?.sourcesOnce.insert(sourceIndex)
    }
}
