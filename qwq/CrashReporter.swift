//
//  CrashReporter.swift
//  崩溃自捕获：挂 SIGSEGV/SIGBUS/SIGILL/SIGABRT/SIGTRAP handler，
//  崩溃时把当前线程 backtrace 写到 ~/Library/Logs/qwq_crash.log。
//  目的：用户 Xcode Run 崩溃时 LLDB 拦截不会落系统 .ips，导致崩溃堆栈丢失；
//  有了这个文件，下次崩溃后直接读 qwq_crash.log 即可拿到调用栈定位。
//  同时注册 NSSetUncaughtExceptionHandler（Swift fatalError / ObjC 异常）写入同一文件。
//

import Foundation
import Darwin

enum CrashReporter {
    private static var installed = false
    private static let logPath = NSHomeDirectory() + "/Library/Logs/qwq_crash.log"

    static func install() {
        guard !installed else { return }
        installed = true
        let sigs: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP]
        for sig in sigs {
            signal(sig, { s in
                CrashReporter.writeCrashLog(signal: s, extra: nil)
                // 恢复默认行为让系统生成标准崩溃报告后退出
                signal(s, SIG_DFL)
                raise(s)
            })
        }
        NSSetUncaughtExceptionHandler { ex in
            let extra = "NSException: \(ex.name.rawValue)\n\(ex.reason ?? "")\n\(ex.callStackSymbols.joined(separator: "\n"))"
            CrashReporter.writeCrashLog(signal: 0, extra: extra)
        }
    }

    /// 崩溃日志落盘（尽量用 async-signal-safe 的函数）
    static func writeCrashLog(signal: Int32, extra: String?) {
        let fd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var header = "===== qwq crash =====\n"
        header += "time: \(Date())\n"
        header += "signal: \(signal) (\(signal != 0 ? String(cString: strsignal(signal)) : "exception"))\n"
        header += "--- thread backtrace ---\n"
        writeStr(fd, header)

        var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let frames = callstack.withUnsafeMutableBufferPointer { buf in
            backtrace(buf.baseAddress, 128)
        }
        callstack.withUnsafeMutableBufferPointer { buf in
            backtrace_symbols_fd(buf.baseAddress, frames, fd)
        }

        if let extra {
            writeStr(fd, "\n--- extra ---\n")
            writeStr(fd, extra)
        }
        writeStr(fd, "\n===== end =====\n")
    }

    private static func writeStr(_ fd: Int32, _ s: String) {
        s.withCString { c in
            _ = write(fd, c, strlen(c))
        }
    }
}
