import Foundation
import Cocoa
import Combine

/// 兼容启动入口：从旧 UI 参数构建 MinecraftInstance 并启动
/// 注意：本函数不阻塞，立即返回；启动过程通过回调通知 UI
/// 前置条件：`username` 必须已通过用例层校验（trim 后非空、无英文引号、≤16 UTF-16 code unit，
/// 空值调用方需自行兜底为 "Player"），本函数不再重复校验。
/// 一次启动「准备阶段」的取消令牌。

/// 定义已拆出：`LaunchCancellationToken` 见 SLCore/LaunchCancellationToken.swift（2026-10-03 搬家）。

public func slLaunch(
    version: String,
    username: String,
    gameDir: String?,
    progressHandler: @escaping (Double) -> Void,
    phaseHandler: @escaping (String) -> Void,
    logHandler: @escaping (String) -> Void,
    launchSuccess: @escaping () -> Void,
    onLauncherReady: @escaping (MinecraftLauncher) -> Void,
    cancellation: LaunchCancellationToken? = nil,
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
            cancellation: cancellation,
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
    cancellation: LaunchCancellationToken?,
    completion: @escaping (MinecraftLauncher?, Result<Int32, Error>) -> Void
) {
    // MARK: 取消判定点（缺陷：「准备期点取消，游戏仍会自己弹出来」）
    // `GameSession.launcher.terminate()` 只能终止**已经起来**的进程；而从点「启动」到进程
    // 真正 `run()` 之间取不到 launcher，用户的取消原先只复位了界面，后台准备链完全感知不到，
    // 会一路跑完并把游戏拉起来 —— 点了取消，几十秒后游戏自己弹出来。
    // 因此准备阶段每个「昂贵 / 不可逆」动作之前都过一次本判定：
    //   ① 函数入口（最早一处；也让「已取消 ⇒ 不启动」能在无实例、无目录的测试环境里确定性验证）
    //   ② 进入启动前补全之前（最贵：600s 超时、可能下载数百 MB）
    //   ③ 补全等待期间（改成 200ms 分片轮询，取消后 ≤0.2s 返回，不再白等最多 10 分钟）
    //   ④ Java 选择之前（可能触发一次全盘 Java 扫描）
    //   ⑤ 拉起进程之前（唯一的不可逆动作）
    // 取消一律以 `LaunchError.cancelled` 收口；UI 侧按同一令牌把它判为「用户主动取消」
    // 而非失败（不弹错误框，见 `LaunchCoordinator.reportLaunchFailure`）。
    func abortIfCancelled(_ stage: String) -> Bool {
        guard cancellation?.isCancelled == true else { return false }
        log("启动已被用户取消：\(stage)")
        completion(nil, .failure(LaunchError.cancelled))
        return true
    }

    // 取消判定点 ①：函数入口。放在最前面有两层用处：
    //  - 语义上，「已取消」优先于其它一切失败 —— 没必要为一次注定不启动的请求去解析目录、
    //    构造实例、读客户端 JAR（也就不会把「客户端 JAR 缺失」这种可修复提示盖在取消之上）；
    //  - 可测性上，本判定只依赖令牌本身，因此「令牌已置位 ⇒ 必然回调 .cancelled 且绝不
    //    触发 onLauncherReady」这条断言可以在没有游戏目录、没有实例的单元测试里稳定跑出来
    //    （反向用例，见 qwqTests/LaunchCancellationTests.swift）。
    if abortIfCancelled("不再继续准备") { return }

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
        // 2026-10-02：结构化错误（此前用 MyLocalizedError("无法创建实例: …") 携带文案，
        // mapFailure 再按文案反猜归类）。LaunchError.errorDescription 与此前文案逐字一致。
        completion(nil, .failure(LaunchError.instanceNotFound(version: version)))
        return
    }

    // 账号选择（微软登录已实现，2026-10-…）：
    // 若 AccountManager 选中了**可用的微软账号**，用它的档案身份与令牌启动；
    // 否则回退原离线逻辑（username 参数来自 UI 的离线用户名输入）。
    // 无论走哪条分支，`options.account` 都承载真实的账号种类，
    // 后续「启动前的最小化设置」处按种类注入对应令牌。
    let options = LaunchOptions()
    options.skipResourceCheck = true
    if let selected = AccountManager.shared.getAccount(),
       case .microsoft(let ms) = selected, ms.isUsable {
        options.playerName = ms.name
        options.uuid = ms.uuid
        options.account = .microsoft(ms)
    } else {
        // 离线账号（PCL2 移植：UUID 走 McLoginLegacyUuid，accessToken = UUID）
        let account = OfflineAccount(username)
        options.playerName = username
        options.uuid = account.uuid
        options.account = .offline(account)
    }

    // 未实现账号告警（迁自原启动流程，治理口径不变）：
    // 微软登录已实现（2026-10-…）；Yggdrasil 登录流程尚未实现，运行期按离线账号处理，
    // 必须显式告知用户，避免其误以为本次启动已完成联网登录。本路径在上方账号选择
    // 分支按 AccountManager 的已选账号构造（离线 or 微软），未实现账号只可能来自
    // 持久化的账号选择（AccountManager 的 .yggdrasil 旧数据）。
    if let selectedAccount = AccountManager.shared.getAccount(),
       let unimplemented = selectedAccount.unimplementedError {
        warn("\(selectedAccount.accountKindDescription)：\(unimplemented.errorDescription ?? "该功能尚未实现")")
        hint(unimplemented.errorDescription ?? "该账号类型尚未实现，本次启动按离线账号处理。", .critical)
    }

    // MARK: 客户端 JAR 校验（LAUNCH_FLOW 缺陷 D1）
    // 本路径把 skipResourceCheck 恒置为 true（该标记的原始用途是跳过旧启动流程里的
    // createCompleteTask 全量安装任务；该任务已随旧流程删除，但字段语义被沿用）；
    // 而启动前补全（LaunchPreflightBridge → DefaultLaunchPreflight）只覆盖 libraries / assets / natives，
    // 不含客户端本体。缺 JAR 时 classpath 末项仍是该路径，JVM 对不存在的 classpath 条目静默忽略，
    // 直到进入游戏才以 ClassNotFoundException 崩溃，UI 只能显示「异常退出」。
    // 故必须在拉起进程前显式判定并失败。
    //
    // **为什么放在补全之前**：本判定与补全无依赖（preflight 从不写客户端 JAR，
    // 见 DefaultLaunchPreflight 四段：libraries / assets 索引 / assets 对象 / natives），
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

    // 取消判定点 ②：进入「启动前补全」之前。
    // 这是准备阶段最贵的一步（600s 超时、可能下载数百 MB），用户既然已经取消，
    // 就不该再开这笔流量与磁盘写。
    if abortIfCancelled("跳过启动前补全") { return }

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
            try await LaunchPreflightBridge.prepare(instance: instance) { p in
                // 补全已被放弃（超时或被用户取消）后不再回调 UI：两种情况 UI 都已复位到 idle
                //（超时会弹错误提示），若继续回调进度，用户会看到「已复位 + 进度条继续走」的并存状态。
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
    // 等待补全完成 —— **可被取消打断**。
    // 原实现是一次性 `wait(timeout: .now() + 600)`：用户在这段时间里点取消，最早也要等补全
    // 整个跑完才可能被察觉（最多白等 10 分钟、白下载数百 MB），而请求发出后不久游戏仍会被拉起。
    // 改成 200ms 分片轮询后，可感知的等待从「最多 600s」降到「≤0.2s」。
    // 分片数即超时上限：3000 × 0.2s = 600s（与原先一致，不用时钟，免得受系统时间调整影响）。
    var fixSignalled = false
    for _ in 0..<3000 {
        if fixSemaphore.wait(timeout: .now() + 0.2) == .success { fixSignalled = true; break }
        if cancellation?.isCancelled == true { break }
    }
    // 3000 片耗尽仍未 signal：区分「用户取消」与「真超时」——前者优先
    let fixWaitOutcome: FixWaitOutcome = fixSignalled
        ? .finished
        : (cancellation?.isCancelled == true ? .cancelled : .timedOut)

    switch fixWaitOutcome {
    case .cancelled:
        // 取消判定点 ③：补全等待期间被取消。
        // 与超时分支同样处理：置 `fixAbandoned` 闸断 UI 回调，`fixTask.cancel()` 尽力而为。
        // 注意这里**不能**等补全真结束才返回 —— 用户的诉求是「立刻停」，不是「等它跑完」。
        fixAbandoned.set()
        fixTask.cancel()
        log("启动已被用户取消：中止启动前补全")
        completion(nil, .failure(LaunchError.cancelled))
        return

    case .timedOut:
        // MARK: 超时处理（缺陷：超时后任务仍继续跑且无取消路径）
        // 原实现只 `completion(.failure)` 就 return：补全 Task 仍在后台下载并持续回调
        // `progressHandler`，UI 报错之后又被进度回调推着继续走，且没有任何取消入口。
        // 现做两件事，并把「能做到什么程度」写清：
        //  1) 置 `fixAbandoned`：**强保证**切断 UI 回调（不再有进度事件流向界面）；
        //  2) `fixTask.cancel()`：**尽力而为**。真正的网络中止需要下载层有取消检查点，
        //     而 `LaunchPreflightBridge` → `DefaultLaunchPreflight` 底层的
        //     `MultiFileDownloader.start()` → `NetManager.downloadAll`
        //     内部没有任何 `Task.isCancelled` / `checkCancellation` 判定
        //     （`SLCore/Download/MultiFileDownloader.swift:110-152`），
        //     且该层不在本轮允许修改的范围内，因此取消只能传递给仍会响应的 await 点，
        //     无法保证立即停止在途 TCP 下载。残留下载只会继续写入本地缓存目录（下次启动可直接复用），
        //     不会阻塞本次流程——本函数已经 return，后续走完 `.launchFailed` 通道。
        fixAbandoned.set()
        fixTask.cancel()
        // 2026-10-02：结构化错误。此前 mapFailure 靠 `contains("启动前补全")` 文案反猜
        // 归类；现在直接落 fileVerificationFailed（补全即文件校验的一环）。
        completion(nil, .failure(LaunchError.fileVerificationFailed(reason: "启动前补全超时（10 分钟），请检查网络连接")))
        return

    case .finished:
        break
    }

    if let fixError = fixResultBox.error {
        // 2026-10-02：结构化错误（此前 MyLocalizedError 携带文案，mapFailure 文案反猜）。
        completion(nil, .failure(LaunchError.fileVerificationFailed(reason: "启动前补全失败：\(fixError.localizedDescription)")))
        return
    }

    // MARK: 客户端 JAR 校验已前移到本函数开头（补全之前）——见该处注释。
    // 补全后不再重复判定：同一路径同一次启动内不可能由补全产生（preflight 不写客户端本体）。

    // 取消判定点 ④：Java 选择之前。取消后不再触发全盘 Java 扫描，也不改写实例配置。
    if abortIfCancelled("跳过 Java 选择") { return }

    phaseHandler("launching")

    let launcher = MinecraftLauncher(instance)

    // 沿用原启动流程中启动前的最小化设置
    // 令牌注入按账号种类分派：离线/Yggdrasil 注入「UUID 本身」（PCL2 规则），
    // 微软账号注入真实的 Minecraft access token（三种 `putAccessToken` 均为同步实现）。
    switch options.account {
    case .offline(let account):
        account.putAccessToken(options: options)
    case .microsoft(let ms):
        ms.putAccessToken(options: options)
    case .yggdrasil(let account):
        account.putAccessToken(options: options)
    case nil:
        break
    }

    // MARK: Java 选择：统一走 manifest 优先的动态策略（收口到 JavaResolver，P3-1）
    // 原先这里有一段「DataManager 为空时触发 JavaManager.preScanJavaAsync + 3s 等待」的预扫描：
    // SLCore 直连 Features/Java 的 JavaManager（审计判据 A 分层倒置）。收口后不做预扫描——
    // `JavaResolver` 内部（DefaultJavaRepository.installed → 空则 refresh 强制重扫）已覆盖
    // 同样的扫描语义，无需在桥接层提前触发、也不必等 DataManager 预热。

    // 1) 读取 manifest.javaVersion（API 后端数据源），推断兜底
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

        // 回退：尝试通过 DataManager 选择（JavaResolver 内部扫描时已同步填充 DataManager。
        // DataManager 是 SLCore 内部数据源，此处不构成跨层倒置）
        if selectedJavaURL == nil, let jvm = MinecraftInstance.findSuitableJava(instance.version, minJavaVersion: minJavaVersion, manifest: instance.manifest) {
            selectedJavaURL = jvm.executableURL
            log("通过 DataManager 自动选择 Java: \(jvm.executableURL.path) (major=\(jvm.version), callMethod=\(jvm.callMethod))")
        }
    }

    guard let finalJavaURL = selectedJavaURL, fm.isExecutableFile(atPath: finalJavaURL.path) else {
        let available = DataManager.shared.javaVirtualMachines.map { "\($0.executableURL.path) (major=\($0.version), \($0.callMethod))" }
        log("未找到满足版本要求 (Java \(minJavaVersion)+) 的 Java 安装")
        log("DataManager JVMs: \(available.joined(separator: "; "))")
        // 2026-10-02：结构化错误（此前 MyLocalizedError 携带文案，mapFailure 靠
        // requiredJavaMajor 正则从文案提取版本号反猜）。errorDescription 逐字一致。
        completion(nil, .failure(LaunchError.javaNotFound(requiredMajorVersion: minJavaVersion)))
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

    // 取消判定点 ⑤：最后的闸门，紧挨着唯一的不可逆动作（拉起进程）之前。
    // 放在这里而不是更早，是为了覆盖耗时最长的「Java 选择」窗口：用户可能在扫描/解析
    // 期间才点取消，此时前面三个判定点都还没轮到。
    if abortIfCancelled("不再拉起游戏进程") { return }

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
                // 本次读取无完整日志行：让出 400ms 再读下一批（日志事实上的生产节奏比这快，
                // 但空读时不能忙轮询空转 CPU；400ms 上限让日志面板刷新不至于肉眼可辨滞后）。
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
            // 窗口未出现：每 2s 重查一次（CGWindowList 是快照式 API，立即重查无意义；
            // 2s 让「窗口检测」不忙轮询，同时游戏窗口出现后首次检测的滞后可接受）。
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
                // 2026-10-02：结构化错误（此前 MyLocalizedError("启动失败：…")，mapFailure 靠
                // contains 反猜）；processStartFailed 的 errorDescription 即「游戏进程启动失败：」。
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("启动失败：\(reason)")
                completion(launcher, .failure(LaunchError.processStartFailed(reason: reason)))
            }
        }
    }
}
