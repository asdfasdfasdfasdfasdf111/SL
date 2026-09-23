//
//  FileManagerExtension.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/19.
//

import Foundation

extension FileManager {
    static let logURL = SharedConstants.shared.logURL

    /// 单文件日志上限（5 MB）。超过即把当前内容归档为 `.old` 并从空文件重新写，
    /// 避免长期运行后日志文件无限增长占满磁盘（原实现无上限、无轮转）。
    private static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    static func writeLog(_ content: String) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            try fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        // 轮转：超过上限就把当前内容归档为同名 `.old`（覆盖旧归档），再从空文件开始写。
        // 本函数在 `LogStore` 的串行 `queue` 上调用，单文件同一时刻只有一个写者在跑，天然无竞态。
        if let attrs = try? fileManager.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64, size > maxLogBytes {
            let oldURL = logURL.deletingPathExtension().appendingPathExtension("log.old")
            try? fileManager.removeItem(at: oldURL)
            try? fileManager.moveItem(at: logURL, to: oldURL)
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(content.utf8))
    }
}
