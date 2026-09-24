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
    /// 会话日志（**已落地的部分**）。
    ///
    /// ⚠️ `private(set)` 是刻意的：**唯一写入口是 `appendLog(_:)` / `appendLogs(_:)`**。
    /// 不要回到 `session.logs.append(...)` —— 本属性是 `@Published`，直接 append 会
    /// **每来一行就向全部订阅者广播一次**；Forge / NeoForge 启动期一秒能刷几十行，
    /// 逐行广播会让日志卡片整表重算并连带拖慢主线程（历史缺陷：长会话越跑越卡）。
    @Published private(set) var logs: [String] = []

    /// 因超出 `maxLogLines` 而被丢弃的日志行数。界面据此显示一行"已省略"说明，
    /// 避免用户以为日志是完整的（丢弃只发生在几万行级别的极端长会话）。
    @Published private(set) var droppedLogLineCount = 0

    /// 单会话保留的最大日志行数。超出后**按 1/4 批量**丢弃最早的行，
    /// 使裁剪是摊还的（每攒够 1/4 上限才搬一次数组），而不是每来一行搬一次。
    ///
    /// 显式 `nonisolated`：工程默认隔离是 MainActor，未标注的静态成员会被推断成主 actor 隔离；
    /// 而下面 `dropCount(forCount:)` 是纯算术、必须能在任意上下文（含单元测试）调用，
    /// 它要读这个常量 —— 不退出默认隔离的话，nonisolated 函数读它会直接报隔离错误。
    nonisolated static let maxLogLines = 20_000

    /// 日志合并窗口：新日志先入缓冲，每满 0.1 s 才写一次 `logs`。
    /// 合并的是 **@Published 的广播次数**，不是日志内容本身 —— 顺序与完整性不变。
    static let logFlushInterval: TimeInterval = 0.1

    /// 待落地的日志缓冲。刻意**不用** `@Published`：缓冲期间的写入不产生任何广播。
    private var logBuffer: [String] = []
    /// 是否已排好一次落地（合并窗口去重，保证 0.1 s 内最多一次）。
    private var isFlushScheduled = false
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

    // MARK: - 日志写入（唯一入口）

    /// 追加一行日志（实际落地时机由合并窗口决定，见 `appendLogs(_:)`）。
    func appendLog(_ line: String) {
        appendLogs([line])
    }

    /// 批量追加日志：并入缓冲，并确保 0.1 s 内有一次落地。
    ///
    /// 合并的是 `@Published` 的**广播次数**：所有行最终都会按原顺序进入 `logs`，
    /// 只是"写进数组 + 广播"这件事从每行一次变成每 0.1 s 一次。
    ///
    /// 必须在主线程调用（`logs` 是主 actor 隔离的展示状态；两个调用方
    /// `LaunchCoordinator` 与 `LaunchSessionManager` 本就都在 `DispatchQueue.main` 上）。
    func appendLogs(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        logBuffer.append(contentsOf: lines)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.logFlushInterval) { [weak self] in
            self?.flushLogs()
        }
    }

    /// 把缓冲区里的日志合并进 `logs`，并在超过上限时裁剪最早的若干行。
    ///
    /// 裁剪时机：`count > maxLogLines` 时一次性丢到 3/4 上限处。
    /// 之所以不"刚好丢到上限"：那会让之后每来一行都触发一次 `removeFirst`（搬整条数组）；
    /// 一次多丢 1/4 上限，就把搬运次数从"每行一次"降到"每 5000 行一次"。
    /// 丢弃的行数累计在 `droppedLogLineCount`，供界面如实说明。
    func flushLogs() {
        isFlushScheduled = false
        guard !logBuffer.isEmpty else { return }
        let batch = logBuffer
        logBuffer.removeAll(keepingCapacity: true)
        var merged = logs
        merged.append(contentsOf: batch)
        if merged.count > Self.maxLogLines {
            let dropCount = Self.dropCount(forCount: merged.count)
            merged.removeFirst(dropCount)
            droppedLogLineCount += dropCount
        }
        logs = merged
    }

    /// 给定当前总行数，返回应当丢弃的**最早**行数（0 表示不用丢）。
    ///
    /// 单独抽成 `nonisolated` 的纯函数，是为了让「上限不被突破」与「裁剪是摊还的」这两条
    /// 不变量可以被单元测试直接钉住 —— 若把它们留在 `flushLogs()` 里，测它就得先构造一个
    /// `GameSession`，而它的 `launcher` 必须是真实 `MinecraftLauncher`，那个 init 会往用户的
    /// Application Support 写日志文件并修剪历史日志：单测不该碰这些真实数据。
    ///
    /// 返回值保证：`count - dropCount` 落在 `[maxLogLines - maxLogLines/4, maxLogLines]` 区间内
    ///（上限不被突破；且一次多丢 1/4，使后续 1/4 上限次追加都不再需要搬数组）。
    nonisolated static func dropCount(forCount count: Int) -> Int {
        guard count > maxLogLines else { return 0 }
        return count - maxLogLines + maxLogLines / 4
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
