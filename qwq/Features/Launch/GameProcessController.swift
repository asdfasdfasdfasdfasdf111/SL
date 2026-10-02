//
//  GameProcessController.swift
//  启动用例层：游戏进程的拉起与终止
//
//  本文件只定义协议与最小进程封装，**不创建 Process**。
//  进程创建的既有约定（并发上限、超时、白名单）由 `SLCore/ProcessPool.swift` 承担：
//  ProcessPool 当前面向「短命令 + 收集输出」场景（同步 execute / executeForData），
//  游戏进程是长驻、输出走日志文件、需要 termination 观察，形态不同，
//  故此处仅声明 `GameProcessController` 协议，未来实现应在 ProcessPool 的并发与超时策略之上扩展，
//  而不是另起一套进程管理（见 README「未来复用 ProcessPool」）。
//

import Foundation

/// 已被拉起的游戏进程的最小封装（持有 Process + termination 观察入口）
public struct ManagedProcess: Sendable {

    public let process: Process

    public init(process: Process) {
        self.process = process
    }

    /// 进程 PID
    public var processIdentifier: Int32 { process.processIdentifier }

    /// 进程是否仍在运行
    public var isRunning: Bool { process.isRunning }

    /// 请求终止（SIGTERM），对应 `MinecraftLauncher.terminate()`
    public func terminate() {
        process.terminate()
    }
}

// MARK: - 进程退出观察的竞态结论（约束，禁止重犯）

/// 挂 `process.terminationHandler` 与检查 `process.isRunning` 之间存在竞态窗口——
/// 进程恰好在两步之间退出时 handler 永不回调、continuation 永不 resume（调用方永久挂起）。
/// 正确形态：**先挂 handler、再补检状态**，两条路径共用一次性门控，保证恰好 resume 一次。
/// （「为什么会有这个结论、删掉的是什么」见 `docs/ARCHAEOLOGY-NOTES.md`。）

/// 游戏进程控制器：把「参数 + 环境」变成可被跟踪的进程
public protocol GameProcessController: Sendable {
    /// - Parameters:
    ///   - executable: Java 可执行文件（`LaunchOptions.javaPath`）
    ///   - arguments: 完整参数（见 `LaunchArgumentBuilder`）
    ///   - environment: 环境变量（`MinecraftLauncher` 当前使用 `ProcessInfo.processInfo.environment`）
    func launch(executable: URL, arguments: [String], environment: [String: String]) async throws -> ManagedProcess
}
