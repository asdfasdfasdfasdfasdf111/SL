import Foundation
import Cocoa
import Combine

/// 兼容层：桥接旧 UI 代码到启动核心（MinecraftLauncher）
extension MinecraftLauncher {
    /// 用户主动终止标志：terminate() 时置 true，completion 回调据此判断不报异常
    public var isUserTerminated: Bool {
        get { _objCIsUserTerminated }
        set { _objCIsUserTerminated = newValue }
    }
    /// 终止游戏进程：标记为用户主动关闭
    /// 注意：使用 launcher 自己的 currentProcess，避免多游戏共用 instance 时终止错误进程
    public func terminate() {
        _objCIsUserTerminated = true
        currentProcess?.terminate()
    }
    /// 日志缓冲：logHandler 在 session 建立前到达时暂存于此，session 建立后 flush
    public var pendingLogs: [String] {
        get { _objCPendingLogs }
        set { _objCPendingLogs = newValue }
    }
}

private var _objCIsUserTerminatedKey: UInt8 = 0
private var _objCPendingLogsKey: UInt8 = 0
extension MinecraftLauncher {
    /// 用 objc 关联对象存储 isUserTerminated（不修改 MinecraftLauncher 核心类的存储）
    private var _objCIsUserTerminated: Bool {
        get { (objc_getAssociatedObject(self, &_objCIsUserTerminatedKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &_objCIsUserTerminatedKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    private var _objCPendingLogs: [String] {
        get { (objc_getAssociatedObject(self, &_objCPendingLogsKey) as? NSArray) as? [String] ?? [] }
        set { objc_setAssociatedObject(self, &_objCPendingLogsKey, newValue as NSArray, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// 兼容启动入口：从旧 UI 参数构建 MinecraftInstance 并启动
/// 注意：本函数不阻塞，立即返回；启动过程通过回调通知 UI
/// 前置条件：`username` 必须已通过用例层校验（trim 后非空、无英文引号、≤16 UTF-16 code unit，
/// 空值调用方需自行兜底为 "Player"），本函数不再重复校验。
public func slLaunch(
    version: String,
    username: String,
    gameDir: String?,
    progressHandler: @escaping (Double) -> Void,
    phaseHandler: @escaping (String) -> Void,
    logHandler: @escaping (String) -> Void,
    launchSuccess: @escaping () -> Void,
    onLauncherReady: @escaping (MinecraftLauncher) -> Void,
    completion: @escaping (MinecraftLauncher?, Result<Int32, Error>) -> Void
) {
    // 启动前的重活（Java 扫描等待、manifest 解析、参数过滤）在后台线程执行，
    // 避免阻塞主线程导致 UI 未响应。所有回调在 UI 侧均已包 DispatchQueue.main.async。
    DispatchQueue.global(qos: .userInitiated).async {
        slLaunchInternal(
            version: version,
            username: username,
            gameDir: gameDir,
            progressHandler: progressHandler,
            phaseHandler: phaseHandler,
            logHandler: logHandler,
            launchSuccess: launchSuccess,
            onLauncherReady: onLauncherReady,
            completion: completion
        )
    }
}

private func slLaunchInternal(
    version: String,
    username: String,
    gameDir: String?,
    progressHandler: @escaping (Double) -> Void,
    phaseHandler: @escaping (String) -> Void,
    logHandler: @escaping (String) -> Void,
    launchSuccess: @escaping () -> Void,
    onLauncherReady: @escaping (MinecraftLauncher) -> Void,
    completion: @escaping (MinecraftLauncher?, Result<Int32, Error>) -> Void
) {
    let resolvedGameDir = gameDir ?? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "")

    // 离线用户名校验已上移至用例层（`MinecraftInstanceLaunchService.validatedUsername`，
    // Features/Launch/Adapters/MinecraftInstanceLaunchService.swift）：
    // 本函数的调用方必须保证 `username` 已 trim、非空、不含英文引号且不超过 16 个 UTF-16 code unit。
    // 上移依据：该判定原本在三处重复（UI 输入提示 / 本函数 / 用例层），逐步合并到用例层唯一入口；
    // 等价性论证（判定、兜底、失败时机、失败时 UI 不提示）见同目录 LAUNCH_FLOW.md。

    let minecraftDir = MinecraftDirectory(
        rootURL: URL(fileURLWithPath: resolvedGameDir),
        name: "默认文件夹"
    )

    guard let instance = MinecraftInstance.create(minecraftDir, version) else {
        completion(nil, .failure(MyLocalizedError(reason: "无法创建实例: \(version)")))
        return
    }

    // 设置离线账号（PCL2 移植：UUID 走 McLoginLegacyUuid，accessToken = UUID）
    let account = OfflineAccount(username)
    let options = LaunchOptions()
    options.playerName = username
    options.uuid = account.uuid
    options.account = .offline(account)
    options.skipResourceCheck = true

    // 未实现账号告警（迁自原启动流程，治理口径不变）：
    // 微软 / Yggdrasil 登录流程尚未实现，运行期一律按离线账号处理，必须显式告知用户，
    // 避免其误以为本次启动已完成联网登录。本路径只构造离线账号，
    // 因此未实现账号只可能来自持久化的账号选择（AccountManager）。
    if let selectedAccount = AccountManager.shared.getAccount(),
       let unimplemented = selectedAccount.unimplementedError {
        warn("\(selectedAccount.accountKindDescription)：\(unimplemented.errorDescription ?? "该功能尚未实现")")
        hint(unimplemented.errorDescription ?? "该账号类型尚未实现，本次启动按离线账号处理。", .critical)
    }

    // MARK: 客户端 JAR 校验（LAUNCH_FLOW 缺陷 D1）
    // 本路径把 skipResourceCheck 恒置为 true（该标记的原始用途是跳过旧启动流程里的
    // createCompleteTask 全量安装任务；该任务已随旧流程删除，但字段语义被沿用）；
    // 而 LaunchFix.perform 只覆盖 libraries / assets / natives，
    // 不含客户端本体。缺 JAR 时 classpath 末项仍是该路径，JVM 对不存在的 classpath 条目静默忽略，
    // 直到进入游戏才以 ClassNotFoundException 崩溃，UI 只能显示「异常退出」。
    // 故必须在拉起进程前显式判定并失败。
    //
    // **为什么放在补全之前**：本判定与 LaunchFix 无依赖（LaunchFix 从不写客户端 JAR，
    // 见 `LaunchFix.perform` 四段：libraries / assets 索引 / assets 对象 / natives），
    // 而补全最长可跑 600s（超时上限）。原顺序把「必然失败」的启动拖到补全结束（甚至拖满
    // 十分钟超时）之后才报错，用户先看到进度条走完、再看到一句「启动前补全失败」，
    // 真正原因（客户端本体缺失）反而被网络错误掩盖。前移后缺 JAR 立即拦住，
    // 零下载、零等待，报错文案也直接指向该问题的解法。
    //
    // 路径推导（沿用既有构造式，未新拼路径）：
    //   MinecraftLauncher.buildClasspath() 末项即
    //   `instance.runningDirectory.appendingPathComponent("\(instance.name).jar")`，
    //   且 `instance.name == runningDirectory.lastPathComponent`；
    //   该路径同时是 MinecraftInstaller.downloadClientJar 的落盘目标
    //   `task.versionURL/<task.name>.jar`（MinecraftInstallTask.versionURL 即
    //   minecraftDirectory.versionsURL/<name>）。
    //
    // 判定口径：只校验「存在且非空」，不与 manifest.clientDownload?.sha1 比对。
    // 带 inheritsFrom 的加载器实例其清单合并后沿用父级 clientDownload.sha1
    // （ClientManifest.merge 保留父级字段），而版本目录内的 JAR 会被加载器安装器就地改写，
    // 哈希必然不同；按 sha1 判定会把本可正常启动的加载器实例判为损坏（LAUNCH_FLOW 风险点 R6）。
    let clientJAR = instance.runningDirectory.appendingPathComponent("\(instance.name).jar")
    if let reason = FileChecker(minSize: 1).check(clientJAR) {
        log("客户端 JAR 校验失败：\(clientJAR.path)（\(reason)）")
        completion(nil, .failure(LaunchError.fileVerificationFailed(
            reason: "客户端 JAR 缺失或损坏：\(clientJAR.path)（\(reason)）。请在「下载」页重新安装该版本。"
        )))
        return
    }

    // MARK: 启动前补全（PCL2 DlClientFix 移植）：分析缺失/损坏的库与资源 → 仅下载缺失项
    // 补全期间 UI 显示 downloading 进度条；完成后才进入 launching（避免相位回退）
    // 补全失败则终止启动（与 PCL2 一致），避免缺文件启动后崩溃
    let fixResultBox = FixResultBox()
    // 超时后置位：闸断后续进度回调（见下方超时分支注释）
    let fixAbandoned = AbandonFlag()
    let fixSemaphore = DispatchSemaphore(value: 0)
    phaseHandler("downloading")
    let fixTask = Task {
        do {
            try await LaunchFix.perform(instance: instance) { p in
                // 超时后不再回调 UI：UI 已按「补全超时」复位到 idle 并弹出错误，
                // 若继续回调进度，用户会看到「错误提示 + 进度条继续走」的并存状态。
                guard !fixAbandoned.isSet else { return }
                progressHandler(p)
            }
            log("启动前补全完成：缺失的库/资源已补齐")
        } catch {
            fixResultBox.error = error
            log("启动前补全失败: \(error.localizedDescription)")
        }
        fixSemaphore.signal()
    }
    if fixSemaphore.wait(timeout: .now() + 600) == .timedOut {
        // MARK: 超时处理（缺陷：超时后任务仍继续跑且无取消路径）
        // 原实现只 `completion(.failure)` 就 return：补全 Task 仍在后台下载并持续回调
        // `progressHandler`，UI 报错之后又被进度回调推着继续走，且没有任何取消入口。
        // 现做两件事，并把「能做到什么程度」写清：
        //  1) 置 `fixAbandoned`：**强保证**切断 UI 回调（不再有进度事件流向界面）；
        //  2) `fixTask.cancel()`：**尽力而为**。真正的网络中止需要下载层有取消检查点，
        //     而 `LaunchFix` 底层的 `MultiFileDownloader.start()` → `NetManager.downloadAll`
        //     内部没有任何 `Task.isCancelled` / `checkCancellation` 判定
        //     （`SLCore/Download/MultiFileDownloader.swift:110-152`），
        //     且该层不在本轮允许修改的范围内，因此取消只能传递给仍会响应的 await 点，
        //     无法保证立即停止在途 TCP 下载。残留下载只会继续写入本地缓存目录（下次启动可直接复用），
        //     不会阻塞本次流程——本函数已经 return，后续走完 `.launchFailed` 通道。
        fixAbandoned.set()
        fixTask.cancel()
        completion(nil, .failure(MyLocalizedError(reason: "启动前补全超时（10 分钟），请检查网络连接")))
        return
    }

    if let fixError = fixResultBox.error {
        completion(nil, .failure(MyLocalizedError(reason: "启动前补全失败：\(fixError.localizedDescription)")))
        return
    }

    // MARK: 客户端 JAR 校验已前移到本函数开头（补全之前）——见该处注释。
    // 补全后不再重复判定：同一路径同一次启动内不可能由补全产生（LaunchFix 不写客户端本体）。

    phaseHandler("launching")

    let launcher = MinecraftLauncher(instance)!

    // 沿用原启动流程中启动前的最小化设置
    account.putAccessToken(options: options)

    // MARK: Java 选择：统一走 manifest 优先的动态策略
    // 1) 确保已触发 Java 扫描（若 DataManager 中为空）
    if DataManager.shared.javaVirtualMachines.isEmpty {
        log("DataManager 中暂无 JVM，触发预扫描")
        JavaManager.shared.preScanJavaAsync()
        // 等待扫描结果：订阅 DataManager 的 JVM 发布流，首个非空值到达即唤醒；
        // 保留原实现的 3s 等待上限，不再用「无人 signal 的信号量」做 100ms 轮询忙等。
        // 发布发生在主线程（JavaManager 回写），本函数运行在后台线程，等待方与回写方互不阻塞（R9）。
        let scanSettled = DispatchSemaphore(value: 0)
        let scanObserver = DataManager.shared.$javaVirtualMachines
            .sink { if !$0.isEmpty { scanSettled.signal() } }
        let hit = scanSettled.wait(timeout: .now() + 3) == .success
        scanObserver.cancel()
        log("Java 扫描等待结束（3s 内命中=\(hit)），DataManager JVM 数量=\(DataManager.shared.javaVirtualMachines.count)")
    }

    // 2) 读取 manifest.javaVersion（API 后端数据源），推断兜底
    let minJavaVersion = MinecraftInstance.resolveMinJavaVersion(manifest: instance.manifest, version: instance.version)
    log("最低 Java 要求: \(minJavaVersion) (manifest.javaVersion = \(instance.manifest?.javaVersion ?? -1), 版本推断 = \(MinecraftInstance.getMinJavaVersion(instance.version))")

    // 3) 校验缓存的 javaURL：存在 + 版本满足
    let fm = FileManager.default
    let cachedJavaURL = instance.config.javaURL
    var selectedJavaURL: URL? = nil
    if let cached = cachedJavaURL, fm.isExecutableFile(atPath: cached.path),
       let major = MinecraftInstance.readJavaMajorVersion(at: cached), major >= minJavaVersion {
        selectedJavaURL = cached
        log("沿用缓存 Java: \(cached.path) (major=\(major))")
    } else {
        if cachedJavaURL != nil { log("缓存 Java 失效或版本不足，重新选择") }
        // 优先走统一的 Java 解析器（Features/Java/JavaResolver）：
        // 候选来源、排序策略与兼容性判断集中在模块内一处，不再依赖多级 fallback 各自为政
        if let resolved = JavaResolverBridge.resolveSynchronously(
            minimumMajor: minJavaVersion,
            mcVersion: instance.version.displayName
        ) {
            selectedJavaURL = resolved
            log("JavaResolver 命中: \(resolved.path)")
        }

        // 回退：尝试通过 DataManager 选择（已被 JavaManager.syncJavaVirtualMachines 填充）
        if selectedJavaURL == nil, let jvm = MinecraftInstance.findSuitableJava(instance.version, minJavaVersion: minJavaVersion, manifest: instance.manifest) {
            selectedJavaURL = jvm.executableURL
            log("通过 DataManager 自动选择 Java: \(jvm.executableURL.path) (major=\(jvm.version), callMethod=\(jvm.callMethod))")
        } else if selectedJavaURL == nil {
            // 兜底：直接使用 JavaManager.selectBestJava（基于 LauncherSettings.availableJavaList）
            var scanned = LauncherSettings.shared.availableJavaList
            if scanned.isEmpty {
                scanned = JavaManager.shared.scanInstalledJava(useCache: true)
                DispatchQueue.main.async { LauncherSettings.shared.availableJavaList = scanned }
            }
            log("DataManager 未命中，回退 JavaManager 扫描列表 (count=\(scanned.count))")
            if let best = JavaManager.shared.selectBestJava(requiredMajor: minJavaVersion, from: scanned) {
                selectedJavaURL = URL(fileURLWithPath: best.path)
                log("兜底选择 Java: \(best.path) (major=\(best.majorVersion), arch=\(best.architecture))")
            }
        }
    }

    guard let finalJavaURL = selectedJavaURL, fm.isExecutableFile(atPath: finalJavaURL.path) else {
        let available = DataManager.shared.javaVirtualMachines.map { "\($0.executableURL.path) (major=\($0.version), \($0.callMethod))" }
        let scanned = LauncherSettings.shared.availableJavaList.map { "\($0.path) (major=\($0.majorVersion))" }
        log("未找到满足版本要求 (Java \(minJavaVersion)+) 的 Java 安装")
        log("DataManager JVMs: \(available.joined(separator: "; "))")
        log("LauncherSettings list: \(scanned.joined(separator: "; "))")
        completion(nil, .failure(MyLocalizedError(reason: "未找到满足版本要求 (Java \(minJavaVersion)+) 的 Java 安装，请先在「Java 管理」中扫描或下载 Java。")))
        return
    }

    options.javaPath = finalJavaURL
    instance.config.javaURL = finalJavaURL
    instance.saveConfig()

    // Java 主版本只探测一次（读 release 文件，不启动进程），后续校验/过滤复用
    let selectedJavaMajor = MinecraftInstance.readJavaMajorVersion(at: finalJavaURL)
    if let javaMajor = selectedJavaMajor {
        log("Java 版本校验: major=\(javaMajor), 要求>=\(minJavaVersion), 满足=\(javaMajor >= minJavaVersion)")
    }

    // MARK: 架构检查 + 参数过滤
    if Architecture.getArchOfFile(finalJavaURL).isCompatiableWithSystem() {
        ArtifactVersionMapper.map(instance.manifest)
        log("Java 架构与系统兼容，使用直接运行")
    } else {
        ArtifactVersionMapper.map(instance.manifest, arch: .x64)
        log("Java 架构与系统不兼容，使用 Rosetta 转译")
    }

    // 过滤当前 Java 不支持的参数（如 Java < 23 过滤 --sun-misc-unsafe-memory-access）
    // 注意：getArguments() 返回 manifest 内部存储的对象，直接修改 jvm 即可生效
    if let javaMajor = selectedJavaMajor, javaMajor < 23 {
        let args = instance.manifest.getArguments()
        args.jvm = args.jvm.filter { arg in
            if let s = arg.string, s.contains("--sun-misc-unsafe-memory-access") {
                log("过滤掉 Java \(javaMajor) 不支持的 JVM 参数: \(s)")
                return false
            }
            return true
        }
    }

    // 立即回传 launcher 引用，让 UI 能调 terminate()
    onLauncherReady(launcher)

    let logURL = launcher.logURL

    // 窗口出现（正常路径）与退出兜底（exitCode==0）都会触发 launchSuccess，
    // 用一次性门控保证 UI 复位逻辑只执行一次。
    let successGate = NSLock()
    var successFired = false
    let reportLaunchSuccess = {
        successGate.lock()
        let shouldFire = !successFired
        successFired = true
        successGate.unlock()
        if shouldFire { launchSuccess() }
    }

    // 后台监听日志文件，新行回传给 UI
    // 增量读取：FileHandle 维护读偏移，只读新增字节（原实现每 150ms 全量 Data(contentsOf:) 重读整个文件）
    // 无新数据时休眠 400ms；UTF-8 字符跨 chunk 截断通过「仅按 \n 边界切行 + 缓冲尾部」保证完整
    let logTask = Task.detached(priority: .utility) {
        guard let handle = FileHandle(forReadingAtPath: logURL.path) else { return }
        defer { try? handle.close() }
        var pending = Data()
        while !Task.isCancelled {
            if let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                var lines: [String] = []
                while let nl = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.prefix(upTo: nl)
                    pending.removeSubrange(0...nl)
                    if let s = String(data: lineData, encoding: .utf8), !s.isEmpty {
                        lines.append(s)
                    }
                }
                for line in lines { logHandler(line) }
            } else {
                try? await Task.sleep(nanoseconds: 400 * 1_000_000)
            }
        }
    }

    // 后台轮询检测 MC 窗口出现，触发 launchSuccess（2s 间隔：CGWindowList 全量遍历较贵，降频省 CPU）
    let windowTask = Task.detached(priority: .utility) {
        var fired = false
        while !Task.isCancelled, !fired {
            // `launcher.currentProcess` 是主 actor 隔离的可变属性（本工程默认隔离为 MainActor），
            // 写入方在启动线程。原先在这个 detached 任务里直接读它，属于**跨线程读可变状态**，
            // 编译器已就此告警（SLLaunchBridge.swift:358，Swift 6 语言模式下是错误）。
            // 改为回主 actor 取一次值，只把 Sendable 的 pid / 运行标记带出隔离域；
            // CGWindowList 的遍历与进程存活判断仍在后台线程执行，降频省 CPU 的意图不变。
            let probe: (pid: Int32, running: Bool)? = await MainActor.run {
                guard let process = launcher.currentProcess else { return nil }
                return (process.processIdentifier, process.isRunning)
            }
            if let probe, probe.running {
                let cgOptions = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
                if let windowInfoList = CGWindowListCopyWindowInfo(cgOptions, kCGNullWindowID) as? [[String: Any]] {
                    for info in windowInfoList {
                        if let windowPID = info["kCGWindowOwnerPID"] as? Int32,
                           windowPID == probe.pid {
                            reportLaunchSuccess()
                            fired = true
                            break
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
        }
    }

    // 在后台线程调用 launch（会阻塞到进程退出）
    DispatchQueue.global(qos: .userInitiated).async {
        launcher.launch(options) { outcome in
            logTask.cancel()
            windowTask.cancel()
            switch outcome {
            case .exited(let exitCode):
                // 窗口检测任务已触发则为幂等跳过；此处兜底保证正常退出也能复位 UI
                if exitCode == 0 { reportLaunchSuccess() }
                completion(launcher, .success(exitCode))
            case .launchFailed(let error):
                // 进程未拉起与「游戏崩溃退出」必须区分：前者没有退出码，
                // 统一返回 .failure 让 UI 展示「启动失败：<原因>」而不是「异常退出（退出码 1）」。
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("启动失败：\(reason)")
                completion(launcher, .failure(MyLocalizedError(reason: "启动失败：\(reason)")))
            }
        }
    }
}

/// 跨线程传递启动前补全的错误结果（后台线程用信号量同步等待 Task 完成）
private final class FixResultBox {
    var error: Error?
}

/// 跨线程共享的一次性「已放弃」标志。
///
/// 用途：`slLaunchInternal` 在补全超时后置位，补全 Task 的进度回调据此**停止向 UI 投递**；
/// 回调可能在主线程（`MultiFileDownloader` 经 `MainActor.run` 回调）而置位发生在等待线程，
/// 故用锁保护（锁内只做内存读写，不回调外部、不跨 await 持有）。
/// 显式 `nonisolated`：需脱离 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 的默认推断
/// （仅靠 `@unchecked Sendable` 不足以阻止 MainActor 推断），与 `TerminationResumeGate` 治理方式一致。
private nonisolated final class AbandonFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        abandoned = true
    }
}
