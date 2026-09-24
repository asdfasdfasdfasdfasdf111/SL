//
//  LaunchSessionManager.swift
//  模块化拆分：从 CategoryContentView 迁出「游戏启动会话 + 日志面板 + 启动进度」全局单例。
//  启动回调（slLaunch 六段）一律只操作本管理器（引用类型）与 LauncherSettings（引用类型），
//  零视图 self 捕获——视图销毁后回调触发也不会写已释放的 @State storage（UAF 根治，
//  与 DownloadDetailManager 治理模式一致：游戏可运行数小时后 completion 才触发，视图早已切走销毁）。
//

import SwiftUI
import Combine

final class LaunchSessionManager: ObservableObject {
    static let shared = LaunchSessionManager()
    private init() {}

    // MARK: - 游戏会话与日志面板

    /// 当前所有游戏会话（含已退出但日志还开着的）。顺序即界面上的排列顺序。
    @Published var sessions: [GameSession] = []
    /// 日志面板是否展开。⚠️ 它与 `sessions.isEmpty` 是**两个独立条件**，
    /// 界面要两者同时成立才显示面板（见 CategoryContentView.logPanel）。
    @Published var showLogView = false

    /// 是否还有**进程活着**的会话。注意与 `!sessions.isEmpty` 不同 ——
    /// 游戏退出后会话仍在列表里（日志还开着），但不再算「运行中」。
    var hasRunningSessions: Bool { sessions.contains { $0.isProcessRunning } }

    /// 创建会话：索引从 1 起分配（跳过已占用的编号），并把 launcher 暂存的日志灌进会话。
    /// ⚠️ 索引是**复用**的：先关掉 1 号会话再开新会话，新会话仍会拿到 1 号 ——
    /// 所以界面上的「启动日志N」不保证唯一递增。
    @discardableResult
    func addSession(launcher: MinecraftLauncher) -> GameSession {
        // 标记「这个 launcher 已经有会话了」：从这一刻起 pendingLogs 不再是合法的暂存目标。
        // 用户随后关掉日志卡时，后续日志行没有消费者，必须丢弃而不是无限暂存
        // （见 LaunchCoordinator 的 .log 分支）。设置必须在这里、而不是 session 存在期间。
        launcher.hasEverHadSession = true
        let usedIndices = Set(sessions.map { $0.index })
        var newIndex = 1
        while usedIndices.contains(newIndex) { newIndex += 1 }
        let session = GameSession(index: newIndex, launcher: launcher)
        if !launcher.pendingLogs.isEmpty {
            // 同样走唯一写入口：这些是会话建立前暂存的行，一并按合并窗口落地
            session.appendLogs(launcher.pendingLogs)
            launcher.pendingLogs.removeAll()
        }
        sessions.append(session)
        return session
    }

    /// 按 launcher **引用**（`===`）反查会话；传 nil 返回 nil。
    /// ⚠️ 用引用相等而不是 id —— 会话就是持着这个 launcher 对象建起来的。
    func session(for launcher: MinecraftLauncher?) -> GameSession? {
        guard let launcher else { return nil }
        return sessions.first { $0.launcher === launcher }
    }

    /// 移除一个会话（界面关掉日志卡片时调用）。⚠️ **不终止游戏进程** ——
    /// 关进程是 CloseSessionButton / LaunchCoordinator 的职责。
    func removeSession(_ session: GameSession) {
        sessions.removeAll { $0.id == session.id }
    }

    func removeAllSessions() {
        sessions.removeAll()
    }

    // MARK: - 启动进度（进度条/阶段/深浅条动画）

    // 启动进度的一组状态。浅色条由真实进度驱动；深色条走定时器平滑逼近 darkBarTarget。
    @Published var isLaunching = false
    @Published var launchProgress: Double = 0.0
    @Published var launchPhase: LaunchPhase = .idle
    /// 下载 / 安装阶段的进度（0~1），直接驱动按钮里的浅色矩形宽度。
    @Published var lightProgress: Double = 0.0
    /// 启动阶段深色条的当前值。**初值 0.2 而不是 0** —— 深色条始终留一小截，
    /// 表示「已进入启动阶段」而非「进度为零」。
    @Published var darkProgress: Double = 0.2
    /// 深色条要逼近的目标值。
    @Published var darkBarTarget: Double = 0.2
    /// 定时器是否在跑；false 时定时器即使被触发也会立刻返回（见 startDarkBarAnimation）。
    @Published var darkBarActive = false
    private var darkBarTimer: Timer?

    /// 开始一次启动：把所有进度状态复位到初值（含深色条回到 0.2）。
    /// ⚠️ **不启动**深色条定时器 —— 那是进入启动阶段时另行调用的（见 startDarkBarAnimation），
    /// 这里只做复位。
    func beginLaunch() {
        isLaunching = true
        launchPhase = .idle
        lightProgress = 0.0
        darkProgress = 0.2
        darkBarTarget = 0.2
        darkBarActive = false
        launchProgress = 0.0
    }

    /// 启动结束（成功拉起或失败）后复位，并**停掉**深色条定时器。
    /// 与 beginLaunch 的差别就在这一处：这里会 stop，那边不会。
    func resetProgress() {
        isLaunching = false
        launchProgress = 0.0
        lightProgress = 0.0
        darkProgress = 0.2
        darkBarTarget = 0.2
        darkBarActive = false
        stopDarkBarAnimation()
    }

    /// 启动深色条的平滑动画：0.05 秒一跳，每跳把差距的 8% 补上去。
    /// ⚠️ 用 `[weak self]` + 主队列派发：Timer 的闭包不保证在主线程触发。
    /// 追赶是**渐近**的（越接近越慢），永远到不了精确目标；但因为有
    /// `min(darkBarTarget, ...)` 封顶，不会越过目标。
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

    /// 停掉定时器并置空。可重复调用（`invalidate()` 对已失效的 Timer 是安全的）。
    func stopDarkBarAnimation() {
        darkBarTimer?.invalidate()
        darkBarTimer = nil
    }
}
