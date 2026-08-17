import Foundation

// MARK: - Java 可执行文件发现（自 JavaManager 拆出）
// 负责扫描 macOS 上全部 7 类常见 Java 来源，返回去重后的 java 可执行文件路径数组。
// 不做版本解析（解析在 JavaManager.parseJavaVersion / JavaVersionParser）。

enum JavaDiscovery {
    /// 扫描全部来源，返回去重后的 java 可执行文件路径（未验证存在性之外的解析）。
    static func discoverExecutables(basePath: URL) -> [String] {
        var visitedPaths = Set<String>()
        var results: [String] = []
        let fm = FileManager.default

        func addIfExecutable(_ javaBin: String) {
            let normalized = (javaBin as NSString).resolvingSymlinksInPath
            guard !visitedPaths.contains(normalized), fm.isExecutableFile(atPath: normalized) else { return }
            visitedPaths.insert(normalized)
            results.append(normalized)
        }

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
                    addIfExecutable(javaPath + "/bin/java")
                }
            }
        }

        // MARK: 2. java_home 默认版本
        if let defaultPath = runProcess("/usr/libexec/java_home", args: []),
           !defaultPath.isEmpty {
            let trimmed = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
            addIfExecutable(trimmed + "/bin/java")
        }

        // MARK: 3. 扫描所有已知 JVM 目录
        let jvmParents = [
            "/Library/Java/JavaVirtualMachines",
            NSHomeDirectory() + "/Library/Java/JavaVirtualMachines",
            basePath.path,
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
                    addIfExecutable(javaBin)
                    enumerator.skipDescendants()
                } else if itemPath.hasSuffix(".jdk") || itemPath.hasSuffix(".jre") {
                    addIfExecutable(fullPath + "/Contents/Home/bin/java")
                    enumerator.skipDescendants()
                }
            }
        }

        // MARK: 4. Homebrew (Intel + Apple Silicon)
        let brewPrefixes = ["/opt/homebrew/opt", "/usr/local/opt"]
        for brewPrefix in brewPrefixes {
            if let contents = try? fm.contentsOfDirectory(atPath: brewPrefix) {
                for item in contents where item.hasPrefix("openjdk") || item == "java" {
                    addIfExecutable(brewPrefix + "/" + item + "/libexec/openjdk.jdk/Contents/Home/bin/java")
                    addIfExecutable(brewPrefix + "/" + item + "/bin/java")
                }
            }
            let cellarPath = brewPrefix.replacingOccurrences(of: "/opt", with: "/opt/Cellar")
                .replacingOccurrences(of: "/usr/local/opt", with: "/usr/local/Cellar")
            if let contents = try? fm.contentsOfDirectory(atPath: cellarPath) {
                for item in contents where item.hasPrefix("openjdk") {
                    let itemPath = cellarPath + "/" + item
                    if let versions = try? fm.contentsOfDirectory(atPath: itemPath) {
                        for version in versions {
                            addIfExecutable(itemPath + "/" + version + "/libexec/openjdk.jdk/Contents/Home/bin/java")
                            addIfExecutable(itemPath + "/" + version + "/bin/java")
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
                addIfExecutable(sdkmanJava + "/" + version + "/bin/java")
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
            addIfExecutable(javaBin)
        }

        // MARK: 7. which java
        if let whichOutput = runProcess("/usr/bin/which", args: ["java"]),
           !whichOutput.isEmpty {
            let whichJava = whichOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            addIfExecutable(whichJava)
        }

        return results
    }

    /// 执行命令（使用 ProcessPool）
    private static func runProcess(_ launchPath: String, args: [String], captureStderr: Bool = false) -> String? {
        AppContext.shared.processPool.execute(
            launchPath, args: args, timeout: 10, captureStderr: captureStderr
        )
    }
}
