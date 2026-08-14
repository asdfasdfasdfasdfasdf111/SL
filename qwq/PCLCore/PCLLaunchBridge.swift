import Foundation
import Cocoa

/// 兼容层：桥接旧 UI 代码到 PCL.Mac 启动核心
extension MinecraftLauncher {
    /// 取消标志（兼容旧 UI 的关闭按钮逻辑，当前为桩实现）
    public var isCancelled: Bool {
        get { false }
        set { /* no-op stub: 同步 launch 调用无法中途取消 */ }
    }
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
    public func resolveGameDirURL() throws -> URL {
        return instance.runningDirectory
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
    /// 用 objc 关联对象存储 isUserTerminated（不修改 PCL.Mac 核心类的存储）
    private var _objCIsUserTerminated: Bool {
        get { (objc_getAssociatedObject(self, &_objCIsUserTerminatedKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &_objCIsUserTerminatedKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    private var _objCPendingLogs: [String] {
        get { (objc_getAssociatedObject(self, &_objCPendingLogsKey) as? NSArray) as? [String] ?? [] }
        set { objc_setAssociatedObject(self, &_objCPendingLogsKey, newValue as NSArray, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// 兼容启动入口：从旧 UI 参数构建 PCL.Mac 实例并启动
/// 注意：本函数不阻塞，立即返回；启动过程通过回调通知 UI
public func pclLaunch(
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
        pclLaunchInternal(
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

private func pclLaunchInternal(
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

    // 离线用户名 PCL2 风格校验（空 → "Player" 兜底；含引号 / 超过 16 字符 → 直接失败）。
    // 1.20.5+ 的 ServerboundHelloPacket 编码时 writeUtf(name, 16) 强校验：
    //   超过 16 字符抛 EncoderException "String too big (was N characters, max 16)"，
    // 表现为进服务器/开局域网时报 Failed to encode packet 'serverbound/minecraft:hello'
    var safeUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    if safeUsername.isEmpty { safeUsername = "Player" }
    let nameError = validateOfflineUsername(safeUsername)
    guard nameError.isEmpty else {
        completion(nil, .failure(MyLocalizedError(reason: "离线登录参数无效：\(nameError)")))
        return
    }

    let minecraftDir = MinecraftDirectory(
        rootURL: URL(fileURLWithPath: resolvedGameDir),
        name: "默认文件夹"
    )

    guard let instance = MinecraftInstance.create(minecraftDir, version) else {
        completion(nil, .failure(MyLocalizedError(reason: "无法创建实例: \(version)")))
        return
    }

    // 设置离线账号（PCL2 移植：UUID 走 McLoginLegacyUuid，accessToken = UUID）
    let account = OfflineAccount(safeUsername)
    let options = LaunchOptions()
    options.playerName = safeUsername
    options.uuid = account.uuid
    options.account = .offline(account)
    options.skipResourceCheck = true

    // MARK: 启动前补全（PCL2 DlClientFix 移植）：分析缺失/损坏的库与资源 → 仅下载缺失项
    // 补全期间 UI 显示 downloading 进度条；完成后才进入 launching（避免相位回退）
    // 补全失败则终止启动（与 PCL2 一致），避免缺文件启动后崩溃
    let fixResultBox = FixResultBox()
    let fixSemaphore = DispatchSemaphore(value: 0)
    phaseHandler("downloading")
    Task {
        do {
            try await LaunchFix.perform(instance: instance) { p in
                progressHandler(p)
            }
            log("启动前补全完成：缺失的库/资源已补齐")
        } catch {
            fixResultBox.error = error
            log("启动前补全失败: \(error.localizedDescription)")
        }
        fixSemaphore.signal()
    }
    fixSemaphore.wait()

    if let fixError = fixResultBox.error {
        completion(nil, .failure(MyLocalizedError(reason: "启动前补全失败：\(fixError.localizedDescription)")))
        return
    }

    phaseHandler("launching")

    let launcher = MinecraftLauncher(instance)!

    // 复刻 MinecraftInstance.launch 中启动前的最小化设置
    account.putAccessToken(options: options)

    // MARK: Java 选择：统一走 manifest 优先的动态策略
    // 1) 确保已触发 Java 扫描（若 DataManager 中为空）
    if DataManager.shared.javaVirtualMachines.isEmpty {
        log("DataManager 中暂无 JVM，触发预扫描")
        JavaManager.shared.preScanJavaAsync()
        // 后台线程短等待扫描结果（最多 3s），避免启动空窗
        let deadline = Date().addingTimeInterval(3)
        while DataManager.shared.javaVirtualMachines.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
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
        // 尝试通过 DataManager 选择（已被 JavaManager.syncJavaVirtualMachines 填充）
        if let jvm = MinecraftInstance.findSuitableJava(instance.version, minJavaVersion: minJavaVersion, manifest: instance.manifest) {
            selectedJavaURL = jvm.executableURL
            log("通过 DataManager 自动选择 Java: \(jvm.executableURL.path) (major=\(jvm.version), callMethod=\(jvm.callMethod))")
        } else {
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
        guard let handle = try? FileHandle(forReadingAtPath: logURL.path) else { return }
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
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    // 后台轮询检测 MC 窗口出现，触发 launchSuccess（2s 间隔：CGWindowList 全量遍历较贵，降频省 CPU）
    let windowTask = Task.detached(priority: .utility) {
        var fired = false
        while !Task.isCancelled, !fired {
            if let process = launcher.currentProcess, process.isRunning {
                let cgOptions = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
                if let windowInfoList = CGWindowListCopyWindowInfo(cgOptions, kCGNullWindowID) as? [[String: Any]] {
                    for info in windowInfoList {
                        if let windowPID = info["kCGWindowOwnerPID"] as? Int32,
                           windowPID == process.processIdentifier {
                            reportLaunchSuccess()
                            fired = true
                            break
                        }
                    }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // 在后台线程调用 launch（会阻塞到进程退出）
    DispatchQueue.global(qos: .userInitiated).async {
        launcher.launch(options) { exitCode in
            logTask.cancel()
            windowTask.cancel()
            // 窗口检测任务已触发则为幂等跳过；此处兜底保证正常退出也能复位 UI
            if exitCode == 0 { reportLaunchSuccess() }
            completion(launcher, .success(exitCode))
        }
    }
}

/// 扩展 MinecraftInstance 以支持从路径创建
extension MinecraftInstance {
    public static func createFromPaths(
        minecraftDirPath: String,
        versionId: String
    ) -> MinecraftInstance? {
        let minecraftDir = MinecraftDirectory(
            rootURL: URL(fileURLWithPath: minecraftDirPath),
            name: "默认文件夹"
        )
        return MinecraftInstance.create(minecraftDir, versionId)
    }
}

/// 跨线程传递启动前补全的错误结果（后台线程用信号量同步等待 Task 完成）
private final class FixResultBox {
    var error: Error?
}
