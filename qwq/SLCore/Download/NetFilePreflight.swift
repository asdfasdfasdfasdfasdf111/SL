//
//  NetFilePreflight.swift
//  SL启动器
//
//  NetManager 的下载前预检：按覆盖策略与 FileChecker 判定「跳过 / 下载 / 抛错」。
//  自 NetDownloader.swift 按职责物理拆出，原第 341-366 行，逻辑与文案均未改动。
//  预检是 actor 内的原子步骤：命中「存在但校验不过」时会删除目标文件后重下。
//

import Foundation

extension NetManager {
    // MARK: - 预检（PCL2 FileChecker.CanUseExistsFile + ReplaceMethod 语义）

    enum PrecheckResult {
        case skip, download, throwError(Error)
    }

    func precheck(_ record: FileRecord) -> PrecheckResult {
        guard FileManager.default.fileExists(atPath: record.file.destination.path) else { return .download }
        switch record.file.replaceMethod {
        case .throw:
            return .throwError(NetDownloadError.fileExists(record.file.destination.lastPathComponent))
        case .replace:
            return .download
        case .skip:
            guard let checker = record.file.checker else {
                // 无校验要求：存在即跳过（PCL2 FileChecker.CanUseExistsFile 默认 true；无 checker 视为通过）
                return .skip
            }
            guard checker.canUseExistsFile else {
                // 显式要求「不复用已有文件」（CanUseExistsFile = false）：即使本地已存在也必须重下。
                // ⚠️ 原实现把这个开关写反了 —— canUseExistsFile == false 时反而走到下面的 return .skip，
                // 即「要求重下却复用了旧文件」，调用方设这个开关完全不起作用。
                return .download
            }
            if checker.check(record.file.destination) == nil {
                return .skip
            }
            // 存在但校验不过（如哈希不匹配）→ 删除重下
            try? FileManager.default.removeItem(at: record.file.destination)
            return .download
        }
    }
}
