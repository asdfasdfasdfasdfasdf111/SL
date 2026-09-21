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
