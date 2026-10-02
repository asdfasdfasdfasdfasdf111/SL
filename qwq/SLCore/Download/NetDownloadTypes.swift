//
//  NetDownloadTypes.swift
//  SL启动器
//
//  NetManager 下载链路的公共数据与错误类型。
//  自 NetDownloader.swift 按职责物理拆出，原第 92-132 行，逻辑与文案均未改动。
//  - SLNetFile：一次下载任务的描述（候选源、目标路径、校验参数、覆盖策略）
//  - NetDownloadError：下载链路对外抛出的错误
//

import Foundation

// MARK: - 下载文件描述（移植自上游 PCL2 的 NetFile）

public final class SLNetFile {
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
    // 已可达（2026-10-02）：`FileRecord.failureKind == .noAvailableSource` 时由
    // NetDownloader 构造本 case。此前为「声明了但永不构造」的预留态——失败载体
    // 是 `FileRecord.failReason: String`（由 NetSourceSelecting.pickSource 写入
    // 「所有下载源均不可用」），download / waitForCompletion 一律包装为 `.fileFailed` 抛出；
    // 现已通过结构化类别字段接入（见 NetDownloadState.FileRecord.failureKind 注释）。
    case noAvailableSource(String)
    case sourceNoResumeSupport
    case slowSpeed
    // 2026-10-02：以下四个 case 是「结构化错误类别」的落地——替代此前
    // Core/Download 适配层靠 failReason **中文文案 contains 反猜**（哈希校验失败 /
    // 磁盘空间不足 / 远程服务器返回了 N / 超时）的分类方式。抛点在源头直接以
    // 精确 case 抛出（NetSliceFetcher / NetMerger / NetDownloader），
    // FileRecord.failureKind 随之置位，waitForCompletion / download 按类别抛出，
    // 适配层 switch 直达 DownloadError，不再读文案。
    case checksumMismatch(String)
    case diskFull(String)
    case httpStatus(Int)
    case timeout(String)
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
        case .checksumMismatch(let reason):
            return "文件校验失败：\(reason)"
        case .diskFull(let reason):
            return "磁盘空间不足：\(reason)"
        case .httpStatus(let code):
            return "远程服务器返回了 \(code)。"
        case .timeout(let reason):
            return "下载超时：\(reason)"
        case .fileFailed(let reason):
            return "下载失败：\(reason)"
        case .mergeFailed(let reason):
            return "合并文件失败：\(reason)"
        }
    }
}

/// 下载失败的结构化类别（替代「靠 failReason 文本匹配」）。
/// 2026-10-02：随 NetDownloadError 精确 case 同步扩到五类，每个成员对应一个
/// `NetDownloadError` case；`FileRecord.failureKind` 在失败落地处置位，
/// waitForCompletion / download 按类别抛精确错误，适配层 switch 直达
/// `DownloadError`，不再读 failReason 中文文案（见 NetDownloaderDownloadEngine.map 注释）。
public enum NetDownloadFailureKind: Sendable {
    /// 全部候选下载源均不可用（对应 `NetDownloadError.noAvailableSource`）。
    case noAvailableSource
    /// 大小或哈希校验不通过（对应 `NetDownloadError.checksumMismatch`）。
    case checksumMismatch
    /// 磁盘空间不足（对应 `NetDownloadError.diskFull`）。
    case diskFull
    /// 服务器返回非 2xx 状态码（对应 `NetDownloadError.httpStatus`）。
    case httpStatus(Int)
    /// 连接或分片传输超时 / 整体等待超时（对应 `NetDownloadError.timeout`）。
    case timeout
}
