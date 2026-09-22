import Foundation

// MARK: - Java 管理器（参考 PCL.Mac 实现）

class JavaManager {
    static let shared = JavaManager()
    private let appSupportPath: URL
    private let javaBasePath: URL
    private let cache = AppContext.shared.cacheManager
    private var cachedJavaList: [JavaInfo]?
    private var isScanning = false
    /// 扫描状态锁。同时充当「已有扫描在途」的等待条件：`scanInstalledJava` 在扫描进行中
    /// 不在主线程忙等，而是**等待在途扫描结束**后取它的结果（见 `waitForScanCompletionLocked`）。
    private let scanLock = NSCondition()
    /// 等待在途扫描结束的上限（秒）。超时即放弃等待、返回已有缓存，避免调用方被无限阻塞。
    private static let scanWaitTimeout: TimeInterval = 10

    private init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        appSupportPath = paths[0].appendingPathComponent("SL启动器")
        javaBasePath = appSupportPath.appendingPathComponent("java")
        try? FileManager.default.createDirectory(at: javaBasePath, withIntermediateDirectories: true)
    }

    var currentArch: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let machineString = String(cString: machine)
        return machineString.hasPrefix("arm64") ? "aarch64" : "x64"
    }

    func loadCachedJavaPath() -> String? {
        return cache.object(String.self, forKey: "cachedJavaPath")
    }

    func saveCachedJavaPath(_ path: String) {
        cache.setObject(path, forKey: "cachedJavaPath")
    }

    func preScanJavaAsync() {
        DispatchQueue.global(qos: .background).async {
            let list = self.scanInstalledJava(useCache: false)
            DispatchQueue.main.async {
                LauncherSettings.shared.availableJavaList = list
                LauncherSettings.shared.isJavaScanning = false
                self.syncJavaVirtualMachines(from: list)
            }
        }
    }

    func refreshAvailableJavaList(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = self.scanInstalledJava(useCache: false)
            DispatchQueue.main.async {
                LauncherSettings.shared.availableJavaList = list
                completion?()
            }
        }
    }

    // MARK: - Java 扫描（参考 PCL.Mac：读 release 文件，不跑 java -version）

    /// 扫描本机 Java（缓存命中优先，否则真扫）。
    ///
    /// **「扫描中」不得表现为「没有 Java」**：`isScanning` 期间旧实现返回 `cachedJavaList ?? []`，
    /// 这个空数组会被 `refreshAvailableJavaList` / `resolveJavaExecutable` 当成「本机无 Java」——
    /// UI 因此显示「未找到 Java 环境」，启动链路也可能选不到 Java。
    /// 现在改为**等待在途扫描结束后返回它的结果**：`NSCondition` 条件等待（配对 `broadcast`），
    /// 不轮询、不忙等。调用方因此不必区分「扫描中」与「确实没有」——扫描中的等待会拿到真实结果。
    func scanInstalledJava(useCache: Bool = true) -> [JavaInfo] {
        scanLock.lock()
        if useCache, let cached = cachedJavaList {
            scanLock.unlock()
            return cached
        }
        if isScanning {
            let result = waitForScanCompletionLocked()
            scanLock.unlock()
            return result
        }
        isScanning = true
        scanLock.unlock()

        defer {
            scanLock.lock()
            isScanning = false
            // 条件等待必须配对唤醒：否则所有等待者只能挂到超时（无谓的最长 10s 延迟）
            scanLock.broadcast()
            scanLock.unlock()
        }

        if useCache, let cachedPaths: [String] = cache.object([String].self, forKey: "cachedJavaPaths") {
            var cachedInfos: [JavaInfo] = []
            for path in cachedPaths {
                if let info = parseJavaVersion(at: path) {
                    cachedInfos.append(info)
                }
            }
            if !cachedInfos.isEmpty {
                scanLock.lock()
                cachedJavaList = cachedInfos
                scanLock.unlock()
                DispatchQueue.main.async {
                    self.syncJavaVirtualMachines(from: cachedInfos)
                }
                return cachedInfos
            }
        }

        // 7 类路径发现已下沉到 JavaDiscovery（java_home -V / 默认版本 / JVM 目录 / Homebrew /
        // SDKMAN / 常见路径 / which java），返回去重后的可执行文件路径，这里只做版本解析。
        var results: [JavaInfo] = []
        let discovered = JavaDiscovery.discoverExecutables(basePath: javaBasePath)
        for javaBin in discovered {
            if let info = parseJavaVersion(at: javaBin) {
                results.append(info)
            }
        }

        scanLock.lock()
        cachedJavaList = results
        scanLock.unlock()

        cache.setObject(results.map { $0.path }, forKey: "cachedJavaPaths")

        // 同步到 DataManager 供启动流程使用
        DispatchQueue.main.async {
            self.syncJavaVirtualMachines(from: results)
        }

        return results
    }

    /// 在**已持有 `scanLock`** 的前提下等待在途扫描结束，返回其最终结果。
    ///
    /// - 非主线程（本方法的既有调用点全部如此：预扫描与 `refreshAvailableJavaList` 走全局队列、
    ///   仓储走 detached task、启动桥接走 GCD 工作线程）：用 `NSCondition` 让出 CPU 等到
    ///   `broadcast`，不引入新的忙等——这与启动链路既有的「订阅发布流 + 有界等待」是同一口径。
    /// - 主线程：不阻塞（阻塞主线程就是冻结 UI），返回已有缓存；扫描状态由
    ///   `LauncherSettings.isJavaScanning` 对 UI 表达，仍不会被当成「没有 Java」。
    private func waitForScanCompletionLocked() -> [JavaInfo] {
        guard !Thread.isMainThread else { return cachedJavaList ?? [] }
        let deadline = Date().addingTimeInterval(Self.scanWaitTimeout)
        while isScanning {
            if !scanLock.wait(until: deadline) { break }
        }
        // 在途扫描的 `defer` 在置 `isScanning = false` 之前就已写回缓存，
        // 因此这里读到的必然是本次扫描的结果（或超时兜底时上一轮的结果）。
        return cachedJavaList ?? []
    }

    private func syncJavaVirtualMachines(from infos: [JavaInfo]) {
        let existingPaths = Set(DataManager.shared.javaVirtualMachines.map { $0.executableURL.path })
        var newJVMs: [JavaVirtualMachine] = []
        for info in infos {
            guard !existingPaths.contains(info.path) else { continue }
            let url = URL(fileURLWithPath: info.path)
            let arch: Architecture = info.architecture == "arm64" ? .arm64 : (info.architecture == "x86_64" || info.architecture == "x64" ? .x64 : .getArchOfFile(url))
            let callMethod: CallMethod = arch == Architecture.system ? .direct : (Architecture.system == .arm64 ? .transition : .incompatible)
            let jvm = JavaVirtualMachine(
                arch: arch,
                version: info.majorVersion,
                displayVersion: info.fullVersion,
                implementor: info.vendor,
                executableURL: url,
                callMethod: callMethod,
                isJdk: nil
            )
            newJVMs.append(jvm)
        }
        if !newJVMs.isEmpty {
            DataManager.shared.javaVirtualMachines.append(contentsOf: newJVMs)
        }
    }

    // MARK: - 版本解析（优先读 release 文件，不行再跑 java -version；主体在 JavaVersionParser）

    func parseJavaVersion(at path: String) -> JavaInfo? {
        guard let info = JavaVersionParser.parse(at: path) else { return nil }
        // 缓存写入留在管理器中：解析器保持无副作用
        if info.majorVersion >= 8 {
            saveCachedJavaPath(path)
        }
        return info
    }

    func selectBestJava(requiredMajor: Int, from list: [JavaInfo]) -> JavaInfo? {
        if let cachedPath = loadCachedJavaPath(),
           let cachedInfo = list.first(where: { $0.path == cachedPath }),
           cachedInfo.majorVersion >= requiredMajor && cachedInfo.architecture == currentArch {
            return cachedInfo
        }
        let compatible = list.filter { $0.majorVersion >= requiredMajor && $0.architecture == currentArch }
        if let best = compatible.sorted(by: { $0.majorVersion > $1.majorVersion }).first {
            saveCachedJavaPath(best.path)
            return best
        }
        return nil
    }

    /// 解析一个可用的 Java 可执行文件：优先用户显式选择的 Java，其次扫描列表中的最佳版本，最后回退系统自带。
    static func resolveJavaExecutable(minimumMajor: Int = 8) -> URL? {
        if let selected = LauncherSettings.shared.selectedJavaPath,
           FileManager.default.isExecutableFile(atPath: selected) {
            return URL(fileURLWithPath: selected)
        }
        let list = JavaManager.shared.scanInstalledJava(useCache: true)
        if let best = JavaManager.shared.selectBestJava(requiredMajor: minimumMajor, from: list) {
            return URL(fileURLWithPath: best.path)
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/java") {
            return URL(fileURLWithPath: "/usr/bin/java")
        }
        return nil
    }

    // MARK: - Java 下载（参考 PCL.Mac：Azul Zulu API；主体在 JavaDownloader）

    func downloadJava(version: Int, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        JavaDownloader.download(version: version, basePath: javaBasePath, arch: currentArch, progressHandler: progressHandler, completion: completion)
    }
}