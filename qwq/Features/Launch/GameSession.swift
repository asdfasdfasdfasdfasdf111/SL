//
//  GameSession.swift
//  模块化拆分：游戏启动会话模型（从 CategoryContentView.swift 拆出）
//

import SwiftUI
import Combine

/// 单次游戏启动会话：绑定 launcher、日志、序号
final class GameSession: ObservableObject, Identifiable {
    let id: UUID = UUID()
    let index: Int
    let launcher: MinecraftLauncher
    @Published var logs: [String] = []
    /// 本会话的游戏进程是否在运行。**唯一写入口是 `LaunchCoordinator`**：
    /// `.running`（进程已确认拉起）置 true，进程退出（`.finished`）与两处终止入口
    /// （`closeSession` / `handlePowerTap`）置 false。
    /// 该标志是日志卡关闭按钮与电源按钮进入终止分支的唯一判据（`LaunchSessionManager
    /// .hasRunningSessions` 亦由它派生），不可由其它模块写入，否则终止逻辑会失效（历史缺陷 D7）。
    @Published var isProcessRunning: Bool = false
    @Published var isLaunching: Bool = true

    /// 本会话的进程是否**需要终止**（两处终止入口的唯一判据）。
    ///
    /// 判据是「进程已存在或已在运行」，**不是** `isProcessRunning`：
    /// 后者只在「游戏窗口出现 / 退出码 0 兜底」时才置 true，而窗口出现前有一段可达数十秒的
    /// 初始化期（Forge / NeoForge 常见）。这段窗口期里进程已经拉起、`launcher.currentProcess`
    /// 非 nil，但 `isProcessRunning` 仍是 false——终止入口若只看它，点日志卡 × 或电源键就只会
    /// 删掉会话、不调 `terminate()`，游戏随即变成没有 UI 入口的孤儿进程。
    ///
    /// 三个条件的取舍（方向：宁可多终止一次，绝不漏终止）：
    ///  - `isProcessRunning`：保持原有全部终止时机不变（本次改动只做加法，不加「减法」）；
    ///  - `launcher.currentProcess?.isRunning`：覆盖「已拉起、窗口尚未出现」的初始化期；
    ///  - `isLaunching && currentProcess != nil`：覆盖 `onLauncherReady` 之后、
    ///    `Process.run()` 之前的极窄窗口。此时 `terminate()` 只能置位
    ///    `isUserTerminated`，由 `MinecraftLauncher.launch` 在 `run()` 后补查该位并立即终止
    ///    （见该处注释），从而不会把「尚未启动完」误判成「未启动」。
    ///
    /// 已退出但会话仍被保留（非 0 退出码）的进程不在判据内：`.finished` 已把 `isLaunching`
    /// 置 false，故不会对已死的进程再调 `terminate()`。
    var hasLiveProcess: Bool {
        if isProcessRunning { return true }
        guard let process = launcher.currentProcess else { return false }
        return process.isRunning || isLaunching
    }

    init(index: Int, launcher: MinecraftLauncher) {
        self.index = index
        self.launcher = launcher
    }
}

enum LaunchPhase: Equatable {
    case idle
    case preparing
    case downloading
    case installing
    case launching
}

extension Notification.Name {
    static let closeGameSession = Notification.Name("closeGameSession")
}
