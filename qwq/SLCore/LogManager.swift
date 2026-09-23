//
//  LogManager.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/19.
//

import Foundation
import SwiftUI
import Combine

final class LogStore {
    let dateFormatter = DateFormatter()
    static let shared = LogStore()
    private let writeImmediately = true
    
    private let queue = DispatchQueue(label: "io.github.asdfasdfasdfasdfasdf111.SL.LogStoreQueue")

    private init() {
        dateFormatter.dateFormat = "[yyyy-MM-dd] [HH:mm:ss.SSS]"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    }
    
    func append(_ message: String, _ level: String, _ caller: String) {
        // 时间戳的格式化必须在串行队列【内部】完成。
        // DateFormatter 不是线程安全的，而本方法会被任意线程调用（后台下载线程、
        // Process 的 terminationHandler、进程池等）。此前是在队列外先格式化再投递，
        // 并发调用会同时读写同一个 formatter 实例（未定义行为）。
        queue.async {
            let stamp = self.dateFormatter.string(from: Date())
            self.appendLocked("\(stamp) [\(level)] \(caller): \(message)")
        }
    }
    
    func appendRaw(_ message: String, write: Bool = true) {
        queue.async {
            self.appendLocked(message, write: write)
        }
    }
    
    /// 真正的写入实现。**只在 `queue` 上调用**（调用方须已在串行队列内），故无需再加锁。
    private func appendLocked(_ message: String, write: Bool = true) {
        if writeImmediately && write {
            appendToDisk(message + "\n")
        }
        print(message)
    }
    
    /// 追加一行到落盘日志文件。
    ///
    /// **失败路径不得回灌日志系统**（本方法曾经调用 `err(...)`，已修）：
    /// `appendLocked` 每写一行都会进入本方法，而 `err` 的调用链是
    /// `err → LogManager.err → LogStore.append → queue.async → appendLocked → appendToDisk`。
    /// 一旦写盘**持续**失败（磁盘写满 / 日志目录不可写 / `logURL` 指向目录），
    /// 这条链就变成自反馈循环：队列永不停歇地重试失败写盘、每次都再投递一条错误日志，
    /// CPU 单核打满、stdout 被刷屏，且错误提示本身永远不可能落盘（因为它也要写盘）。
    /// 故失败时只做一次 `print`（不落盘、不进日志系统），循环被切断。
    func appendToDisk(_ content: String, _ callback: ((Bool) -> Void)? = nil) {
        do {
            try FileManager.writeLog(content)
            callback?(true)
        } catch {
            print("[LogStore] 日志保存失败: \(error.localizedDescription)")
            callback?(false)
        }
    }
    
    /// 清空落盘日志文件。
    /// **必须投递到 `queue`**：`appendLocked` 正在写同一个文件，若在调用方线程直接
    /// `removeItem`，会与队列上的 `FileHandle` 写入并发（删掉另一个线程已打开的 inode），
    /// 造成写入落空或句柄错误。投递到同一串行队列后，删除与写入天然互斥。
    func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: SharedConstants.shared.logURL)
        }
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
