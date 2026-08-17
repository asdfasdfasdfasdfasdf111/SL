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
    @Published var isProcessRunning: Bool = true
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
