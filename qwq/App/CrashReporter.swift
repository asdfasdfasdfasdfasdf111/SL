//
//  CrashReporter.swift
//  崩溃自捕获：挂 SIGSEGV/SIGBUS/SIGILL/SIGABRT/SIGTRAP handler，
//  崩溃时把当前线程 backtrace 写到 ~/Library/Logs/SL_crash.log。
//  目的：用户 Xcode Run 崩溃时 LLDB 拦截不会落系统 .ips，导致崩溃堆栈丢失；
//  有了这个文件，下次崩溃后直接读 SL_crash.log 即可拿到调用栈定位。
//  同时注册 NSSetUncaughtExceptionHandler（Swift fatalError / ObjC 异常）写入同一文件。
//
//  ⚠️ 上游对照（2026-09-24 核查，结论：本文件**没有**上游可抄）：
//   - PCL.Mac（CeciliaStudio/PCL.Mac）：没有对应实现，只有「按需导出错误报告」
//     （打包启动器日志 + 游戏输出 + 崩溃报告）。启动器自身崩溃由独立仓库 PCL.Mac.Daemon 兜。
//   - PCL2 原版（Meloong-Git/PCL，VB.NET）：也没有信号处理器（.NET 做不到），
//     它走 Application_DispatcherUnhandledException → Logger.Error(…, LogBehavior.AlertThenCrash)。
//  也就是说「装信号处理器、在信号里写崩溃栈」是本地自造的，既然要做，就得自己保证信号安全。
//

import Foundation
import Darwin

enum CrashReporter {
    private static var installed = false

    /// 日志路径：安装期一次性 `strdup` 成 C 串。
    /// 信号路径里**绝不能**出现 Swift String —— 哪怕只是把 String 传给 `open`，
    /// 也有一次 String→C 串的桥接，可能触发分配（`open` 收的是 `UnsafePointer<CChar>`）。
    private static var logPathC: UnsafeMutablePointer<CChar>?

    static func install() {
        guard !installed else { return }
        installed = true

        logPathC = strdup(NSHomeDirectory() + "/Library/Logs/SL_crash.log")

        let sigs: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP]
        for sig in sigs {
            signal(sig) { s in CrashReporter.handleSignal(s) }
        }
        NSSetUncaughtExceptionHandler { ex in CrashReporter.handleUncaughtException(ex) }
    }

    // MARK: - 信号路径（只允许 async-signal-safe 调用，且零堆分配）

    /// 信号处理器本体：写日志 → 恢复默认处理 → 重新抛出信号。
    private static func handleSignal(_ sig: Int32) {
        writeCrashLog(signal: sig, extraC: nil)
        // 恢复默认行为让系统按常规方式终止进程（也能生成标准 .ips / 系统崩溃报告）
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// 崩溃日志落盘。**信号上下文**：只使用 async-signal-safe 调用，且**不做任何堆分配**。
    ///
    /// 历史账（2026-09-24 复审 8dfebf8 那轮「修复」）：那轮去掉了字符串插值与 `ctime`，
    /// 但**没去干净**，信号路径里还剩 4 处分配：
    ///  1. `open(logPath, …)`：`logPath` 是 Swift String，传参要走一次到 C 串的桥接；
    ///  2. `[CChar](repeating: 0, count: 24)`（itoa 缓冲）—— Swift Array 一律堆分配；
    ///  3. `[CChar](repeating: 0, count: 19)`（时间缓冲）—— 同上；
    ///  4. `[UnsafeMutableRawPointer?](repeating: nil, count: 128)` —— 同上（约 1 KiB）。
    /// 另外 `strsignal` 也**不在** macOS 的 async-signal-safe 清单里
    /// （`man 2 sigaction` 的 Base / Realtime / ANSI C / Extension 四段都没有它），已换成静态字面量表。
    ///
    /// 危害：崩溃点若恰好落在 malloc 内部（堆损坏、越界写坏堆头是最常见的一类），
    /// 信号处理器再调 malloc 会**自死锁**，结果是崩溃日志静默写不出来 ——
    /// 恰恰在最需要它的时刻失效，而且没有任何报错可供排查。
    ///
    /// 现改为：路径在安装期 `strdup`，三个缓冲全部走 `withUnsafeTemporaryAllocation`（栈上）。
    /// 依据：POSIX.1-2008 async-signal-safe 清单（`write` / `strlen` / `time` / `gmtime_r` /
    /// `open` / `close` / `raise` / `signal` 在列；`malloc` / `ctime` / `strsignal` 不在列）。
    private static func writeCrashLog(signal sig: Int32, extraC: UnsafePointer<CChar>?) {
        guard let path = logPathC else { return }
        let savedErrno = errno
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { errno = savedErrno; return }
        defer {
            close(fd)
            // 信号处理器不该污染调用方看到的 errno（man 2 sigaction 的告诫）
            errno = savedErrno
        }

        writeLiteral(fd, "===== SL crash =====\nsignal: ")
        writeInt(fd, Int(sig))
        writeSignalName(fd, sig)
        var now = time(nil)
        var broken = tm()
        if gmtime_r(&now, &broken) != nil {
            writeLiteral(fd, "\ntime(UTC): ")
            writeTime(fd, broken)
        }
        writeLiteral(fd, "\n--- backtrace ---\n")

        // `backtrace_symbols_fd` 官方说明它不做 malloc（直接写 fd）；macOS 的 `backtrace`
        // 也只是把栈指针填进我们给的缓冲。两者严格说也不在 POSIX 清单内 —— 但不取栈就没意义，
        // 且它们不像 malloc 那样可能撞上「崩溃点正持有的同一把锁」。此处只保证**我们自己**不分配。
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 128) { buf in
            guard let base = buf.baseAddress else { return }
            let frames = backtrace(base, Int32(buf.count))
            backtrace_symbols_fd(base, frames, fd)
        }

        if let extraC {
            writeLiteral(fd, "\n--- extra ---\n")
            writeCStr(fd, extraC)
        }
        writeLiteral(fd, "\n===== end =====\n")
    }

    /// 写出 Swift **字面量**。字面量在静态存储中，`withCString` 只取指针、不做分配。
    /// ⚠️ 只允许传字面量 —— 传拼接出来的 String 就会在信号路径里分配。
    private static func writeLiteral(_ fd: Int32, _ literal: String) {
        literal.withCString { c in
            _ = write(fd, c, strlen(c))
        }
    }

    /// 直接写出调用方备好的 C 串（不构造 Swift String，零分配）。
    private static func writeCStr(_ fd: Int32, _ s: UnsafePointer<CChar>) {
        _ = write(fd, s, strlen(s))
    }

    /// 信号名后缀，全是静态存储的字面量，零分配、可重入。
    ///
    /// 不用 `strsignal`：① 它不在 macOS 的 async-signal-safe 清单里；② 它的返回值本来就带编号
    /// （`strsignal(11)` = "Segmentation fault: 11"），跟前面的 `signal: 11` 重复得很难看。
    private static func writeSignalName(_ fd: Int32, _ sig: Int32) {
        if sig == SIGSEGV {
            writeLiteral(fd, " (SIGSEGV: segmentation fault)")
        } else if sig == SIGBUS {
            writeLiteral(fd, " (SIGBUS: bus error)")
        } else if sig == SIGILL {
            writeLiteral(fd, " (SIGILL: illegal instruction)")
        } else if sig == SIGABRT {
            writeLiteral(fd, " (SIGABRT: abort)")
        } else if sig == SIGTRAP {
            writeLiteral(fd, " (SIGTRAP: trace trap)")
        }
    }

    /// async-signal-safe 的十进制整数写出：手写 itoa，缓冲区在栈上。
    private static func writeInt(_ fd: Int32, _ value: Int) {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 24) { buf in
            guard let base = buf.baseAddress else { return }
            var v = value
            let negative = v < 0
            if negative { v = -v }
            var cursor = buf.count
            repeat {
                cursor -= 1
                base[cursor] = CChar(48 + v % 10)
                v /= 10
            } while v > 0
            if negative {
                cursor -= 1
                base[cursor] = 45 // '-'
            }
            _ = write(fd, base + cursor, buf.count - cursor)
        }
    }

    /// 把 `tm` 写成 "YYYY-MM-DD HH:MM:SS"，全程操作栈缓冲，可重入且零分配。
    private static func writeTime(_ fd: Int32, _ broken: tm) {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 19) { buf in
            guard let base = buf.baseAddress else { return }
            func put(_ value: Int, at position: Int, width: Int) {
                var v = value
                var p = position + width - 1
                for _ in 0..<width {
                    base[p] = CChar(48 + v % 10)
                    v /= 10
                    p -= 1
                }
            }
            put(Int(broken.tm_year) + 1900, at: 0, width: 4)
            base[4] = 45  // '-'
            put(Int(broken.tm_mon) + 1, at: 5, width: 2)
            base[7] = 45  // '-'
            put(Int(broken.tm_mday), at: 8, width: 2)
            base[10] = 32 // ' '
            put(Int(broken.tm_hour), at: 11, width: 2)
            base[13] = 58 // ':'
            put(Int(broken.tm_min), at: 14, width: 2)
            base[16] = 58 // ':'
            put(Int(broken.tm_sec), at: 17, width: 2)
            _ = write(fd, base, buf.count)
        }
    }

    // MARK: - 非信号路径

    /// Swift `fatalError` / ObjC 异常。**不是信号上下文**，可以正常分配、正常拼字符串。
    private static func handleUncaughtException(_ ex: NSException) {
        let extra = "NSException: \(ex.name.rawValue)\n\(ex.reason ?? "")\n\(ex.callStackSymbols.joined(separator: "\n"))"
        if let c = strdup(extra) {
            writeCrashLog(signal: 0, extraC: c)
            free(c)
        }
    }
}
