//
//  NetSourceSelecting.swift
//  PCL.Mac
//
//  NetManager 的下载源选择与源失败记账：
//  - pickSource：按顺序跳过「不支持断点续传的源」与「失败次数超阈值的源」，全部不可用时置文件为失败；
//  - isConnectionLevelError：连接层错误（SSL/无法连接/DNS/断流/无网络/超时）判定；
//  - sourceFailCount / sourceRejectsRange：分片任务读写源记账的 actor 边界接口。
//  自 NetDownloader.swift 按职责物理拆出，原第 525-535、722-737、837-843 行，判定顺序与阈值未改动。
//

import Foundation

extension NetManager {
    /// 选择可用源：按顺序跳过黑名单（不支持断点续传）与失败超阈值的源
    func pickSource(_ record: FileRecord) -> Int? {
        for i in 0..<record.file.urls.count {
            if record.sourcesOnce.contains(i) { continue }
            if record.sourceFails[i, default: 0] >= config.maxFailPerSource { continue }
            return i
        }
        record.state = .failed
        record.failReason = "所有下载源均不可用"
        return nil
    }

    /// 连接层错误判定：此类错误下同源重试无意义（PCL2 的源失败计数用于瞬时错误，这里单独提速）
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

    func sourceFailCount(fileID: UUID, sourceIndex: Int) -> Int {
        find(fileID)?.sourceFails[sourceIndex] ?? 0
    }

    func sourceRejectsRange(fileID: UUID, sourceIndex: Int) {
        find(fileID)?.sourcesOnce.insert(sourceIndex)
    }
}
