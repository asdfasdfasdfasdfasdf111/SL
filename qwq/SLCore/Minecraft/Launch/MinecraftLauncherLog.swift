//
//  MinecraftLauncherLog.swift
//  SL启动器
//
//  游戏进程输出的落盘支撑（从 MinecraftLauncher.swift 逐字搬移，逻辑与文案未变）：
//  - LaunchCompletionGate：正常退出回调 / 轮询兜底 / run 抛错共享的一次性门控
//  - GameLogWriter：按行落盘缓冲（加锁，跨 readabilityHandler 与退出收尾共用）
//  - drainPipe：退出后排空管道残留字节
//
//  跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
//  与 .../extensions/）：`private` 仅对同一封闭声明及其同文件成员可见，扩展不能声明存储属性；
//  故拆分后 LaunchCompletionGate / GameLogWriter / drainPipe 由 private 放宽为 internal，
//  buildGameArguments 由 private 放宽为 internal（主文件 launch() 调用）。对外接口零变化。
//

import Foundation
import Darwin

final class LaunchCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return false }
        didComplete = true
        return true
    }
}

/// 游戏进程输出到日志文件的落盘缓冲。
///
/// 缓冲区被两处访问：进程运行期间的 `readabilityHandler`（FileHandle 私有串行队列）
/// 与进程退出后的收尾排空（启动线程），因此缓冲区与文件句柄访问统一加锁。
/// 锁内只做内存操作与文件写入，不回调外部、不等待其它锁，不存在死锁
/// （`raw()` 内部为异步投递，不会反向获取本锁）。
///
/// `handle` 允许为 nil（**丢弃模式**）：日志文件无法创建/打开时（磁盘满、目录无权限），
/// 调用方仍需继续读取管道——否则管道缓冲写满会让游戏进程阻塞——但不落盘任何内容。
/// 丢弃模式由 `MinecraftLauncher.launch` 的降级分支使用（缺陷：日志写不了却阻断整局启动）。
final class GameLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    /// 未满一行的行尾残留字节：跨回调保留，避免多字节 UTF-8 字符 / 长日志行被读取边界截断。
    private var buffer = Data()
    /// 句柄是否已关闭。关闭后到达的字节直接丢弃，
    /// 避免在途的 readabilityHandler 对已关闭句柄写入 / seek（后者会抛 ObjC 异常）。
    private var isClosed = false

    init(handle: FileHandle?) {
        self.handle = handle
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        // 丢弃模式：不留缓冲（无落盘目标，且缓冲会随游戏时长无限增长）
        guard handle != nil else { return }
        buffer.append(data)
        flushCompleteLines()
    }

    /// 关闭底层日志句柄。
    ///
    /// 调用前必须完成管道排空，否则残留字节无法落盘（排空顺序见 `drainPipe` 与调用方注释）。
    /// **关闭前先把行尾残字节落盘**：游戏最后一行输出常常没有换行符（如崩溃前的半行堆栈），
    /// 原实现只落「以 \n 结尾的完整行」，这些残字节会随 close() 一起丢掉——表现为日志尾部缺行，
    /// 而这恰恰是排查崩溃最需要的一段。此处补一次收尾刷写，并对文件做一次同步。
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        guard let handle else { return }
        if !buffer.isEmpty {
            let residual = buffer
            buffer.removeAll()
            if let line = String(data: residual, encoding: .utf8) {
                raw(line.replacingOccurrences(of: "\t", with: "    "))
                // 补换行，与其它行的落盘格式保持一致（读取方按 \n 切行）
                try? handle.write(contentsOf: (line + "\n").data(using: .utf8)!)
            } else {
                // 非法 UTF-8 残字节：原样落盘，不臆造内容（解码失败行本就按约定丢弃）
                try? handle.write(contentsOf: residual)
            }
        }
        // 同步到文件系统：避免进程即将退出 / 断电时缓冲区仍在页缓存中未回写
        try? handle.synchronize()
        try? handle.close()
    }

    /// 只落盘以 \n 结尾的完整行，行尾残字节留在缓冲区等待后续数据补齐。
    private func flushCompleteLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(0...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            raw(line.replacingOccurrences(of: "\t", with: "    "))
            try? handle?.write(contentsOf: (line + "\n").data(using: .utf8)!)
            handle?.seekToEndOfFile()
        }
    }
}

/// 排空管道中尚未被 `readabilityHandler` 取走的字节，交给 `writer` 按行落盘。
///
/// 顺序不变（排空 → 调用方置 `readabilityHandler = nil` → `writer.close()`）：
/// 依据 `FileHandle.readabilityHandler` 官方说明，置 nil 会取消 dispatch source 并清理句柄结构，
/// 故必须先排空再摘回调，否则仍滞留在内核管道缓冲的字节没有机会被读出（日志尾部缺行）。
///
/// **为什么必须加超时**：原实现假设「写端必然关闭 ⇒ 读端必然 EOF」。该假设只在
/// 管道写端仅由直接子进程持有时成立；一旦写端被**孙进程继承**（Java 拉起 crash handler、
/// Forge 早期窗口的独立子进程、游戏内 `Runtime.exec` 的派生进程等），直接子进程退出后
/// 写端仍被其它进程持有 → 读端永远等不到 EOF → 本函数在启动线程上永久阻塞
/// → `completion` 不触发、UI 永停「启动中」。
/// 因此改为「读到 EOF，或超过总时限即收尾返回」，并配合 `O_NONBLOCK` + `poll` 限时等待：
/// 置非阻塞是为了防止 `readabilityHandler` 在 poll 返回后抢走数据导致 `read` 再次无界阻塞。
func drainPipe(_ pipe: Pipe, into writer: GameLogWriter) {
    let handle = pipe.fileHandleForReading
    let fd = handle.fileDescriptor
    /// 排空总时限：正常退出时尾部数据量有限，3s 足够读完；超时说明写端被其它进程持有。
    let deadline = Date().addingTimeInterval(3)

    // 置非阻塞读：本函数结束后该管道即被释放，故无需在正常路径恢复标志位，
    // 但仍显式还原，避免调用方（或未来的复用点）观察到被改动的 fd 语义。
    let originalFlags = fcntl(fd, F_GETFL)
    if originalFlags >= 0 {
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
    }

    while Date() < deadline {
        let remainingMS = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard remainingMS > 0 else { break }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, remainingMS)
        if ready == 0 { break }                 // 超时：写端仍被持有，按有界收尾返回
        if ready < 0 {
            if errno == EINTR { continue }      // 被信号打断：重试，直到时限
            break
        }
        let events = pfd.revents
        if events & Int16(POLLIN) != 0 || events & Int16(POLLHUP) != 0 {
            do {
                let chunk = try handle.read(upToCount: 64 * 1024)
                guard let chunk, !chunk.isEmpty else { break }  // 空 Data = EOF
                writer.append(chunk)
            } catch {
                // EAGAIN：可读事件被 `readabilityHandler` 抢先消费，重试下一轮 poll
                continue
            }
        } else if events & Int16(POLLERR) != 0 {
            break
        } else {
            break
        }
    }

    if originalFlags >= 0 {
        _ = fcntl(fd, F_SETFL, originalFlags)
    }
}
