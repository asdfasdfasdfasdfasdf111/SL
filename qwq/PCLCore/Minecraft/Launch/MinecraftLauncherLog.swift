//
//  MinecraftLauncherLog.swift
//  PCL.Mac
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
final class GameLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    /// 未满一行的行尾残留字节：跨回调保留，避免多字节 UTF-8 字符 / 长日志行被读取边界截断。
    private var buffer = Data()
    /// 句柄是否已关闭。关闭后到达的字节直接丢弃，
    /// 避免在途的 readabilityHandler 对已关闭句柄写入 / seek（后者会抛 ObjC 异常）。
    private var isClosed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        buffer.append(data)
        flushCompleteLines()
    }

    /// 关闭底层日志句柄。调用前必须完成管道排空，否则残留字节无法落盘。
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    /// 只落盘以 \n 结尾的完整行，行尾残字节留在缓冲区等待后续数据补齐。
    private func flushCompleteLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(0...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            raw(line.replacingOccurrences(of: "\t", with: "    "))
            try? handle.write(contentsOf: (line + "\n").data(using: .utf8)!)
            handle.seekToEndOfFile()
        }
    }
}

/// 排空管道中尚未被 `readabilityHandler` 取走的字节，交给 `writer` 按行落盘。
///
/// 循环读取直到读到空数据。进程退出时管道写端已全部关闭（子进程已退出，
/// 父进程持有的写端由 Foundation 在 `Process.run()` 期间关闭，已实测），
/// 故读端必然到达 EOF，读取不会阻塞，不存在死锁。
func drainPipe(_ pipe: Pipe, into writer: GameLogWriter) {
    let handle = pipe.fileHandleForReading
    while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        writer.append(chunk)
    }
}
