//
//  GameProcessController.swift
//  启动用例层：游戏进程的拉起与终止
//
//  本文件只定义协议与最小进程封装，**不创建 Process**。
//  进程创建的既有约定（并发上限、超时、白名单）由 `Features/Launch/ProcessPool.swift` 承担：
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

    /// 等待进程退出并返回退出码。
    ///
    /// 注意：实现先判断 `isRunning` 再挂 handler，理论上存在「判断后即刻退出」的窄窗口竞态；
    /// 接线阶段若需覆盖该窗口，应由实现方在 `Process.run()` 之后立即建立观察。
    public func waitForTermination() async -> Int32 {
        if !process.isRunning {
            return process.terminationStatus
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }
    }
}

/// 游戏进程控制器：把「参数 + 环境」变成可被跟踪的进程
public protocol GameProcessController: Sendable {
    /// - Parameters:
    ///   - executable: Java 可执行文件（`LaunchOptions.javaPath`）
    ///   - arguments: 完整参数（见 `LaunchArgumentBuilder`）
    ///   - environment: 环境变量（`MinecraftLauncher` 当前使用 `ProcessInfo.processInfo.environment`）
    func launch(executable: URL, arguments: [String], environment: [String: String]) async throws -> ManagedProcess
}
