//
//  RealLaunchIntegrationTests.swift
//  qwqTests
//
//  真实启动集成用例（**会真的拉起一个 Minecraft 进程并打开游戏窗口**）。
//
//  为什么必须有这一条：
//  其余全部单元测试都停在「纯值类型 / 纯协议 / 可注入桩」的层面，而本轮改动里风险最高的
//  几处恰恰只在真实链路上才暴露——natives 架构选择（arm64 vs x64）、Java 解析与版本门槛、
//  classpath 去重与排序、进程生命周期与退出码。这些用桩测不出「对」，只能用一次真机启动证伪。
//
//  默认跳过（见 `isEnabled`）：跑一次要拉起真实 JVM、占内存、弹窗口、最长数分钟，
//  把它塞进日常 `verify-test.sh` 会让每次单测都变成一次游戏启动。显式打开标记文件后才执行，
//  用法见 `qwqTests/TESTING.md` 的「真实启动」一节。
//
//  判定口径（也是「启动链路健康」的可证据清单）：
//   1. `launcher` 引用就绪 → 实例可创建、客户端 JAR 非空、Java 已解析成功；
//   2. 收到 `.running` → 游戏窗口被 CGWindowList 观测到，进程真的活到了出窗口；
//   3. 日志里不出现 `UnsatisfiedLinkError` / `NoClassDefFoundError` /
//      `Could not find or load main class` → natives 架构与 classpath 正确；
//   4. 退出码不强求 0：本用例自己 `terminate()` 收尾，被杀进程的退出码本就非 0。
//

import XCTest
@testable import qwq

final class RealLaunchIntegrationTests: XCTestCase {

    /// 真实启动开关：标记文件存在才跑。
    /// 不用环境变量，是因为 `xcodebuild test` 不会把调用方的 shell 环境带进宿主进程，
    /// 而标记文件对「人手动 touch 一下再跑」和「脚本里 touch / rm」同样方便。
    private static let flagURL = URL(fileURLWithPath: "/tmp/sl-real-launch.enabled")

    private static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    /// 与 `LauncherSettings` 当前持久化取值一致（`selectedGameRoot` / `selectedMinecraftVersion`）。
    /// 刻意硬编码而不读 LauncherSettings：真实启动用例要能脱离 App 状态独立复现，
    /// 取值一旦被 UI 改动，用例应当**失败并提示**，而不是悄悄换个版本再跑。
    private static let gameRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/minecraft")
    private static let version = "26.2-Fabric"
    private static let username = "Player"

    func testLaunchRealMinecraftVersion() async throws {
        try XCTSkipUnless(
            Self.isEnabled,
            "真实启动已跳过：需要 \(Self.flagURL.path)（touch 后重跑，或按 TESTING.md 的命令执行）"
        )

        let clientJAR = Self.gameRoot
            .appendingPathComponent("versions")
            .appendingPathComponent(Self.version)
            .appendingPathComponent("\(Self.version).jar")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: clientJAR.path),
            "前置条件不满足：客户端 JAR 不存在 \(clientJAR.path)（本用例只验证启动链路，不负责下载）"
        )

        let probe = LaunchProbe()
        let service = MinecraftInstanceLaunchService(events: { event in
            switch event {
            case .log(let line):
                probe.appendLog(line)
            case .launcherReady(let launcher):
                probe.markLauncherReady(launcher)
            case .running:
                probe.markRunning()
            case .failed(let error):
                probe.markFailure(error)
            case .finished(let result):
                probe.markFinished(exitCode: result.exitCode)
            case .progress, .phase:
                break
            }
        })

        let request = LaunchRequest(
            version: Self.version,
            gameRoot: Self.gameRoot,
            offlineUsername: Self.username
        )

        // 启动本身是 async 的，但会一直挂到进程退出（游戏可以开很久），
        // 故放进独立 Task，主测试体只负责观测与收尾。
        let launchTask = Task { [service] in
            try await service.launch(request)
        }

        let reachedRunning = await waitUntil(timeout: 300) {
            probe.isRunning || probe.failure != nil
        }

        // 先把判定所需的材料全部取出，再收尾：terminate 之后日志仍在增长，断言对象必须固定
        let failureDescription = probe.failure?.localizedDescription
        let capturedLogs = probe.logs
        let launcherReady = probe.hasLauncher

        // 收尾：无论成败都终止进程，避免用例失败时留下一个孤儿游戏进程占着内存与端口
        probe.terminateGameProcess()
        _ = try? await launchTask.value

        if let failureDescription {
            XCTFail("启动失败（未拉起进程）：\(failureDescription)\n--- 日志尾部 ---\n\(tail(capturedLogs))")
            return
        }

        XCTAssertTrue(launcherReady, "未收到 launcher 就绪事件：实例创建 / 客户端 JAR 校验 / Java 解析阶段已失败")
        XCTAssertTrue(reachedRunning, "300s 内未观测到游戏窗口（.running 未到达）\n--- 日志尾部 ---\n\(tail(capturedLogs))")

        // natives 架构与 classpath 的硬证据：这三条错误各自对应一类启动期崩溃，
        // 出现任意一条都说明「进程活着但游戏起不来」，不能算通过。
        for marker in ["UnsatisfiedLinkError", "NoClassDefFoundError", "Could not find or load main class"] {
            XCTAssertFalse(
                capturedLogs.contains(where: { $0.contains(marker) }),
                "游戏日志出现 \(marker)，说明 natives 架构或 classpath 有误\n--- 日志尾部 ---\n\(tail(capturedLogs))"
            )
        }

        // 软证据：只记录不判定。LWJGL 的行文案随版本变化，硬断言容易变成噪音
        let lwjglLines = capturedLogs.filter { $0.contains("LWJGL") || $0.contains("arm64") }
        XCTAssertFalse(capturedLogs.isEmpty, "日志通道一行未收到：logHandler 未接到游戏输出")
        print("[RealLaunch] 捕获日志 \(capturedLogs.count) 行；arch/LWJGL 相关 \(lwjglLines.count) 行")
        for line in lwjglLines.prefix(5) { print("[RealLaunch] \(line)") }
    }

    // MARK: - 辅助

    private func tail(_ lines: [String], limit: Int = 25) -> String {
        lines.suffix(limit).joined(separator: "\n")
    }

    /// 轮询等待（不阻塞主线程）：`wait(for:timeout:)` 会占住主线程数分钟，
    /// 而宿主 App 的主线程还要跑 SwiftUI 与 CGWindowList 观测。
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }
}

// MARK: - 事件探针

/// 事件探针：`LaunchEvent` 从多个后台线程投递（进度 / 日志 / completion 各在其原调用点），
/// 故全部读写走同一把锁；测试末尾会把结果整体取出后断言，避免与 terminate 收尾竞态。
private final class LaunchProbe: @unchecked Sendable {

    private let lock = NSLock()
    private var _logs: [String] = []
    private var _launcher: MinecraftLauncher?
    private var _isRunning = false
    private var _failure: Error?
    private var _exitCode: Int?

    var logs: [String] { lock.lock(); defer { lock.unlock() }; return _logs }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _isRunning }
    var hasLauncher: Bool { lock.lock(); defer { lock.unlock() }; return _launcher != nil }
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return _failure }
    var exitCode: Int? { lock.lock(); defer { lock.unlock() }; return _exitCode }

    func appendLog(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _logs.append(line)
    }

    func markLauncherReady(_ launcher: MinecraftLauncher) {
        lock.lock(); defer { lock.unlock() }
        _launcher = launcher
    }

    func markRunning() {
        lock.lock(); defer { lock.unlock() }
        _isRunning = true
    }

    func markFailure(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _failure = error
    }

    func markFinished(exitCode: Int) {
        lock.lock(); defer { lock.unlock() }
        _exitCode = exitCode
    }

    /// 终止游戏进程（`MinecraftLauncher.terminate()` 会同时置 `isUserTerminated`，
    /// 与 UI 的关闭按钮走同一条路径）
    func terminateGameProcess() {
        lock.lock()
        let launcher = _launcher
        lock.unlock()
        launcher?.terminate()
    }
}
