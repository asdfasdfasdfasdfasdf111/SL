//
//  NetDownloadTypes.swift
//  PCL.Mac
//
//  NetManager 下载链路的公共数据与错误类型。
//  自 NetDownloader.swift 按职责物理拆出，原第 92-132 行，逻辑与文案均未改动。
//  - PCLNetFile：一次下载任务的描述（候选源、目标路径、校验参数、覆盖策略）
//  - NetDownloadError：下载链路对外抛出的错误
//

import Foundation

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
