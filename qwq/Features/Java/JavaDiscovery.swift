import Foundation

// MARK: - Java 可执行文件发现（自 JavaManager 拆出）
// 负责扫描 macOS 上全部 7 类常见 Java 来源，返回去重后的 java 可执行文件路径数组。
// 不做版本解析（解析在 JavaManager.parseJavaVersion / JavaVersionParser）。
//
// ⚠️ 本类型是**纯同步阻塞**的：7 类来源里两处会起子进程（`java_home -V`、`which java`）、
// 两处会递归遍历目录（/Library/Java、/opt/homebrew/opt …）。在界面线程直接调用会明显卡顿，
// 调用方应放进后台任务。
//
// ⚠️ 去重按**解析符号链接后的真实路径**做（不是输入字符串）——
// 所以 `/usr/bin/java` 与它指向的真实 jdk 只会保留一个，**先扫到的那个胜出**；
// 而扫描顺序就是下面 MARK 1 → 7 的顺序（`java_home -V` 的结果排在最前）。

/// java 可执行文件的发现器（全部静态方法，无状态）。
enum JavaDiscovery {
    /// 正则编译开销远高于匹配；字面量一次编译、全程复用（原写在循环内每次调用重编译）。
    /// 匹配 `java_home -V` 的输出行，形如：
    ///     `17.0.9 (arm64) "Azul Systems, Inc." - "Zulu 17" /Library/Java/.../zulu-17.jdk/Contents/Home`
    /// 分组 1 = 版本号，分组 2 = 该 JDK 的 Home 路径（调用处会拼上 `/bin/java`）。
    /// 调用处必须 `.trimmingCharacters` —— 末尾的 `\s+(.+)$` 会把行尾空白一起吃进分组 2。
    private static let javaHomeVersionRegex = try? NSRegularExpression(pattern: #"\s+(\d+(?:\.\d+)*)\s+\([^)]+\)\s+"[^"]*"\s+-\s+"[^"]*"\s+(.+)$"#)

    /// 扫描全部来源，返回去重后的 java 可执行文件路径（未验证存在性之外的解析）。
    /// 扫描全部来源。`basePath` 是启动器自己的目录（用于找随启动器分发的 java）。
    /// 返回值已按真实路径去重，顺序即下面 MARK 1→7 的先后。
    static func discoverExecutables(basePath: URL) -> [String] {
        var visitedPaths = Set<String>()
        var results: [String] = []
        let fm = FileManager.default

        /// 唯一收口：先解析符号链接归一化，再判「没扫过 && 可执行」才收。
        /// ⚠️ 归一化是去重的关键 —— 调用方给的可能是软链（`/usr/bin/java`）、
        /// 也可能是真实路径，不归一化会被当成两个不同的 java。
        func addIfExecutable(_ javaBin: String) {
            let normalized = (javaBin as NSString).resolvingSymlinksInPath
            guard !visitedPaths.contains(normalized), fm.isExecutableFile(atPath: normalized) else { return }
            visitedPaths.insert(normalized)
            results.append(normalized)
        }

        // MARK: 1. /usr/libexec/java_home -V (最可靠的系统级 Java 发现方式)
        // `-V` 把已注册的 JDK 全列到 **stderr**（故必须 captureStderr: true）——
        // 这是 macOS 上最可靠的系统级 Java 发现方式。
        if let output = runProcess("/usr/libexec/java_home", args: ["-V"], captureStderr: true) {
            let lines = output.split(separator: "\n")
            for line in lines {
                let lineStr = String(line)
                if let regex = Self.javaHomeVersionRegex,
                   let match = regex.firstMatch(in: lineStr, range: NSRange(location: 0, length: lineStr.utf16.count)),
                   match.numberOfRanges > 2,
                   let pathRange = Range(match.range(at: 2), in: lineStr) {
                    let javaPath = String(lineStr[pathRange]).trimmingCharacters(in: .whitespaces)
                    addIfExecutable(javaPath + "/bin/java")
                }
            }
        }

        // MARK: 2. java_home 默认版本
        // 不带参数调用 = 问「系统当前默认的 JDK 是哪个」，与上面的全量列表互补
        //（默认那个未必能在 -V 的输出里被正则解析成功）。
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
            // enumerator 是**深度优先递归**的；命中一个 java 就 skipDescendants() 剪枝 ——
            // 否则一个 JDK 目录下几十个同名 bin/java 会被反复加入（虽被去重，但白扫一遍）。
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
        // 两代 Homebrew 前缀都试（Apple Silicon = /opt/homebrew，Intel = /usr/local）。
        // 每个 openjdk 包下有两条可能路径都试：`libexec/openjdk.jdk/Contents/Home/bin/java`
        //（Homebrew 的 JDK 封装）与直接的 `bin/java`。
        let brewPrefixes = ["/opt/homebrew/opt", "/usr/local/opt"]
        for brewPrefix in brewPrefixes {
            if let contents = try? fm.contentsOfDirectory(atPath: brewPrefix) {
                for item in contents where item.hasPrefix("openjdk") || item == "java" {
                    addIfExecutable(brewPrefix + "/" + item + "/libexec/openjdk.jdk/Contents/Home/bin/java")
                    addIfExecutable(brewPrefix + "/" + item + "/bin/java")
                }
            }
            // Cellar 才是 Homebrew 的真实安装目录（opt 只是软链）。
            // 从 `/opt/homebrew/opt` 去掉尾部 3 个字符（"opt"）再拼 "Cellar"
            // → `/opt/homebrew/Cellar`。
            let cellarPath = brewPrefix.hasSuffix("/opt") ? String(brewPrefix.dropLast(3)) + "Cellar" : brewPrefix + "/Cellar"
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
        // 优先读环境变量 SDKMAN_DIR，没有再回落默认目录 ~/.sdkman。
        let sdkmanDir = ProcessInfo.processInfo.environment["SDKMAN_DIR"] ?? (NSHomeDirectory() + "/.sdkman")
        let sdkmanJava = sdkmanDir + "/candidates/java"
        if let versions = try? fm.contentsOfDirectory(atPath: sdkmanJava) {
            for version in versions {
                addIfExecutable(sdkmanJava + "/" + version + "/bin/java")
            }
        }

        // MARK: 6. 其他常见路径
        // 覆盖：官方 pkg 安装（/usr/bin/java 是个转发壳）、HMCL 自带运行时、
        // Android Studio 与 IDEA 捆绑的 JBR、Adoptium 安装包、以及已废弃的 JavaApplet 插件。
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
        // 用 shell 的解析结果兜最后一道：能捞到用户 PATH 里自定义的 jdk。
        // ⚠️ 代价是依赖 PATH —— 从 Finder 双击启动时 PATH 与终端里不同，
        // 这一条的结果可能与终端里跑出来的不一样。
        if let whichOutput = runProcess("/usr/bin/which", args: ["java"]),
           !whichOutput.isEmpty {
            let whichJava = whichOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            addIfExecutable(whichJava)
        }

        return results
    }

    /// 执行命令（使用 ProcessPool）。
    /// ⚠️ 返回 nil 与返回空串含义不同：nil = 进程起不来 / 超时（输出全部丢弃），
    /// 空串 = 命令成功跑完但没输出。三个调用点都按「非空才算数」处理。
    private static func runProcess(_ launchPath: String, args: [String], captureStderr: Bool = false) -> String? {
        AppContext.shared.processPool.execute(
            launchPath, args: args, timeout: 10, captureStderr: captureStderr
        )
    }
}
