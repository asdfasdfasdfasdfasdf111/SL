import SwiftUI
import AppKit

/// 游戏启动编排 + 启动会话生命周期管理（CategoryContentView.startLaunch/closeSession/handleCloseSessionTap 下沉）。
///
/// 只操作引用类型全局单例（LauncherSettings / LaunchSessionManager）与全局函数 pclLaunch：
/// 六段 pclLaunch 回调（progress/phase/log/success/ready/completion）全部**零 self 捕获**——
/// completion 在游戏退出时才触发（可运行数小时），视图早已随分类切换销毁，
/// 操作单例而非视图 @State 即根治 UAF（与 DownloadDetailManager 治理模式一致）。
enum LaunchCoordinator {
    /// 启动游戏（版本/用户名校验 → 皮肤资源包准备 → pclLaunch 六段回调 → 会话登记）
    static func start(settings: LauncherSettings, sessionManager: LaunchSessionManager) {
        sessionManager.beginLaunch()
        // 启动前准备阶段：皮肤资源包应用等耗时操作期间按钮显示「准备中…」，
        // 避免此前启动按钮变灰却仍显示「启动游戏」的无反馈等待
        sessionManager.launchPhase = .preparing
        let gameDir = settings.selectedGameRoot.isEmpty ? nil : settings.selectedGameRoot
        let version = settings.selectedMinecraftVersion
        // PCL2 风格离线用户名校验（非空 / 无英文引号 / ≤16 字符）：
        // 否则 1.20.5+ 会因 hello 包 writeUtf(name,16) 报 "String too big" 而进服失败
        let username = settings.offlineUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameError = validateOfflineUsername(username)
        guard nameError.isEmpty else {
            sessionManager.resetProgress()
            settings.launchErrorMessage = nameError
            settings.showLaunchAlert = true
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
        var boundLauncher: MinecraftLauncher?

        let startGame = {
            pclLaunch(
            version: version,
            username: finalUsername,
            gameDir: gameDir,
            progressHandler: { progress in
                DispatchQueue.main.async {
                    if progress > sessionManager.launchProgress {
                        sessionManager.launchProgress = progress
                    }
                    if sessionManager.launchPhase == .downloading || sessionManager.launchPhase == .installing {
                        sessionManager.lightProgress = progress
                    }
                }
            },
            phaseHandler: { phase in
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
            },
            logHandler: { logLine in
                DispatchQueue.main.async {
                    guard let l = boundLauncher else { return }
                    if let session = sessionManager.session(for: l) {
                        session.logs.append(logLine)
                    } else {
                        // session 尚未建立：暂存到 launcher，建立后 flush
                        l.pendingLogs.append(logLine)
                    }
                }
            },
            launchSuccess: {
                DispatchQueue.main.async {
                    if let l = boundLauncher,
                       let session = sessionManager.session(for: l) {
                        session.isLaunching = false
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
            },
            onLauncherReady: { launcher in
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
            },
            completion: { launcher, result in
                DispatchQueue.main.async {
                    if let launcher = launcher,
                       let session = sessionManager.session(for: launcher) {
                        session.isProcessRunning = false
                        session.isLaunching = false
                    }
                    switch result {
                    case .success(let exitCode):
                        let userTerminated = launcher?.isUserTerminated ?? false
                        if exitCode != 0 && !userTerminated {
                            settings.launchErrorMessage = "Minecraft 异常退出 (退出码: \(exitCode))，请查看日志"
                            settings.showLaunchAlert = true
                        }
                        sessionManager.resetProgress()
                        withAnimation(.easeOut(duration: 0.3)) {
                            sessionManager.launchPhase = .idle
                        }
                    case .failure(let error):
                        sessionManager.resetProgress()
                        withAnimation(.easeOut(duration: 0.3)) {
                            sessionManager.launchPhase = .idle
                            if sessionManager.sessions.isEmpty { sessionManager.showLogView = false }
                        }
                        settings.launchErrorMessage = error.localizedDescription
                        settings.showLaunchAlert = true
                    }
                }
            }
        )
        }

        // 离线皮肤：确保资源包已生成并注入（PCL2 移植，幂等 hash 判断）。
        // 后台执行避免阻塞主线程。JAR 替换对 1.13+ 无效（默认皮肤在 entity/player/{slim,wide}/ 下），
        // 资源包方案全版本生效（1.19.3+ 与旧版路径都写入）。
        let gameDirPath = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
        if let skin = settings.skinImageURL, !gameDirPath.isEmpty, !version.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try SkinResourcePackApplier.apply(
                        skinURL: skin,
                        toVersion: version,
                        gameDir: URL(fileURLWithPath: gameDirPath),
                        settings: settings
                    )
                } catch {
                    print("皮肤资源包应用失败: \(error.localizedDescription)")
                }
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
        if session.isProcessRunning {
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

    /// 电源按钮点击：运行中有游戏 → NSAlert 确认后终止全部；否则取消启动并复位
    static func handlePowerTap(sessionManager: LaunchSessionManager) {
        let runningSessions = sessionManager.sessions.filter { $0.isProcessRunning }
        if !runningSessions.isEmpty {
            let alert = NSAlert()
            alert.messageText = runningSessions.count == 1 ? "确认关闭游戏？" : "确认关闭 \(runningSessions.count) 个正在运行的游戏？"
            alert.informativeText = "游戏进程将被终止，未保存的进度可能会丢失。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
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
