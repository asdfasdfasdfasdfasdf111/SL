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
    // 预留 case：全部候选源均不可用。
    // 当前引擎的失败载体是 `FileRecord.failReason: String`（由 NetSourceSelecting.pickSource 写入
    // 「所有下载源均不可用」），download / waitForCompletion 一律包装为 `.fileFailed` 抛出，
    // 因此本 case 目前不会被构造。保留而非删除的理由：Core/Download 适配层按 NetDownloadError
    // 归类失败原因（NetDownloaderDownloadEngine.map(_:) → DownloadError.sourceUnavailable），
    // 该归类只有在失败载体从字符串改为结构化错误后才可达，属已登记的迁移目标；接入本 case
    // 需要给 FileRecord 增加结构化错误字段，超出本次修复范围，故按预留标注处理。
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
