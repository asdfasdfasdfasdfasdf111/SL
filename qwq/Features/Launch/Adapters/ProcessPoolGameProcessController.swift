//
//  ProcessPoolGameProcessController.swift
//  启动用例层适配器：`GameProcessController` 的进程池实现
//
//  委托关系：进程池取 `AppContext.shared.processPool`（全应用唯一实例，
//  与 `JavaDiscovery` / `VersionUtils` / `SkinExtractor` 等共用同一并发上限），
//  **不新建 ProcessPool 实例，不新建第二套进程管理**。
//
//  MARK: - 为什么长驻进程仍然直连 Process（本阶段被允许的唯一直连点）
//
//  `ProcessPool` 现有两个入口（`execute` / `executeForData`）都是
//  「同步执行短命令 → 阻塞等待退出 → 返回 stdout」，且内部会 `semaphore.wait()` 占满并发额度。
//  游戏进程是长驻进程（可运行数小时），且输出走日志文件、需要 termination 观察，
//  形态与池内两个入口完全不兼容；而池内承载策略的三个成员
//  （`maxConcurrent` / `semaphore` / `allowedCommands`）均为 private，
//  在不修改 `ProcessPool` 的前提下无法从外部把长驻进程纳入池。
//
//  因此本适配器的边界是：
//    - 可用池完成的部分 → 全部走池（见 `probeExecutable`，复用池的白名单 / 超时 / 并发策略）；
//    - 长驻进程本身 → 直连 `Process()`，并在此处显式标注为待迁移点。
//
//  合并阶段需要 `ProcessPool` 新增的长驻入口（建议签名，供后续实现参考）：
//      func launchLongRunning(_ executable: URL, args: [String],
//                             environment: [String: String],
//                             stdout: FileHandle?) throws -> Process
//  该入口内部复用同一 `semaphore` 与白名单判定，才能真正做到「长驻进程也归池管」。
//
//  MARK: - 与 GameProcessController 协议的缺口（合并前必须补齐）
//
//  1) **工作目录**：现有 `MinecraftLauncher.launch` 设置
//     `process.currentDirectoryURL = instance.runningDirectory`，游戏读 options.txt、
//     写 crash-report 等都依赖该目录；协议参数内没有工作目录，本适配器无法补齐。
//  2) **输出去向**：现有实现用 Pipe + readabilityHandler 把输出落盘到
//     `GameLogs/<uuid>.log` 并经 `LogStore.raw()` 双写；协议同样没有输出句柄。
//     本适配器自行落盘（见下），避免 Pipe 无人读取导致写满 64KB 后游戏阻塞。
//  3) 环境变量：调用方需传 `ProcessInfo.processInfo.environment`（与现有实现一致）；
//     传空字典会让游戏缺少 HOME / PATH。
//
//  MARK: - 与现有日志管线的差异（合并阶段需二选一）
//
//  现有 `MinecraftLauncher.launch` 走「Pipe + readabilityHandler 按行转发」，
//  退出时先置 `readabilityHandler = nil` 再关闭句柄，管道内残留数据存在丢失窗口。
//  本适配器改为把 `standardOutput` / `standardError` 直接绑到文件句柄：
//  进程输出由内核直写日志文件，无中间管道、无 reader、无 flush 时序依赖，退出后内容完整。
//  代价是失去「按行转发到 LogStore」的能力，因此日志文件路径通过
//  `logURL(forProcessIdentifier:)` 暴露，供后续会话层订阅。
//
//  说明：本文件当前无调用方，上述差异不会改变任何现有启动行为。
//

import Foundation
import os

/// 全库无引用，待清理（含 `qwqTests`）：全库没有任何 `ProcessPoolGameProcessController(...)`
/// 构造点，启动路径仍走 `MinecraftLauncher.launch`；因此本适配器描述的那条「长驻进程归池管」路径从未执行。
/// 保留原因：文件头的协议缺口分析（工作目录 / 输出句柄 / 环境变量）与「直接绑定文件句柄不丢尾部日志」
/// 的替代方案，是合并阶段必须复用的结论，删除会丢失依据。
@available(*, deprecated, message: "全库无引用，待清理")
final class ProcessPoolGameProcessController: GameProcessController, @unchecked Sendable {

    /// 进程池（默认复用应用级单例）
    private let pool: ProcessPool
    /// 日志目录，与 `MinecraftLauncher` 使用同一约定（AppSupport/GameLogs/<uuid>.log）
    private let logDirectory: URL

    /// PID → 该进程的日志文件路径（供会话层读取日志）。
    /// 用作用域锁保护，避免 NSLock 在 async 上下文中的不可用告警。
    private let logURLs = OSAllocatedUnfairLock<[Int32: URL]>(initialState: [:])

    init(pool: ProcessPool = AppContext.shared.processPool) {
        self.pool = pool
        self.logDirectory = SharedConstants.shared.applicationSupportURL.appendingPathComponent("GameLogs")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    /// 查询某个已拉起进程的日志文件路径；未登记时返回 nil。
    func logURL(forProcessIdentifier pid: Int32) -> URL? {
        logURLs.withLock { $0[pid] }
    }

    func launch(executable: URL, arguments: [String], environment: [String: String]) async throws -> ManagedProcess {
        // 1) 启动前可执行性探测（复用进程池的策略，失败仅告警）
        await probeExecutable(executable)

        // 2) 长驻进程（协议缺口见文件头：无工作目录、无输出句柄参数）
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let logURL = makeLogFileURL()
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            throw LaunchError.processStartFailed(reason: "无法创建游戏日志文件：\(logURL.path)")
        }
        // 直接落盘：避免 Pipe 无人读取写满缓冲导致游戏阻塞；句柄由 Process 持有，进程释放时关闭
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            // 注意：terminationHandler 的挂载由 ManagedProcess.waitForTermination 负责，
            // 与 MinecraftLauncher「run() 之前挂 handler」的做法相比存在窄竞态，
            // 合并阶段建议把观察点前移到 run() 之前（见 GameProcessController.swift 注释）。
            try process.run()
        } catch {
            try? logHandle.close()
            throw LaunchError.processStartFailed(reason: "\(executable.path)：\(error.localizedDescription)")
        }

        logURLs.withLock { $0[process.processIdentifier] = logURL }
        log("[GameProcess] 已拉起进程 pid=\(process.processIdentifier)，日志: \(logURL.path)")

        return ManagedProcess(process: process)
    }

    // MARK: - 私有

    /// 复用进程池执行一次 `java -version` 探测。
    ///
    /// 现有链路判断 Java 可用性只依赖两件事：读 `release` 文件得到主版本号、
    /// 读 Mach-O 头得到架构；两者都不能证明该可执行文件在本机能真正运行
    /// （典型失败：架构不匹配且未启用 Rosetta、二进制被截断、动态库缺失）。
    /// 本探测补上这一诊断，且**只诊断不阻断**：
    /// 池白名单未覆盖的合法 Java 路径（如 /Applications 下）会探测失败，
    /// 若据此中止启动会引入新的失败路径，故一律降级为告警。
    private func probeExecutable(_ executable: URL) async {
        let output: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // 池的 execute 为同步阻塞调用，放到全局队列执行，避免占用 Swift 并发协作线程
            DispatchQueue.global(qos: .utility).async { [self] in
                let result = pool.execute(
                    executable.path,
                    args: ["-version"],
                    timeout: 5,
                    captureStderr: true
                )
                continuation.resume(returning: result)
            }
        }

        if let output, !output.isEmpty {
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
            log("[ProcessPool] Java 可执行性探测通过: \(executable.path) → \(firstLine)")
        } else {
            warn("[ProcessPool] Java 可执行性探测未通过（已降级为告警，继续拉起进程）: \(executable.path)")
        }
    }

    private func makeLogFileURL() -> URL {
        logDirectory.appendingPathComponent(UUID().uuidString + ".log")
    }
}
