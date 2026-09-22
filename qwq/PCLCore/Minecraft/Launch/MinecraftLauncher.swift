//
//  MinecraftLauncher.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/20.
//
//
//  一次启动的进程编排。本文件只保留实例状态与启动主流程：
//  - MinecraftLaunchOutcome：启动结局（进程未拉起 / 已运行后退出）
//  - MinecraftLauncher：实例与日志路径状态、launch（进程拉起、日志落盘接线、退出等待与收尾）
//  其余按职责拆分在同目录，逻辑、常量与文案均与原实现逐字一致（仅物理搬移）：
//  - MinecraftLauncherLog.swift        进程输出落盘（一次性门控、GameLogWriter、drainPipe）
//  - MinecraftLauncherArguments.swift  JVM / classpath / 游戏参数构建
//  - MinecraftLauncherDownload.swift   authlib-injector 与单文件下载入口
//
//  跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
//  与 .../extensions/）：`private` 仅对同一封闭声明及其同文件成员可见，扩展不能声明存储属性；
//  故拆分后 LaunchCompletionGate / GameLogWriter / drainPipe 由 private 放宽为 internal，
//  buildGameArguments 由 private 放宽为 internal（主文件 launch() 调用）。对外接口零变化。
//

import Foundation
import Cocoa
import Combine
import SwiftyJSON

/// 一次启动的最终结局。
///
/// 用于区分「进程未能拉起」与「进程已运行后退出」两类语义不同的结果：
/// 前者不存在真实退出码（原实现统一回传 1，导致与游戏崩溃退出表现完全一致），
/// 后者才携带进程的真实退出状态。
public enum MinecraftLaunchOutcome {
    /// 进程已成功拉起并退出，携带真实退出码。
    case exited(Int32)
    /// 进程未能拉起（如 `Process.run()` 抛错、可执行文件无效），携带底层错误。
    case launchFailed(Error)
}

public class MinecraftLauncher {
    public let instance: MinecraftInstance
    private let id = UUID()
    public let logURL: URL
    /// 本 launcher 自己启动的进程引用。不依赖 instance.process（后者会被同版本的其它 launcher 覆盖）。
    public private(set) var currentProcess: Process?
    
    public init?(_ instance: MinecraftInstance) {
        self.instance = instance
        self.logURL = SharedConstants.shared.applicationSupportURL.appendingPathComponent("GameLogs").appendingPathComponent(id.uuidString + ".log")
        // 目录 / 文件创建失败在此**不抛错也不报错**：日志写不了不应阻止游戏启动。
        // 失败会在 launch() 打开句柄时被发现，并按「无日志运行 + 提示用户」降级（见 launch 内注释）。
        try? FileManager.default.createDirectory(at: logURL.parent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        // 日志保留策略：日志文件在退出时不再删除（退出码 0 也保留，供日志面板与 LaunchResult.logURL 读取），
        // 改为在新建本次日志后按份数上限修剪历史文件（上限见 GameLogRetention.maxCount）。
        GameLogRetention.prune(in: logURL.parent())
    }
    
    public func launch(_ options: LaunchOptions, _ callback: @MainActor @escaping (MinecraftLaunchOutcome) -> Void = { _ in }) {
        let process = Process()
        process.executableURL = options.javaPath
        process.environment = ProcessInfo.processInfo.environment
        process.arguments = []
        process.arguments!.append(contentsOf: buildJvmArguments(options))
        process.arguments!.append(instance.manifest.mainClass)
        process.arguments!.append(contentsOf: buildGameArguments(options))
        let command = process.executableURL!.path + " " + process.arguments!.joined(separator: " ")
            .replacingOccurrences(of: #"--accessToken\s+\S+"#, with: "--accessToken 🎉", options: .regularExpression)
        debug(command)
        MinecraftCrashHandler.lastLaunchCommand = command
        process.currentDirectoryURL = instance.runningDirectory
        
        if instance.config.qualityOfService.rawValue == 0 {
            instance.config.qualityOfService = .default
        }
        process.qualityOfService = instance.config.qualityOfService
        
        instance.process = process
        self.currentProcess = process
        // 正常 terminationHandler、轮询兜底和 run() 抛错共享一次性门控，避免重复复位 UI。
        let terminationSemaphore = DispatchSemaphore(value: 0)
        let completionGate = LaunchCompletionGate()
        let reportCompletion: (MinecraftLaunchOutcome) -> Void = { outcome in
            guard completionGate.claim() else { return }
            DispatchQueue.main.async { callback(outcome) }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var logWriter: GameLogWriter?
        do {
            // MARK: 日志降级（缺陷：日志目录创建失败被 try? 吞掉 → 阻断整局启动）
            // `init` 里 `try? createDirectory` 的失败会在原先的 `try FileHandle(forWritingTo:)`
            // 处暴露成抛出，再经 catch 走 `.launchFailed`——用户看到「启动失败」，
            // 真实原因只是「日志写不了」，而游戏本身完全能跑。故此处降级为**无日志运行**：
            // 日志文件打不开就用丢弃模式的 writer，启动照常继续，仅提示用户。
            //
            // 仍然必须挂 readabilityHandler：即使不落盘也要持续读取管道，
            // 否则管道缓冲（OS 决定大小）写满后游戏进程自身会被阻塞；退出时的 drainPipe 亦照常执行。
            let writer: GameLogWriter
            if let logHandle = try? FileHandle(forWritingTo: logURL) {
                writer = GameLogWriter(handle: logHandle)
            } else {
                writer = GameLogWriter(handle: nil)
                warn("无法写入游戏日志 \(logURL.path)，本次启动不记录游戏日志（不影响游戏运行）")
                hint("无法写入游戏日志文件，本次启动将不记录游戏日志。请检查磁盘空间与目录权限。", .critical)
            }
            logWriter = writer
            // 管道字节可能含非法 UTF-8（Java/模组输出非 UTF-8 编码时不崩溃）；解码失败行丢弃。
            // 内容切行与落盘由 GameLogWriter 负责（内部加锁，与退出时的收尾排空共用同一缓冲区）。
            pipe.fileHandleForReading.readabilityHandler = { handle in
                writer.append(handle.availableData)
            }

            // terminationHandler 在 run() 之前设置（消除竞态）：若进程启动后立刻退出
            // （秒退/崩溃/手动关闭恰好在 run 之后），后置的 handler 可能永远不触发，
            // 导致启动器识别不到「游戏已关闭」。前置设置保证任何退出都能回调；
            // 回调经一次性门控（与下方轮询兜底互斥），只落一次到 UI。
            process.terminationHandler = { proc in
                terminationSemaphore.signal()
                reportCompletion(.exited(proc.terminationStatus))
            }

            try process.run()
            // 竞态收口：`terminate()` 可能在「进程对象已建立、`run()` 尚未执行」的窗口内被调用
            // （此时它只能置位 `isUserTerminated`，`currentProcess?.terminate()` 打不到尚未启动的进程）。
            // run() 之后补查该位：命中即立刻终止刚拉起的进程，避免用户已经点了关闭却仍留下孤儿进程。
            // 该位只会由 terminate() 置 true（每个 launcher 实例独立持有），不存在被误触发的路径。
            if isUserTerminated {
                log("启动期间已收到终止请求，立即终止刚拉起的进程")
                process.terminate()
            }
            Task { // 轮询判断窗口是否出现
                while process.isRunning {
                    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
                    guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                        throw NSError()
                    }

                    for info in windowInfoList {
                        if let windowPID = info["kCGWindowOwnerPID"] as? Int32,
                           windowPID == process.processIdentifier {
                            log("窗口已出现")
                            return
                        }
                    }
                    try await Task.sleep(nanoseconds: 1 * 1_000_000_000)
                }
            }

            // 等待进程退出（替代 process.waitUntilExit()，后者在 Java 死锁时可能无限阻塞）。
            // 带超时轮询兜底：terminationHandler 因任何原因未触发时，检测到进程不再运行
            // 就主动回调，确保「手动关闭/异常退出」的进程必然被识别并复位 UI。
            while terminationSemaphore.wait(timeout: .now() + 1) == .timedOut {
                if !process.isRunning {
                    log("兜底检测到进程已退出（terminationHandler 未触发）")
                    reportCompletion(.exited(process.terminationStatus))
                    break
                }
            }
            log("\(instance.name) 进程已退出, 退出代码 \(process.terminationStatus)")
            // 收尾顺序：先排空管道残留字节，再解除回调，最后关闭日志句柄。
            // 原实现先置 readabilityHandler = nil 再关句柄，管道内已到达但尚未被读取的字节
            // 会随之丢弃（表现为日志尾部缺行）；排空读到 EOF 即返回，不阻塞、不死锁。
            drainPipe(pipe, into: writer)
            // 解除回调（否则闭包持有 writer，每次启动泄漏）
            pipe.fileHandleForReading.readabilityHandler = nil
            writer.close()
            // 日志文件一律保留（含退出码 0）：会话日志面板与 LaunchResult.logURL 都指向它，
            // 提前删除会导致用户点开日志时内容为空。目录容量由 GameLogRetention 按份数上限维护。
            // 归属校验：回调已异步提交主队列，旧 launch 线程可能晚于「回调内快速重启新游戏」执行到这里，
            // 无条件置 nil 会清掉新启动进程的引用。仅当引用仍是本进程时才清理（崩溃 #4 教训）。
            if instance.process === process {
                instance.process = nil
            }
        } catch {
            err(error.localizedDescription)
            pipe.fileHandleForReading.readabilityHandler = nil
            logWriter?.close()
            // 启动失败同样走一次性门控回调（结局为 .launchFailed），UI 才能复位「启动中」状态并
            // 展示真实失败原因；terminationHandler 在 run() 前已设置，若 run 抛错则其绝不会触发。
            if instance.process === process {
                instance.process = nil
            }
            if self.currentProcess === process {
                self.currentProcess = nil
            }
            reportCompletion(.launchFailed(error))
        }
    }
}
