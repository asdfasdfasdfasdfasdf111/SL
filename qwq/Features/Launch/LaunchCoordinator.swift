import SwiftUI
import AppKit

/// 游戏启动编排 + 启动会话生命周期管理（CategoryContentView.startLaunch/closeSession/handleCloseSessionTap 下沉）。
///
/// 启动入口由用例层 `LaunchService` 承担（实现为 `Adapters/MinecraftInstanceLaunchService`，
/// 内部仍委托桥接层 `slLaunch`）：本文件只构造 `LaunchRequest` 并处理 `LaunchEvent`，
/// 不再直接依赖 `slLaunch` 的六段回调签名。事件处理与原回调逐条等价（时序与文案一致），
/// 迁移计划、差异分析与不可迁移项见 `Adapters/LAUNCH_FLOW.md`。
/// 回退：还原本文件的启动入口接线即可恢复旧路径（桥接层与旧流程未被删除）。
///
/// 只操作引用类型全局单例（LauncherSettings / LaunchSessionManager）与用例层服务：
/// 事件处理全部**零 self 捕获**——进程退出事件在游戏退出时才到达（可运行数小时），
/// 视图早已随分类切换销毁，操作单例而非视图 @State 即根治 UAF（与 DownloadDetailManager 治理模式一致）。
enum LaunchCoordinator {
    /// 启动游戏（版本/用户名校验 → 皮肤资源包准备 → 构造 LaunchRequest → 订阅启动事件 → 会话登记）
    static func start(settings: LauncherSettings, sessionManager: LaunchSessionManager) {
        sessionManager.beginLaunch()
        // 启动前准备阶段：皮肤资源包应用等耗时操作期间按钮显示「准备中…」，
        // 避免此前启动按钮变灰却仍显示「启动游戏」的无反馈等待
        sessionManager.launchPhase = .preparing
        let version = settings.selectedMinecraftVersion
        // PCL2 风格离线用户名校验（非空 / 无英文引号 / ≤16 字符）：
        // 否则 1.20.5+ 会因 hello 包 writeUtf(name,16) 报 "String too big" 而进服失败。
        // 此处保留为 UI 侧输入提示（立即反馈）；用例层入口会再做一次等价判定（见适配器 validatedUsername）。
        let username = settings.offlineUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameError = validateOfflineUsername(username)
        guard nameError.isEmpty else {
            sessionManager.resetProgress()
            LaunchPanelState.shared.presentError(nameError)
            return
        }
        let finalUsername = username.isEmpty ? "Player" : username
        // PCL2 HintChinese 语义：Minecraft 1.18+ 服务端只接受 [0-9A-Za-z_] 用户名，
        // 中文等字符会在服务端抛 "Invalid characters in username" 并断开连接（表现为「连接中断」）。
        // 启动前给明确警告，避免用户误以为启动器异常；保留「仍要启动」以兼容 1.18 之前的版本。
        if finalUsername.range(of: "^[0-9A-Za-z_]*$", options: .regularExpression) == nil {
            sessionManager.resetProgress()
            let alert = NSAlert()
            alert.messageText = "用户名可能无法进入游戏"
            alert.informativeText = "「\(finalUsername)」含非法字符，1.18+ 服务端会拒绝（连接中断），仅 1.18 前可用。仍要启动？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "仍要启动")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertSecondButtonReturn {
                return
            }
        }
        // 游戏根目录：取值口径与桥接层 `slLaunchInternal` 的 `resolvedGameDir` 完全一致
        // （selectedGameRoot 优先，为空则取当前实例目录）。同一路径随后也用于皮肤包与 options.txt 写入。
        let resolvedGameDirPath = settings.selectedGameRoot.isEmpty
            ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "")
            : settings.selectedGameRoot
        var boundLauncher: MinecraftLauncher?

        // 启动失败上报门控：`.failed` 事件（进程未拉起，桥接层经 completion 回传）与
        // `launch(_:)` 的抛出（用例层在进入桥接之前失败，如离线用户名非法）是同一失败的
        // 两条回传通道，共用一次性门控保证同一次启动只提示一次。
        let failureGate = LaunchFailureNoticeGate()

        // 启动失败统一上报（缺陷 D8）：**不再以 launcher 引用是否建立为前置条件**。
        // 旧实现把处理整体放在 `if let launcher` 内，launcher 尚未建立时的失败
        // （Java 未安装 / 客户端 JAR 缺失 / 实例无法创建 / 补全失败）被直接吞掉：
        // 既不提示，也不复位进度，界面永久停在「启动中」。
        // 文案沿用桥接层原始描述（错误文案的唯一来源），与 D2 确立的
        // 「启动失败（无退出码）vs 异常退出（有退出码）」区分口径一致，不在此处改写措辞。
        let reportLaunchFailure: (Error) -> Void = { error in
            guard failureGate.claim() else { return }
            DispatchQueue.main.async {
                sessionManager.resetProgress()
                withAnimation(.easeOut(duration: 0.3)) {
                    sessionManager.launchPhase = .idle
                    if sessionManager.sessions.isEmpty { sessionManager.showLogView = false }
                }
                LaunchPanelState.shared.presentError(error.localizedDescription)
            }
        }

        let startGame = {
            let request = LaunchRequest(
                version: version,
                gameRoot: URL(fileURLWithPath: resolvedGameDirPath),
                offlineUsername: finalUsername
            )
            // 事件 → UI 的翻译逐条对应原 slLaunch 六段回调，投递线程与调用点亦一致。
            // 用例层规范结果是 launch(_:) 的返回值/抛出值；本通道为迁移期兼容缝（见适配器文件头）。
            //
            // **接线现状（缺陷：会话登记等全部空转）**：此处只传了 `events`，
            // `sessionStore` 与 `logSink` 保持默认 nil，于是用例层内所有 `sessionStore?.` 调用
            // （会话登记 `register`、状态 `update`、`GameProcessController.waitForTermination`
            // 所需的过程观察）都不产生任何效果；`LaunchFixClientVerifier` 的 sha1 口径同样从未生效
            // （其宿主 `LaunchFixPreflight` 全库无引用）。本处**只标注不改接线**：
            // 终止入口实际走 `GameSession.launcher.terminate()`（closeSession / handlePowerTap），
            // 补上 store 会同时启用一条与现有 UI 并行的状态通道，属于合并阶段的任务。
            let service = MinecraftInstanceLaunchService(events: { event in
                switch event {
                case .progress(let progress):
                    DispatchQueue.main.async {
                        if progress > sessionManager.launchProgress {
                            sessionManager.launchProgress = progress
                        }
                        if sessionManager.launchPhase == .downloading || sessionManager.launchPhase == .installing {
                            sessionManager.lightProgress = progress
                        }
                    }
                case .phase(let phase):
                    DispatchQueue.main.async {
                        switch phase {
                        case "downloading":
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                sessionManager.launchPhase = .downloading
                            }
                        case "installing":
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                sessionManager.launchPhase = .installing
                            }
                        case "launching":
                            sessionManager.lightProgress = 1.0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                    sessionManager.launchPhase = .launching
                                }
                                sessionManager.darkProgress = 0.2
                                sessionManager.darkBarTarget = 1.0
                                sessionManager.darkBarActive = true
                                sessionManager.startDarkBarAnimation()
                            }
                        default:
                            break
                        }
                    }
                case .log(let logLine):
                    DispatchQueue.main.async {
                        guard let l = boundLauncher else { return }
                        if let session = sessionManager.session(for: l) {
                            session.logs.append(logLine)
                        } else {
                            // session 尚未建立：暂存到 launcher，建立后 flush
                            l.pendingLogs.append(logLine)
                        }
                    }
                case .launcherReady(let launcher):
                    // 绑定同步完成（与旧实现一致）：后续 log 事件依赖该引用，晚绑定会丢日志；
                    // 面板动画与 session 插入仍在主线程执行
                    boundLauncher = launcher
                    DispatchQueue.main.async {
                        let wasEmpty = sessionManager.sessions.isEmpty
                        // 先触发面板弹出动画（offset/opacity 过渡）
                        if wasEmpty {
                            withAnimation(.exaggeratedSpring) {
                                sessionManager.showLogView = true
                            }
                        }
                        // 再插入 session（带 transition）；索引分配与暂存日志 flush 在 addSession 内完成
                        _ = withAnimation(.exaggeratedSpring) {
                            sessionManager.addSession(launcher: launcher)
                        }
                    }
                case .running:
                    DispatchQueue.main.async {
                        if let l = boundLauncher,
                           let session = sessionManager.session(for: l) {
                            session.isLaunching = false
                            // 缺陷 D7：进程已确认拉起（窗口出现，或退出码 0 兜底）→ 置「运行中」。
                            // 此前该标志全代码库无人置 true，导致两处终止入口
                            // （日志卡关闭按钮 closeSession / 电源按钮 handlePowerTap）
                            // 的终止分支恒不可达，点了也杀不掉游戏进程。
                            // 取值直接读 launcher 自身 currentProcess 的实时状态：退出码 0 兜底
                            // 触发时进程已退出，此处不会被误置为运行中；该引用亦是 terminate()
                            // 的定向目标（多开时各自终止自己的进程，不共用 instance.process）。
                            session.isProcessRunning = (l.currentProcess?.isRunning ?? false)
                        }
                        withAnimation(.exaggeratedSpring) {
                            sessionManager.darkBarTarget = 1.0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(.easeOut(duration: 0.4)) {
                                sessionManager.launchPhase = .idle
                            }
                            sessionManager.resetProgress()
                        }
                    }
                case .finished(let result):
                    DispatchQueue.main.async {
                        guard let launcher = boundLauncher,
                              let session = sessionManager.session(for: launcher) else { return }
                        session.isProcessRunning = false
                        session.isLaunching = false
                        let userTerminated = launcher.isUserTerminated
                        if result.exitCode != 0 && !userTerminated {
                            LaunchPanelState.shared.presentError("Minecraft 异常退出 (退出码: \(result.exitCode))，请查看日志")
                        }
                        if result.exitCode == 0 || userTerminated {
                            // 正常退出或被用户终止：自动清掉会话，避免日志面板残留
                            let willBeEmpty = sessionManager.sessions.count == 1
                            withAnimation(.exaggeratedSpring) {
                                sessionManager.removeSession(session)
                                if willBeEmpty { sessionManager.showLogView = false }
                            }
                        }
                        sessionManager.resetProgress()
                        withAnimation(.easeOut(duration: 0.3)) {
                            sessionManager.launchPhase = .idle
                        }
                    }
                case .failed(let error):
                    // 启动失败（进程未拉起）：复位进度 + 提示，与 launcher 引用是否建立无关（D8）
                    reportLaunchFailure(error)
                }
            })
            // 用例层入口是 async：发起后立即返回（与旧 slLaunch 同为非阻塞）。
            // 用例层在进入桥接之前抛出的失败（离线用户名非法等）不会产生 `.failed` 事件，
            // 旧实现的 `try?` 会把它连同 UI 提示一并丢弃；此处捕获后走同一上报通道。
            Task {
                do {
                    _ = try await service.launch(request)
                } catch {
                    reportLaunchFailure(error)
                }
            }
        }

        // 离线皮肤：确保资源包已生成并注入（PCL2 移植，幂等 hash 判断）。
        // 后台执行避免阻塞主线程。JAR 替换对 1.13+ 无效（默认皮肤在 entity/player/{slim,wide}/ 下），
        // 资源包方案全版本生效（1.19.3+ 与旧版路径都写入）。
        // 语言与皮肤写入串行在同一个后台队列（都改 options.txt，避免竞态互相覆盖）。
        // 实际游戏运行目录是 gameRoot/versions/<版本>（instance.runningDirectory，slLaunch 实证），
        // 皮肤包与 options.txt 必须写到这里；此前写到 gameRoot 根目录游戏读不到（潜伏错误）。
        let versionGameDir: URL? = {
            guard !resolvedGameDirPath.isEmpty, !version.isEmpty else { return nil }
            return URL(fileURLWithPath: resolvedGameDirPath + "/versions/" + version)
        }()
        if let versionGameDir {
            DispatchQueue.global(qos: .utility).async {
                // 仅当存在自定义皮肤时才生成资源包；语言注入无条件执行
                if let skin = settings.skinImageURL {
                    do {
                        try SkinResourcePackApplier.apply(
                            skinURL: skin,
                            toVersion: version,
                            gameDir: versionGameDir,
                            settings: settings
                        )
                    } catch {
                        let err = "皮肤资源包应用失败: \(error.localizedDescription)"
                        NSLog(err)
                    }
                }
                GameLanguageSetter.applyChinese(gameDir: versionGameDir)
                DispatchQueue.main.async {
                    startGame()
                }
            }
        } else {
            startGame()
        }
    }

    /// 关闭单个会话（日志卡 xmark 按钮 → .closeGameSession 通知）：终止进程 → 移除会话 → 空时复位启动状态
    static func closeSession(_ session: GameSession, sessionManager: LaunchSessionManager) {
        // 判据用 `hasLiveProcess` 而非 `isProcessRunning`：后者在「窗口出现 / 退出码 0」之前恒为 false，
        // Forge 初始化期（可达数十秒）点 × 会只删会话、不终止进程 → 游戏成孤儿进程且再无终止入口。
        if session.hasLiveProcess {
            session.launcher.terminate()
            session.isProcessRunning = false
            session.isLaunching = false
        }
        let willBeEmpty = sessionManager.sessions.count == 1
        withAnimation(.exaggeratedSpring) {
            sessionManager.removeSession(session)
            if willBeEmpty {
                sessionManager.showLogView = false
            }
        }
        // 关闭最后一个会话时复位启动状态，确保关闭按钮消失
        if willBeEmpty {
            sessionManager.resetProgress()
            withAnimation(.easeOut(duration: 0.3)) {
                sessionManager.launchPhase = .idle
            }
        }
    }

    /// 电源按钮点击：运行中有游戏 → 直接终止全部（不弹窗确认）；否则取消启动并复位
    static func handlePowerTap(sessionManager: LaunchSessionManager) {
        // 与 closeSession 同一判据：窗口出现前的初始化期也要能终止，
        // 否则点电源键只会清掉会话，游戏在后台继续跑（孤儿进程）
        let runningSessions = sessionManager.sessions.filter { $0.hasLiveProcess }
        if !runningSessions.isEmpty {
            for s in runningSessions {
                s.launcher.terminate()
                s.isProcessRunning = false
                s.isLaunching = false
            }
            withAnimation(.exaggeratedSpring) {
                sessionManager.removeAllSessions()
                sessionManager.showLogView = false
            }
            sessionManager.resetProgress()
            withAnimation(.easeOut(duration: 0.3)) {
                sessionManager.launchPhase = .idle
            }
        } else {
            sessionManager.resetProgress()
            withAnimation(.easeOut(duration: 0.3)) {
                sessionManager.launchPhase = .idle
                sessionManager.showLogView = false
            }
        }
    }
}

// MARK: - 失败上报一次性门控

/// 保证同一次启动的失败只上报一次。
///
/// `.failed` 事件与 `launch(_:)` 的抛出可能描述同一失败（用例层先投递事件、再抛契约错误），
/// 两条通道各自 hop 到主队列后执行顺序无保证，故用门控而非顺序假设。
///
/// 显式 `nonisolated`：该对象要被事件回调线程与调用方线程共享，必须脱离
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 的默认推断（仅靠 `@unchecked Sendable`
/// 不足以阻止 MainActor 推断，届时跨线程访问会成片告警），与 `TerminationResumeGate`
/// 的治理方式一致。锁内只做内存操作，属同步临界区，不跨 `await` 持有。
private nonisolated final class LaunchFailureNoticeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reported else { return false }
        reported = true
        return true
    }
}
