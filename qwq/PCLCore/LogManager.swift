//
//  LogManager.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/19.
//

import Foundation
import SwiftUI
import Combine

class LogLine: Identifiable {
    let id: UUID = UUID()
    let string: String
    
    init(_ string: String) {
        self.string = string
    }
}

final class LogStore {
    let dateFormatter = DateFormatter()
    static let shared = LogStore()
    private var logs: [String] = []
    var logLines: [LogLine] = []
    private let maxCapacity = 10_000
    private let writeImmediately = true
    
    private let queue = DispatchQueue(label: "io.github.pcl-community.LogStoreQueue")

    private init() {
        dateFormatter.dateFormat = "[yyyy-MM-dd] [HH:mm:ss.SSS]"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    }
    
    func append(_ message: String, _ level: String, _ caller: String) {
        appendRaw(
            "\(dateFormatter.string(from: Date())) [\(level)] \(caller): \(message)",
            LogLine("[\(level)] \(caller): \(message)")
        )
    }
    
    func appendRaw(_ message: String, _ line: LogLine? = nil, write: Bool = true) {
        queue.async {
            if self.logs.count >= self.maxCapacity {
                self.logs.removeFirst(1000)
            }
            if self.logLines.count >= 200 {
                self.logLines.removeFirst(100)
            }
            self.logs.append(message)
            self.logLines.append(line ?? LogLine(message))
            if self.writeImmediately && write {
                self.appendToDisk(message + "\n")
            }
            print(message)
        }
    }
    
    func appendToDisk(_ content: String, _ callback: ((Bool) -> Void)? = nil) {
        do {
            try FileManager.writeLog(content)
            callback?(true)
        } catch {
            err("日志保存失败: \(error.localizedDescription)")
            callback?(false)
        }
    }
    
    func clear() {
        try? FileManager.default.removeItem(at: SharedConstants.shared.logURL)
    }
}

/// 游戏日志目录（`GameLogs/`）的保留策略。
///
/// 背景：进程以退出码 0 结束时曾直接删除本次日志文件，导致会话日志面板与
/// `LaunchResult.logURL` 指向一个已不存在的路径。现改为「保留文件 + 按份数上限修剪」：
/// 每次启动都会新建日志文件，因此在新建之后按最后修改时间修剪，只保留最近 `maxCount` 份。
public enum GameLogRetention {
    /// 保留的最近日志份数上限。
    public static let maxCount = 20

    /// 修剪日志目录：按最后修改时间倒序保留最近 `maxCount` 份，其余删除。
    /// 正在运行的游戏日志其修改时间为当前，不会被误删。
    public static func prune(in directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let dated: [(url: URL, modified: Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }

        guard dated.count > maxCount else { return }
        for item in dated.sorted(by: { $0.modified > $1.modified }).dropFirst(maxCount) {
            try? fm.removeItem(at: item.url)
        }
    }
}

public struct LogManager {
    public static func log(_ message: Any, file: String = #file, line: Int = #line) {
        LogStore.shared.append(String(describing: message), "INFO", file.split(separator: "/").last! + ":" + String(line))
    }

    public static func warn(_ message: Any, file: String = #file, line: Int = #line) {
        LogStore.shared.append(String(describing: message), "WARN", file.split(separator: "/").last! + ":" + String(line))
    }

    public static func err(_ message: Any, file: String = #file, line: Int = #line) {
        LogStore.shared.append(String(describing: message), "ERROR", file.split(separator: "/").last! + ":" + String(line))
    }

    public static func debug(_ message: Any, file: String = #file, line: Int = #line) {
        LogStore.shared.append(String(describing: message), "DEBUG", file.split(separator: "/").last! + ":" + String(line))
    }

    public static func raw(_ message: Any) {
        LogStore.shared.appendRaw(String(describing: message), write: false)
    }
}

public func log(_ message: Any, file: String = #file, line: Int = #line) { LogManager.log(message, file: file, line: line) }
public func warn(_ message: Any, file: String = #file, line: Int = #line) { LogManager.warn(message, file: file, line: line) }
public func err(_ message: Any, file: String = #file, line: Int = #line) { LogManager.err(message, file: file, line: line) }
public func debug(_ message: Any, file: String = #file, line: Int = #line) { LogManager.debug(message, file: file, line: line) }
public func raw(_ message: Any, file: String = #file, line: Int = #line) { LogManager.raw(message) }

