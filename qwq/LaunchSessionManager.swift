//
//  LaunchSessionManager.swift
//  模块化拆分：从 CategoryContentView 迁出「游戏启动会话 + 日志面板 + 启动进度」全局单例。
//  启动回调（pclLaunch 六段）一律只操作本管理器（引用类型）与 LauncherSettings（引用类型），
//  零视图 self 捕获——视图销毁后回调触发也不会写已释放的 @State storage（UAF 根治，
//  与 DownloadDetailManager 治理模式一致：游戏可运行数小时后 completion 才触发，视图早已切走销毁）。
//

import SwiftUI
import Combine

final class LaunchSessionManager: ObservableObject {
    static let shared = LaunchSessionManager()
    private init() {}

    // MARK: - 游戏会话与日志面板

    @Published var sessions: [GameSession] = []
    @Published var showLogView = false

    var hasRunningSessions: Bool { sessions.contains { $0.isProcessRunning } }

    /// 创建会话：索引从 1 起分配（跳过已占用），flush launcher 暂存日志
    @discardableResult
    func addSession(launcher: MinecraftLauncher) -> GameSession {
        let usedIndices = Set(sessions.map { $0.index })
        var newIndex = 1
        while usedIndices.contains(newIndex) { newIndex += 1 }
        let session = GameSession(index: newIndex, launcher: launcher)
        if !launcher.pendingLogs.isEmpty {
            session.logs.append(contentsOf: launcher.pendingLogs)
            launcher.pendingLogs.removeAll()
        }
        sessions.append(session)
        return session
    }

    func session(for launcher: MinecraftLauncher?) -> GameSession? {
        guard let launcher else { return nil }
        return sessions.first { $0.launcher === launcher }
    }

    func removeSession(_ session: GameSession) {
        sessions.removeAll { $0.id == session.id }
    }

    func removeAllSessions() {
        sessions.removeAll()
    }

    // MARK: - 启动进度（进度条/阶段/深浅条动画）

    @Published var isLaunching = false
    @Published var launchProgress: Double = 0.0
    @Published var launchPhase: LaunchPhase = .idle
    @Published var lightProgress: Double = 0.0
    @Published var darkProgress: Double = 0.2
    @Published var darkBarTarget: Double = 0.2
    @Published var darkBarActive = false
    private var darkBarTimer: Timer?

    func beginLaunch() {
        isLaunching = true
        launchPhase = .idle
        lightProgress = 0.0
        darkProgress = 0.2
        darkBarTarget = 0.2
        darkBarActive = false
        launchProgress = 0.0
    }

    func resetProgress() {
        isLaunching = false
        launchProgress = 0.0
        lightProgress = 0.0
        darkProgress = 0.2
        darkBarTarget = 0.2
        darkBarActive = false
        stopDarkBarAnimation()
    }

    func startDarkBarAnimation() {
        darkBarTimer?.invalidate()
        darkBarTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.darkBarActive else { return }
                if self.darkProgress < self.darkBarTarget {
                    let step = max(0.003, (self.darkBarTarget - self.darkProgress) * 0.08)
                    self.darkProgress = min(self.darkBarTarget, self.darkProgress + step)
                }
            }
        }
    }

    func stopDarkBarAnimation() {
        darkBarTimer?.invalidate()
        darkBarTimer = nil
    }
}
