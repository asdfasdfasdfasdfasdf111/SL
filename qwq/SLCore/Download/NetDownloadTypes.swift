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

/// 下载失败的结构化类别（替代「靠 failReason 文本匹配」）。
/// 2026-10-02 引入首个成员 `noAvailableSource`；后续如需区分其它终端失败
/// （校验失败、落盘失败等）在此扩充，并同步 FileRecord 的置位点与该枚举的抛出点。
public enum NetDownloadFailureKind: Sendable {
    /// 全部候选下载源均不可用（对应 `NetDownloadError.noAvailableSource`）。
    case noAvailableSource
}
