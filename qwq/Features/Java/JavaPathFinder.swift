import Foundation

// JavaInfo → JavaInfo.swift（JavaManager/JavaVersionParser/ThemeManager 共享）
// JavaEnvironment + compareJavaVersions → JavaEnvironment.swift

/// Java 路径查找器（多来源全量扫描 + 内存缓存）。
final class JavaPathFinder {
    private let fileManager = FileManager.default
    private let processPool = AppContext.shared.processPool
    private let cache = AppContext.shared.cacheManager
    private let lock = NSLock()
    private var cachedEnvironments: [JavaEnvironment]?
    private var cachedPaths: [String]?

    init() {}

    func getAllJavaEnvironments() -> [JavaEnvironment] {
        lock.lock()
        if let cached = cachedEnvironments { lock.unlock(); return cached }
        lock.unlock()

        let environments = performFullScan()

        lock.lock()
        cachedEnvironments = environments
        lock.unlock()
        return environments
    }

    func getAllJavaPaths() -> [String] {
        lock.lock()
        if let cached = cachedPaths { lock.unlock(); return cached }
        lock.unlock()

        let paths = getAllJavaEnvironments().map { $0.path }

        lock.lock()
        cachedPaths = paths
        lock.unlock()
        return paths
    }

    func getRecommendedJava() -> JavaEnvironment? {
        guard let output = processPool.execute("/usr/libexec/java_home", args: []),
              !output.isEmpty else { return nil }
        let trimmedPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let javaBin = trimmedPath + "/bin/java"
        guard fileManager.fileExists(atPath: javaBin) else { return nil }
        return JavaEnvironment(path: trimmedPath,
                               version: getVersionFromPath(trimmedPath) ?? "Unknown",
                               vendor: nil,
                               isValid: true)
    }

    /// 清除缓存（内存警告时调用）
    func clearCache() {
        lock.lock()
        cachedEnvironments = nil
        cachedPaths = nil
        lock.unlock()
    }

    // MARK: - 核心扫描逻辑

    private func performFullScan() -> [JavaEnvironment] {
        var uniquePaths = Set<String>()

        // 1. 系统标准路径
        for path in scanDirectory("/Library/Java/JavaVirtualMachines") { uniquePaths.insert(path) }

        // 2. 用户自定义 JDK 路径
        for path in scanDirectory(NSHomeDirectory() + "/.jdks") { uniquePaths.insert(path) }

        // 3. SDKMAN
        if let sdkmanDir = ProcessInfo.processInfo.environment["SDKMAN_DIR"] {
            for path in scanDirectory(sdkmanDir + "/candidates/java") { uniquePaths.insert(path) }
        } else {
            for path in scanDirectory(NSHomeDirectory() + "/.sdkman/candidates/java") { uniquePaths.insert(path) }
        }

        // 4. Homebrew（intel + Apple Silicon）
        let brewPrefixes = ["/usr/local/opt", "/opt/homebrew/opt"]
        for brewPrefix in brewPrefixes {
            // 扫描 openjdk@17、openjdk@21 等
            if let contents = try? fileManager.contentsOfDirectory(atPath: brewPrefix) {
                for item in contents where item.hasPrefix("openjdk") {
                    let brewPath = brewPrefix + "/" + item
                    let resolvedPath = resolveSymlink(brewPath) + "/libexec/openjdk.jdk/Contents/Home"
                    if fileManager.fileExists(atPath: resolvedPath + "/bin/java") {
                        uniquePaths.insert(resolvedPath)
                    }
                }
            }
            // 默认 openjdk
            let defaultPath = brewPrefix + "/openjdk"
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: defaultPath, isDirectory: &isDir), isDir.boolValue {
                let resolvedPath = resolveSymlink(defaultPath) + "/libexec/openjdk.jdk/Contents/Home"
                if fileManager.fileExists(atPath: resolvedPath + "/bin/java") {
                    uniquePaths.insert(resolvedPath)
                }
            }
        }

        // 5. HMCL 及通用路径
        let hmclPaths = [
            "/Applications/HMCL.app/Contents/runtime",
            NSHomeDirectory() + "/Library/Application Support/hmcl/runtime",
            "/opt/java",
            NSHomeDirectory() + "/java"
        ]
        for hmclPath in hmclPaths {
            for path in scanDirectory(hmclPath) { uniquePaths.insert(path) }
        }

        // 6. java_home -V
        for path in getPathsFromJavaHomeV() { uniquePaths.insert(path) }

        // 7. /usr/bin/java + which java
        if fileManager.fileExists(atPath: "/usr/bin/java") {
            if let resolved = try? fileManager.destinationOfSymbolicLink(atPath: "/usr/bin/java") {
                let resolvedPath = resolved.hasPrefix("/") ? resolved : "/usr/bin/\(resolved)"
                let homeDir = ((resolvedPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                uniquePaths.insert(homeDir)
            }
        }
        // which java 获取 PATH 中的 Java
        if let whichOutput = processPool.execute("/usr/bin/which", args: ["java"]),
           !whichOutput.isEmpty {
            let whichJava = whichOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if fileManager.isExecutableFile(atPath: whichJava) {
                let homeDir = ((whichJava as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                uniquePaths.insert(homeDir)
            }
        }

        // 8. 额外常见路径
        let extraPaths = [
            "/usr/lib/jvm",
            NSHomeDirectory() + "/.sdkman/candidates/java",
            "/opt/homebrew/Cellar/openjdk",
            "/usr/local/Cellar/openjdk"
        ]
        for extraPath in extraPaths {
            for path in scanDirectory(extraPath) { uniquePaths.insert(path) }
        }

        // 组装
        var envs: [JavaEnvironment] = []
        for path in uniquePaths {
            let version = getVersionFromPath(path) ?? "Unknown"
            let isValid = validateJavaHome(path)
            envs.append(JavaEnvironment(path: path, version: version, vendor: nil, isValid: isValid))
        }
        envs.sort { compareJavaVersions($0.version, $1.version) == .orderedDescending }
        return envs
    }

    // MARK: - 辅助扫描

    private func scanDirectory(_ basePath: String) -> [String] {
        var results: [String] = []
        guard let enumerator = fileManager.enumerator(atPath: basePath) else { return results }
        for case let path as String in enumerator {
            let fullPath = basePath + "/" + path
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let javaBinPath = fullPath + "/bin/java"
            if fileManager.fileExists(atPath: javaBinPath) {
                results.append(fullPath)
                enumerator.skipDescendants()
            } else if path.hasSuffix(".jdk") || path.hasSuffix(".jre") {
                let contentHomeJava = fullPath + "/Contents/Home/bin/java"
                if fileManager.fileExists(atPath: contentHomeJava) {
                    results.append(fullPath + "/Contents/Home")
                    enumerator.skipDescendants()
                }
            }
        }
        return results
    }

    private func getPathsFromJavaHomeV() -> [String] {
        var paths: [String] = []
        guard let output = processPool.execute("/usr/libexec/java_home", args: ["-V"], captureStderr: true) else { return paths }
        let lines = output.split(separator: "\n")
        for line in lines {
            let lineStr = String(line)
            // 格式: "    21.0.1 (arm64) \"Microsoft\" - \"OpenJDK 21.0.1\" /path/to/home"
            let pattern = #"\s+\d+(?:\.\d+)*\s+\([^)]+\)\s+"[^"]*"\s+-\s+"[^"]*"\s+(.+)$"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: lineStr, range: NSRange(location: 0, length: lineStr.utf16.count)),
               match.numberOfRanges > 1,
               let pathRange = Range(match.range(at: 1), in: lineStr) {
                let javaPath = String(lineStr[pathRange]).trimmingCharacters(in: .whitespaces)
                if !javaPath.isEmpty {
                    paths.append(javaPath)
                }
            }
        }
        return paths
    }

    private func validateJavaHome(_ path: String) -> Bool {
        let javaBin = path + "/bin/java"
        guard fileManager.fileExists(atPath: javaBin) else { return false }
        return processPool.execute(javaBin, args: ["-version"], captureStderr: true) != nil
    }

    private func getVersionFromPath(_ path: String) -> String? {
        let patterns = [
            #"([0-9]+\.?[0-9]*\.?[0-9]*(?:_[0-9]+)?)"#,
            #"jdk[.-]?([0-9\._]+)"#,
            #"openjdk[.-]?([0-9\._]+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) {
                let versionRange = Range(match.range(at: 1), in: path)!
                return String(path[versionRange])
            }
        }
        return nil
    }

    private func resolveSymlink(_ path: String) -> String {
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) ?? path
    }
}