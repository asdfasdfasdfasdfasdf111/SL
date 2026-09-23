//
//  CrashReporter.swift
//  崩溃自捕获：挂 SIGSEGV/SIGBUS/SIGILL/SIGABRT/SIGTRAP handler，
//  崩溃时把当前线程 backtrace 写到 ~/Library/Logs/SL_crash.log。
//  目的：用户 Xcode Run 崩溃时 LLDB 拦截不会落系统 .ips，导致崩溃堆栈丢失；
//  有了这个文件，下次崩溃后直接读 SL_crash.log 即可拿到调用栈定位。
//  同时注册 NSSetUncaughtExceptionHandler（Swift fatalError / ObjC 异常）写入同一文件。
//

import Foundation
import Darwin

enum CrashReporter {
    private static var installed = false
    private static let logPath = NSHomeDirectory() + "/Library/Logs/SL_crash.log"

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

    /// 崩溃日志落盘。**信号上下文**：整条调用链只允许 async-signal-safe 函数。
    ///
    /// 原实现与下方注释自相矛盾，三处"看起来无害"的东西全在信号路径里分配内存：
    ///  1. 字符串插值 `"signal: \(signal)"` → 触发 malloc；
    ///  2. `String(cString: strsignal(sig))` → 触发 malloc；
    ///  3. `ctime(&t)` → 既非可重入（返回指向共享静态缓冲区的指针），也不在 POSIX
    ///     async-signal-safe 名单内。
    /// 若崩溃点恰好落在 malloc 内部（堆损坏、越界写坏堆头是最常见的一类），
    /// 信号处理函数再调 malloc 会**自死锁**，结果是崩溃日志静默写不出来 ——
    /// 恰恰在最需要它的时刻失效，而且没有任何报错可供排查。
    /// 现改为：字面量走 `withCString`（静态存储，零分配）、整数手写 itoa 写进栈缓冲、
    /// `strsignal` 的 C 串直接 `write`、时间用 POSIX 明确列名的 `time` + `gmtime_r` 自行格式化。
    /// 依据：POSIX.1-2008 async-signal-safe 函数清单（`write` / `strlen` / `time` /
    /// `gmtime_r` 在列，`malloc` / `ctime` 不在列）。
    static func writeCrashLog(signal: Int32, extra: String?) {
        let fd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        writeStr(fd, "===== SL crash =====\nsignal: ")
        writeInt(fd, Int(signal))
        if let name = strsignal(signal) {
            writeStr(fd, " (")
            writeCStr(fd, name)
            writeStr(fd, ")")
        }
        var now = time(nil)
        var broken = tm()
        if gmtime_r(&now, &broken) != nil {
            writeStr(fd, "\ntime(UTC): ")
            writeTime(fd, broken)
        }
        writeStr(fd, "\n--- backtrace ---\n")

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

    /// 写出 Swift 字面量。字面量在静态存储中，`withCString` 只取指针、不做分配。
    private static func writeStr(_ fd: Int32, _ s: String) {
        s.withCString { c in
            _ = write(fd, c, strlen(c))
        }
    }

    /// 直接写出 C 串（不构造 Swift String，零分配）。用于 `strsignal` 的返回值。
    private static func writeCStr(_ fd: Int32, _ s: UnsafePointer<CChar>) {
        _ = write(fd, s, strlen(s))
    }

    /// async-signal-safe 的十进制整数写出：手写 itoa，缓冲区在栈上。
    private static func writeInt(_ fd: Int32, _ value: Int) {
        var digits = [CChar](repeating: 0, count: 24)
        var v = value
        let negative = v < 0
        if negative { v = -v }
        var cursor = digits.count
        repeat {
            cursor -= 1
            digits[cursor] = CChar(48 + v % 10)
            v /= 10
        } while v > 0
        if negative {
            cursor -= 1
            digits[cursor] = 45 // '-'
        }
        digits.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(fd, base + cursor, buf.count - cursor)
        }
    }

    /// 把 `tm` 写成 "YYYY-MM-DD HH:MM:SS"，全程操作栈缓冲，可重入且零分配。
    private static func writeTime(_ fd: Int32, _ broken: tm) {
        var out = [CChar](repeating: 0, count: 19)
        func put(_ value: Int, at position: Int, width: Int) {
            var v = value
            var p = position + width - 1
            for _ in 0..<width {
                out[p] = CChar(48 + v % 10)
                v /= 10
                p -= 1
            }
        }
        put(Int(broken.tm_year) + 1900, at: 0, width: 4)
        out[4] = 45  // '-'
        put(Int(broken.tm_mon) + 1, at: 5, width: 2)
        out[7] = 45  // '-'
        put(Int(broken.tm_mday), at: 8, width: 2)
        out[10] = 32 // ' '
        put(Int(broken.tm_hour), at: 11, width: 2)
        out[13] = 58 // ':'
        put(Int(broken.tm_min), at: 14, width: 2)
        out[16] = 58 // ':'
        put(Int(broken.tm_sec), at: 17, width: 2)
        out.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(fd, base, buf.count)
        }
    }
}
