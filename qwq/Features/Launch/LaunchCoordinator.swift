import SwiftUI
import AppKit

/// 游戏启动编排 + 启动会话生命周期管理（CategoryContentView.startLaunch/closeSession/handleCloseSessionTap 下沉）。
///
/// 启动入口由用例层 `LaunchService` 承担（实现为 `Adapters/MinecraftInstanceLaunchService`，
/// 内部仍委托桥接层 `pclLaunch`）：本文件只构造 `LaunchRequest` 并处理 `LaunchEvent`，
/// 不再直接依赖 `pclLaunch` 的六段回调签名。事件处理与原回调逐条等价（时序与文案一致），
/// 迁移计划、差异分析与不可迁移项见 `Adapters/DUAL_FLOW.md`。
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
        // 游戏根目录：取值口径与桥接层 `pclLaunchInternal` 的 `resolvedGameDir` 完全一致
        // （selectedGameRoot 优先，为空则取当前实例目录）。同一路径随后也用于皮肤包与 options.txt 写入。
        let resolvedGameDirPath = settings.selectedGameRoot.isEmpty
            ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "")
            : settings.selectedGameRoot
        var boundLauncher: MinecraftLauncher?

        let startGame = {
            let request = LaunchRequest(
                version: version,
                gameRoot: URL(fileURLWithPath: resolvedGameDirPath),
                offlineUsername: finalUsername
            )
            // 事件 → UI 的翻译逐条对应原 pclLaunch 六段回调，投递线程与调用点亦一致。
            // 用例层规范结果是 launch(_:) 的返回值/抛出值；本通道为迁移期兼容缝（见适配器文件头）。
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
                    DispatchQueue.main.async {
                        // launcher 引用尚未建立时的失败（用户名/实例/Java/补全）沿用旧实现行为：
                        // 不产生任何 UI 提示，也不复位进度（旧 completion 亦在该条件内才处理）。
                        guard let launcher = boundLauncher,
                              sessionManager.session(for: launcher) != nil else { return }
                        sessionManager.resetProgress()
                        withAnimation(.easeOut(duration: 0.3)) {
                            sessionManager.launchPhase = .idle
                            if sessionManager.sessions.isEmpty { sessionManager.showLogView = false }
                        }
                        LaunchPanelState.shared.presentError(error.localizedDescription)
                    }
                }
            })
            // 用例层入口是 async：发起后立即返回（与旧 pclLaunch 同为非阻塞）。
            // 失败经 .failed 事件回传，故此处忽略抛出值——与旧实现一致：
            // launcher 尚未建立时的失败在旧路径下同样不产生任何 UI 提示。
            Task { _ = try? await service.launch(request) }
        }

        // 离线皮肤：确保资源包已生成并注入（PCL2 移植，幂等 hash 判断）。
        // 后台执行避免阻塞主线程。JAR 替换对 1.13+ 无效（默认皮肤在 entity/player/{slim,wide}/ 下），
        // 资源包方案全版本生效（1.19.3+ 与旧版路径都写入）。
        // 语言与皮肤写入串行在同一个后台队列（都改 options.txt，避免竞态互相覆盖）。
        // 实际游戏运行目录是 gameRoot/versions/<版本>（instance.runningDirectory，pclLaunch 实证），
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

    /// 电源按钮点击：运行中有游戏 → 直接终止全部（不弹窗确认）；否则取消启动并复位
    static func handlePowerTap(sessionManager: LaunchSessionManager) {
        let runningSessions = sessionManager.sessions.filter { $0.isProcessRunning }
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
