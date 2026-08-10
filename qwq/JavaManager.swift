import Foundation

// MARK: - Java 管理器（参考 PCL.Mac 实现）

class JavaManager {
    static let shared = JavaManager()
    private let appSupportPath: URL
    private let javaBasePath: URL
    private let cache = AppContext.shared.cacheManager
    private var cachedJavaList: [JavaInfo]?
    private var isScanning = false
    private let scanLock = NSLock()

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

    func clearCachedJavaPath() {
        cache.removeObject(forKey: "cachedJavaPath")
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

    func refreshAvailableJavaList() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = self.scanInstalledJava(useCache: false)
            DispatchQueue.main.async {
                LauncherSettings.shared.availableJavaList = list
            }
        }
    }

    // MARK: - Java 扫描（参考 PCL.Mac：读 release 文件，不跑 java -version）

    func scanInstalledJava(useCache: Bool = true) -> [JavaInfo] {
        scanLock.lock()
        if useCache, let cached = cachedJavaList {
            scanLock.unlock()
            return cached
        }
        if isScanning {
            let fallback = cachedJavaList ?? []
            scanLock.unlock()
            return fallback
        }
        isScanning = true
        scanLock.unlock()

        defer {
            scanLock.lock()
            isScanning = false
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