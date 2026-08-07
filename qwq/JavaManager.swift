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

        var results: [JavaInfo] = []
        var visitedPaths = Set<String>()
        let fm = FileManager.default

        // MARK: 1. /usr/libexec/java_home -V (最可靠的系统级 Java 发现方式)
        if let output = runProcess("/usr/libexec/java_home", args: ["-V"], captureStderr: true) {
            let lines = output.split(separator: "\n")
            for line in lines {
                let lineStr = String(line)
                let pattern = #"\s+(\d+(?:\.\d+)*)\s+\([^)]+\)\s+"[^"]*"\s+-\s+"[^"]*"\s+(.+)$"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: lineStr, range: NSRange(location: 0, length: lineStr.utf16.count)),
                   match.numberOfRanges > 2,
                   let pathRange = Range(match.range(at: 2), in: lineStr) {
                    let javaPath = String(lineStr[pathRange]).trimmingCharacters(in: .whitespaces)
                    let javaBin = javaPath + "/bin/java"
                    if fm.isExecutableFile(atPath: javaBin) {
                        let normalized = (javaBin as NSString).resolvingSymlinksInPath
                        if !visitedPaths.contains(normalized) {
                            visitedPaths.insert(normalized)
                            if let info = parseJavaVersion(at: javaBin) {
                                results.append(info)
                            }
                        }
                    }
                }
            }
        }

        // MARK: 2. java_home 默认版本
        if let defaultPath = runProcess("/usr/libexec/java_home", args: []),
           !defaultPath.isEmpty {
            let trimmed = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let javaBin = trimmed + "/bin/java"
            if fm.isExecutableFile(atPath: javaBin) {
                let normalized = (javaBin as NSString).resolvingSymlinksInPath
                if !visitedPaths.contains(normalized) {
                    visitedPaths.insert(normalized)
                    if let info = parseJavaVersion(at: javaBin) {
                        results.append(info)
                    }
                }
            }
        }

        // MARK: 3. 扫描所有已知 JVM 目录
        let jvmParents = [
            "/Library/Java/JavaVirtualMachines",
            NSHomeDirectory() + "/Library/Java/JavaVirtualMachines",
            javaBasePath.path,
            "/usr/lib/jvm",
            "/opt/java",
            NSHomeDirectory() + "/java",
            NSHomeDirectory() + "/.jdks"
        ]

        for parent in jvmParents {
            guard let enumerator = fm.enumerator(atPath: parent) else { continue }
            for case let itemPath as String in enumerator {
                let fullPath = parent + "/" + itemPath
                let javaBin = fullPath + "/bin/java"
                if fm.isExecutableFile(atPath: javaBin) {
                    let normalized = (javaBin as NSString).resolvingSymlinksInPath
                    if !visitedPaths.contains(normalized) {
                        visitedPaths.insert(normalized)
                        if let info = parseJavaVersion(at: javaBin) {
                            results.append(info)
                        }
                    }
                    enumerator.skipDescendants()
                } else if itemPath.hasSuffix(".jdk") || itemPath.hasSuffix(".jre") {
                    let contentHomeJava = fullPath + "/Contents/Home/bin/java"
                    if fm.isExecutableFile(atPath: contentHomeJava) {
                        let normalized = (contentHomeJava as NSString).resolvingSymlinksInPath
                        if !visitedPaths.contains(normalized) {
                            visitedPaths.insert(normalized)
                            if let info = parseJavaVersion(at: contentHomeJava) {
                                results.append(info)
                            }
                        }
                        enumerator.skipDescendants()
                    }
                }
            }
        }

        // MARK: 4. Homebrew (Intel + Apple Silicon)
        let brewPrefixes = ["/opt/homebrew/opt", "/usr/local/opt"]
        for brewPrefix in brewPrefixes {
            // openjdk@17, openjdk@21 等
            if let contents = try? fm.contentsOfDirectory(atPath: brewPrefix) {
                for item in contents where item.hasPrefix("openjdk") || item == "java" {
                    let candidates = [
                        brewPrefix + "/" + item + "/libexec/openjdk.jdk/Contents/Home/bin/java",
                        brewPrefix + "/" + item + "/bin/java"
                    ]
                    for javaBin in candidates {
                        if fm.isExecutableFile(atPath: javaBin) {
                            let normalized = (javaBin as NSString).resolvingSymlinksInPath
                            if !visitedPaths.contains(normalized) {
                                visitedPaths.insert(normalized)
                                if let info = parseJavaVersion(at: javaBin) {
                                    results.append(info)
                                }
                            }
                        }
                    }
                }
            }
            // Cellar 路径
            let cellarPath = brewPrefix.replacingOccurrences(of: "/opt", with: "/opt/Cellar")
                .replacingOccurrences(of: "/usr/local/opt", with: "/usr/local/Cellar")
            if let contents = try? fm.contentsOfDirectory(atPath: cellarPath) {
                for item in contents where item.hasPrefix("openjdk") {
                    let itemPath = cellarPath + "/" + item
                    if let versions = try? fm.contentsOfDirectory(atPath: itemPath) {
                        for version in versions {
                            let candidates = [
                                itemPath + "/" + version + "/libexec/openjdk.jdk/Contents/Home/bin/java",
                                itemPath + "/" + version + "/bin/java"
                            ]
                            for javaBin in candidates {
                                if fm.isExecutableFile(atPath: javaBin) {
                                    let normalized = (javaBin as NSString).resolvingSymlinksInPath
                                    if !visitedPaths.contains(normalized) {
                                        visitedPaths.insert(normalized)
                                        if let info = parseJavaVersion(at: javaBin) {
                                            results.append(info)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // MARK: 5. SDKMAN
        let sdkmanDir = ProcessInfo.processInfo.environment["SDKMAN_DIR"] ?? (NSHomeDirectory() + "/.sdkman")
        let sdkmanJava = sdkmanDir + "/candidates/java"
        if let versions = try? fm.contentsOfDirectory(atPath: sdkmanJava) {
            for version in versions {
                let javaBin = sdkmanJava + "/" + version + "/bin/java"
                if fm.isExecutableFile(atPath: javaBin) {
                    let normalized = (javaBin as NSString).resolvingSymlinksInPath
                    if !visitedPaths.contains(normalized) {
                        visitedPaths.insert(normalized)
                        if let info = parseJavaVersion(at: javaBin) {
                            results.append(info)
                        }
                    }
                }
            }
        }

        // MARK: 6. 其他常见路径
        let extraPaths = [
            "/usr/bin/java",
            NSHomeDirectory() + "/Library/Application Support/hmcl/runtime",
            "/Applications/HMCL.app/Contents/runtime",
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java",
            "/Applications/IntelliJ IDEA.app/Contents/jbr/Contents/Home/bin/java",
            "/Applications/Eclipse Adoptium/Contents/Home/bin/java",
            "/Library/Internet Plug-Ins/JavaApplet.plugin/Contents/Home/bin/java"
        ]
        for javaBin in extraPaths {
            if fm.isExecutableFile(atPath: javaBin) {
                let normalized = (javaBin as NSString).resolvingSymlinksInPath
                if !visitedPaths.contains(normalized) {
                    visitedPaths.insert(normalized)
                    if let info = parseJavaVersion(at: javaBin) {
                        results.append(info)
                    }
                }
            }
        }

        // MARK: 7. which java
        if let whichOutput = runProcess("/usr/bin/which", args: ["java"]),
           !whichOutput.isEmpty {
            let whichJava = whichOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if fm.isExecutableFile(atPath: whichJava) {
                let normalized = (whichJava as NSString).resolvingSymlinksInPath
                if !visitedPaths.contains(normalized) {
                    visitedPaths.insert(normalized)
                    if let info = parseJavaVersion(at: whichJava) {
                        results.append(info)
                    }
                }
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

    private func runProcess(_ launchPath: String, args: [String], captureStderr: Bool = false) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        if captureStderr {
            task.standardError = pipe
        } else {
            task.standardOutput = pipe
        }
        task.terminationHandler = { _ in }
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - 版本解析（优先读 release 文件，不行再跑 java -version）

    func parseJavaVersion(at path: String) -> JavaInfo? {
        let javaBin = (path as NSString).resolvingSymlinksInPath
        let homeDir = ((javaBin as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent

        // 优先读 release 文件（PCL.Mac 的做法，不需要启动进程）
        let releasePaths = [
            homeDir + "/release",
            ((javaBin as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/release"
        ]

        var majorVersion = 0
        var displayVersion = "未知"
        var vendor: String? = nil
        var arch = "unknown"

        for releasePath in releasePaths {
            guard let content = try? String(contentsOfFile: releasePath, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("JAVA_VERSION=") {
                    let raw = String(trimmed.dropFirst(13)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    // 去掉引号内的引号
                    displayVersion = raw.replacingOccurrences(of: "\"", with: "")
                    // 解析主版本号
                    let cleaned = displayVersion.replacingOccurrences(of: "\"", with: "")
                    if cleaned.hasPrefix("1.") {
                        majorVersion = Int(cleaned.split(separator: ".").dropFirst().first ?? "0") ?? 0
                    } else {
                        majorVersion = Int(cleaned.split(separator: ".").first ?? "0") ?? 0
                    }
                }
                if trimmed.hasPrefix("IMPLEMENTOR=") {
                    vendor = String(trimmed.dropFirst(13)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            if majorVersion > 0 { break }
        }

        // 如果 release 文件解析失败，回退到 java -version
        if majorVersion == 0 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: javaBin)
            task.arguments = ["-version"]
            let pipe = Pipe()
            task.standardError = pipe
            try? task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let versionPattern = #"version "(\d+)"#
            if let regex = try? NSRegularExpression(pattern: versionPattern),
               let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: output.utf16.count)) {
                majorVersion = Int((output as NSString).substring(with: match.range(at: 1))) ?? 0
            } else {
                let oldPattern = #"version "1\.(\d+)"#
                if let regex = try? NSRegularExpression(pattern: oldPattern),
                   let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: output.utf16.count)) {
                    majorVersion = Int((output as NSString).substring(with: match.range(at: 1))) ?? 0
                }
            }

            if output.contains("aarch64") || output.contains("arm64") { arch = "arm64" }
            else if output.contains("x86_64") || output.contains("64-Bit") { arch = "x86_64" }

            if let vendorRange = output.range(of: #"(?:Oracle|Azul|Eclipse|IBM|Microsoft|Amazon|Red Hat|Tencent|Alibaba|Huawei|BellSoft|SAP|AdoptOpenJDK|OpenJDK)"#, options: .regularExpression) {
                vendor = String(output[vendorRange])
            }
            displayVersion = "\(majorVersion)"
        }

        // 用 file 命令检测架构（PCL.Mac 做法）
        if arch == "unknown" {
            let fileTask = Process()
            fileTask.executableURL = URL(fileURLWithPath: "/usr/bin/file")
            fileTask.arguments = [javaBin]
            let filePipe = Pipe()
            fileTask.standardOutput = filePipe
            try? fileTask.run()
            let fileData = filePipe.fileHandleForReading.readDataToEndOfFile()
            fileTask.waitUntilExit()
            let fileOutput = String(data: fileData, encoding: .utf8) ?? ""
            if fileOutput.contains("arm64") { arch = "arm64" }
            else if fileOutput.contains("x86_64") { arch = "x86_64" }
        }

        let normalizedArch = arch == "x86_64" ? "x64" : (arch == "arm64" ? "aarch64" : arch)

        let info = JavaInfo(path: javaBin, majorVersion: majorVersion, fullVersion: displayVersion, architecture: normalizedArch, vendor: vendor, isValid: true)
        if majorVersion >= 8 {
            saveCachedJavaPath(javaBin)
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

    // MARK: - Java 下载（参考 PCL.Mac：Azul Zulu API）

    func downloadJava(version: Int, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        let arch = currentArch == "aarch64" ? "aarch64" : "x64"

        // 使用 Azul Zulu API 搜索可用版本
        let apiURL = "https://api.azul.com/metadata/v1/zulu/packages/?os=macos&archive_type=zip&java_version=\(version)&arch=\(arch)&java_package_type=jdk&latest=true"

        guard let url = URL(string: apiURL) else {
            completion(.failure(NSError(domain: "JavaManager", code: -1)))
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(NSError(domain: "JavaManager", code: -2))); return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let pkg = json.first,
                  let downloadURLStr = pkg["download_url"] as? String,
                  let downloadURL = URL(string: downloadURLStr),
                  let pkgName = pkg["name"] as? String else {
                // Azul API 失败，回退到 Microsoft JDK
                self.downloadMicrosoftJDK(version: version, arch: arch, progressHandler: progressHandler, completion: completion)
                return
            }

            let downloadTask = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, _, error in
                guard let self = self else { return }
                if let error = error { completion(.failure(error)); return }
                guard let tempURL = tempURL else { completion(.failure(NSError(domain: "JavaManager", code: -3))); return }

                let targetDir = self.javaBasePath.appendingPathComponent("jdk-\(version)")
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

                // 解压 zip
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-o", tempURL.path, "-d", targetDir.path]
                do {
                    try unzip.run()
                    unzip.waitUntilExit()
                } catch {
                    completion(.failure(error))
                    return
                }

                // 查找解压后的 java 可执行文件
                if let javaURL = self.findJavaExecutable(in: targetDir) {
                    completion(.success(javaURL))
                } else {
                    completion(.failure(NSError(domain: "JavaManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "解压后未找到 Java"])))
                }
            }
            let observation = downloadTask.progress.observe(\.fractionCompleted) { progress, _ in
                DispatchQueue.main.async { progressHandler(progress.fractionCompleted) }
            }
            objc_setAssociatedObject(downloadTask, "progressObserver", observation, .OBJC_ASSOCIATION_RETAIN)
            downloadTask.resume()
        }.resume()
    }

    private func downloadMicrosoftJDK(version: Int, arch: String, progressHandler: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        let urlString: String
        if version == 17 {
            urlString = arch == "aarch64" ? "https://aka.ms/download-jdk/microsoft-jdk-17-macOS-aarch64.tar.gz" : "https://aka.ms/download-jdk/microsoft-jdk-17-macOS-x64.tar.gz"
        } else if version == 21 {
            urlString = arch == "aarch64" ? "https://aka.ms/download-jdk/microsoft-jdk-21-macOS-aarch64.tar.gz" : "https://aka.ms/download-jdk/microsoft-jdk-21-macOS-x64.tar.gz"
        } else {
            completion(.failure(NSError(domain: "JavaManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的 Java 版本"])))
            return
        }
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "JavaManager", code: -2)))
            return
        }
        let downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            if let error = error { completion(.failure(error)); return }
            guard let tempURL = tempURL else { completion(.failure(NSError(domain: "JavaManager", code: -3))); return }
            let targetDir = self.javaBasePath.appendingPathComponent("jdk-\(version)")
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", tempURL.path, "-C", targetDir.path, "--strip-components=1"]
            do {
                try tar.run()
                tar.waitUntilExit()
                if tar.terminationStatus == 0, let javaURL = self.findJavaExecutable(in: targetDir) {
                    completion(.success(javaURL))
                } else {
                    completion(.failure(NSError(domain: "JavaManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "解压失败"])))
                }
            } catch { completion(.failure(error)) }
        }
        let observation = downloadTask.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async { progressHandler(progress.fractionCompleted) }
        }
        objc_setAssociatedObject(downloadTask, "progressObserver", observation, .OBJC_ASSOCIATION_RETAIN)
        downloadTask.resume()
    }

    private func findJavaExecutable(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == "java" && FileManager.default.isExecutableFile(atPath: fileURL.path) {
                return fileURL
            }
        }
        return nil
    }
}