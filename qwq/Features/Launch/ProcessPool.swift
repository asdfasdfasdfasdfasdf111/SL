import Foundation

// MARK: - 进程池（防止并发进程风暴，统一超时控制）

//
// ⚠️ 并发使用约定（关键）
// 本类的 `execute` / `executeForData` 是【同步阻塞】调用（内部 `semaphore.wait`，默认最长 10 秒）。
// 禁止在主线程 / async 上下文中直接调用；调用方必须自行将调用置于后台队列或 `Task.detached`，
// 否则会卡住主线程（冷启动、UI 响应等）。
// 说明（为什么不给它加 `nonisolated`）：
// 本类成员全是 `let` 或 `DispatchSemaphore`，本可标 `nonisolated`；但那【不解决】阻塞问题 ——
// 同步函数在哪个线程调用就在哪个线程等待，标 `nonisolated` 只会让调用点失去编译器的
// 主线程提醒。要真正消除卡顿，必须由调用方把调用移到后台（`Task.detached` / 后台队列）。
// 因此这里保持默认隔离，等调用点改造时一并处理。
//

/// 替代各处直接创建 Process 的做法，提供：
/// - 最大并发数限制（防止进程风暴耗尽系统资源）
/// - 统一超时控制（默认 10s）
/// - 管道死锁防护（先读后等）
/// - 命令白名单校验
final class ProcessPool {
    private let maxConcurrent: Int
    private let semaphore: DispatchSemaphore
    private let queue = DispatchQueue(label: "qwq.processpool", qos: .userInitiated)

    /// 允许执行的命令白名单
    private static let allowedCommands: Set<String> = [
        "/usr/bin/unzip", "/usr/bin/zip", "/usr/bin/tar",
        "/usr/libexec/java_home", "/usr/bin/java", "/usr/bin/find",
        "/usr/bin/installer"
    ]

    init(maxConcurrent: Int = 3) {
        self.maxConcurrent = maxConcurrent
        self.semaphore = DispatchSemaphore(value: maxConcurrent)
    }

    /// 同步执行命令，返回 stdout 内容
    /// - Parameters:
    ///   - command: 命令绝对路径
    ///   - args: 参数列表
    ///   - timeout: 超时时间（秒），默认 10
    ///   - captureStderr: 是否将 stderr 合并到输出
    /// - Returns: stdout 字符串，失败返回 nil
    func execute(
        _ command: String,
        args: [String],
        timeout: TimeInterval = 10,
        captureStderr: Bool = false,
        currentDirectory: URL? = nil
    ) -> String? {
        // 命令白名单校验
        guard ProcessPool.allowedCommands.contains(command) ||
              command.hasPrefix("/usr/bin/") ||
              command.hasPrefix("/bin/") ||
              command.hasPrefix("/Library/") ||
              command.hasPrefix("/opt/") ||
              command.hasPrefix(NSHomeDirectory()) else {
            debug("[ProcessPool] 拒绝执行非白名单命令: \(command)")
            return nil
        }

        semaphore.wait()
        defer { semaphore.signal() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        if let dir = currentDirectory { process.currentDirectoryURL = dir }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = captureStderr ? stdoutPipe : stderrPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // 先起读，再等进程退出（顺序不可反：否则 64KB 管道缓冲写满会死锁）。
        // 读放在后台队列；读完成后再用 drain 信号量同步，确保消费者读到【完整】数据。
        // 关键点：terminationHandler 的 sem.signal() 与后台队列对 stdoutData 的【赋值】之间
        // 无 happens-before 关系，必须先等进程退出、再等读完成，才能安全使用 stdoutData。
        let sem = DispatchSemaphore(value: 0)
        let drain = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        var stdoutData = Data()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drain.signal()
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        drain.wait()  // 进程已退出 ⇒ 管道必到 EOF ⇒ 读必完成，此处不会长时间阻塞

        guard process.terminationStatus == 0 || captureStderr else { return nil }
        return String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 异步执行命令
    func executeAsync(
        _ command: String,
        args: [String],
        timeout: TimeInterval = 10,
        completion: @escaping (String?) -> Void
    ) {
        queue.async { [weak self] in
            let result = self?.execute(command, args: args, timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 同步执行命令并返回原始 Data（用于读取 JAR 内容）
    func executeForData(
        _ command: String,
        args: [String],
        timeout: TimeInterval = 10
    ) -> Data? {
        guard ProcessPool.allowedCommands.contains(command) ||
              command.hasPrefix("/usr/bin/") else { return nil }

        semaphore.wait()
        defer { semaphore.signal() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let sem = DispatchSemaphore(value: 0)
        let drain = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        var data = Data()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drain.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        drain.wait()  // 进程已退出 ⇒ 读必完成，再安全使用 data
        return data.isEmpty ? nil : data
    }
}