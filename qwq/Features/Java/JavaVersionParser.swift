//
//  JavaVersionParser.swift
//  模块化拆分：Java 版本解析（从 JavaManager.swift 拆出）
//  优先读 release 文件，失败回退 java -version，再用 file 命令检测架构
//

//
//  JavaVersionParser.swift
//  模块化拆分：Java 版本解析（从 JavaManager.swift 拆出）
//  优先读 release 文件，失败回退 java -version，再用 file 命令检测架构
//
//  ⚠️ 本类型**只解析、不缓存** —— 要不要缓存、缓存键怎么算，由调用方 JavaManager 决定。
//  所以同一路径重复调用会重复起进程（代价见下方超时说明）。
//
//  ⚠️ 两处「失败即保持 unknown」是刻意的保守策略：拿不准就报未知，绝不猜 ——
//  猜错会把 x64 的 java 当成 arm64 去启动游戏，症状比「架构未知」严重得多。
//

import Foundation

/// java 可执行文件版本 / 厂商 / 架构的解析器（全部静态方法，无状态）。
enum JavaVersionParser {

    /// 解析 java 可执行文件的版本信息（不写缓存；缓存写入由调用方 JavaManager 完成）。
    ///
    /// ⚠️ 最坏情况**同步阻塞可达 20 秒**：`java -version` 与 `file` 各允许 10 秒超时，
    /// 两条兜底路径都可能起进程 —— 不要在界面线程直接调用。
    /// 返回 nil 的三种情形：release 读不到且 java 起不来、进程超时、输出无法按 UTF-8 解码。
    static func parse(at path: String) -> JavaInfo? {
        let javaBin = (path as NSString).resolvingSymlinksInPath
        let homeDir = ((javaBin as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent

        // 优先读 release 文件（PCL.Mac 的做法，不需要启动进程）
        // ⚠️ 数组里的两个候选其实是**同一个路径算了两遍**（下面那个表达式的含义与 homeDir 完全相同），
        // 保留成数组只是为将来可能出现的层级差异留位；当前等价于「只试一次」。
        let releasePaths = [
            homeDir + "/release",
            ((javaBin as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/release"
        ]

        var majorVersion = 0
        var displayVersion = "未知"
        var vendor: String? = nil
        var arch = "unknown"

        // 两个字段都从同一个 release 文件里取：JAVA_VERSION= 定版本，IMPLEMENTOR= 定厂商。
        // 第一个成功解析出主版本号的文件即 break（`if majorVersion > 0 { break }`）。
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
                    // 1.x 时代真版本号在第二段（`1.8.0_392` → 8）；其余取第一段（`17.0.9` → 17）。
                    // 1.x 实际只到 1.8，故这个近似在真实数据上成立。
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

        // 如果 release 文件解析失败，回退到 java -version。
        // 这一段是全文件最重的一步：起进程 + 双信号量（先等进程退出、再等管道读干），
        // 后者是为避免「进程已退出但管道还有未读数据」的竞态。
        if majorVersion == 0 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: javaBin)
            task.arguments = ["-version"]
            let pipe = Pipe()
            task.standardError = pipe
            let sem = DispatchSemaphore(value: 0)
            let drain = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in sem.signal() }
            var data = Data()
            do {
                try task.run()
            } catch {
                // 启动失败（如二进制不可执行）：无法解析版本，直接返回 nil，避免进入等待而空等 10 秒
                return nil
            }
            // 启动成功后再起读取线程：与 ProcessPool 同款写法，避免「未连接管道的 read 永久阻塞」泄漏线程。
            // 两个信号量分工：sem 等进程退出、drain 等读线程收工 —— 两者都等到才能安全使用 data。
            DispatchQueue.global().async {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                drain.signal()
            }
            // 10 秒超时：先 terminate（SIGTERM）、给 0.5 秒收尾，仍在跑才 SIGKILL。
            // 之后必须 drain.wait() 回收读线程，否则每超时一次就漏一个线程。
            if sem.wait(timeout: .now() + 10) == .timedOut {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                drain.wait()  // 回收后台读取线程，避免超时后线程泄漏
                return nil
            }
            drain.wait()  // 进程已退出 ⇒ 读必完成，再安全使用 data
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // 先按现代格式 `version "17.0.9"` 抓主版本；
            let versionPattern = #"version "(\d+)"#
            if let regex = try? NSRegularExpression(pattern: versionPattern),
               let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: output.utf16.count)) {
                majorVersion = Int((output as NSString).substring(with: match.range(at: 1))) ?? 0
            } else {
                // 抓不到再按老的 `1.8.0_392` 形态抓第二段（1.x 时代的真版本号）。
                let oldPattern = #"version "1\.(\d+)"#
                if let regex = try? NSRegularExpression(pattern: oldPattern),
                   let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: output.utf16.count)) {
                    majorVersion = Int((output as NSString).substring(with: match.range(at: 1))) ?? 0
                }
            }

            // 架构从 `java -version` 输出里猜 —— 注意在 Rosetta 下这里会得到 x86_64
            //（进程视角），而非物理机架构。
            if output.contains("aarch64") || output.contains("arm64") { arch = "arm64" }
            else if output.contains("x86_64") || output.contains("64-Bit") { arch = "x86_64" }

            // 厂商用一个「已知厂商名」白名单去撞，撞到哪个就取哪个 ——
            // 名单外的发行版（小众构建）保持 nil，界面上不显示厂商，而不是瞎猜一个。
            if let vendorRange = output.range(of: #"(?:Oracle|Azul|Eclipse|IBM|Microsoft|Amazon|Red Hat|Tencent|Alibaba|Huawei|BellSoft|SAP|AdoptOpenJDK|OpenJDK)"#, options: .regularExpression) {
                vendor = String(output[vendorRange])
            }
            // 兜底路径只拿得到「主版本」这一个数字，展示版本号就退化成它本身
            //（不像读 release 那样有完整的 `17.0.9+8-LTS`）。
            displayVersion = "\(majorVersion)"
        }

        // 用 file 命令检测架构（PCL.Mac 做法）。
        // 只在前面两条路径都没定出架构时才走这里 —— 用 `file` 读 Mach-O 头比跑 java 便宜，
        // 但前两步若能给出结论就不必再跑。
        if arch == "unknown" {
            let fileTask = Process()
            fileTask.executableURL = URL(fileURLWithPath: "/usr/bin/file")
            fileTask.arguments = [javaBin]
            let filePipe = Pipe()
            fileTask.standardOutput = filePipe
            let fileSem = DispatchSemaphore(value: 0)
            let fileDrain = DispatchSemaphore(value: 0)
            fileTask.terminationHandler = { _ in fileSem.signal() }
            var fileData = Data()
            do {
                try fileTask.run()
            } catch {
                // 启动失败：架构探测不可用，保持 unknown 回落，直接返回（不进入等待，避免空等 10 秒）。
                // ⚠️ 这里仍然返回 `isValid: true` —— isValid 表达的是「路径合法、可执行」，
                // 不含「架构已知」的意思。
                let normalizedArch = arch == "x64" ? "x64" : (arch == "arm64" ? "aarch64" : arch)
                return JavaInfo(path: javaBin, majorVersion: majorVersion, fullVersion: displayVersion, architecture: normalizedArch, vendor: vendor, isValid: true)
            }
            // 启动成功后再起读取线程：与 ProcessPool 同款写法，避免未连接管道的 read 永久阻塞
            DispatchQueue.global().async {
                fileData = filePipe.fileHandleForReading.readDataToEndOfFile()
                fileDrain.signal()
            }
            // 超时视为探测失败：kill 进程并回收读取线程，arch 保持 unknown 回落（绝不继续使用未完成的缓冲）。
            // ⚠️ 注意这里**不 return** —— 架构未知同样返回 isValid: true 的 JavaInfo；
            // 它只影响后续的兼容性判断，不影响这个 java 被登记进列表。
            let timedOut = fileSem.wait(timeout: .now() + 10) == .timedOut
            if timedOut {
                fileTask.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if fileTask.isRunning { kill(fileTask.processIdentifier, SIGKILL) }
            }
            fileDrain.wait()  // 无论是否超时均回收读取线程，避免线程泄漏
            if !timedOut {
                let fileOutput = String(data: fileData, encoding: .utf8) ?? ""
                if fileOutput.contains("arm64") { arch = "arm64" }
                else if fileOutput.contains("x86_64") { arch = "x86_64" }
            }
        }

        // 统一架构命名：x86_64 → x64、arm64 → aarch64（其余原样透传，可能是 "unknown"）。
        let normalizedArch = arch == "x86_64" ? "x64" : (arch == "arm64" ? "aarch64" : arch)

        // ⚠️ 无论如何都返回 `isValid: true` —— 本方法只负责「解析出了什么」；
        // 「这个 java 能不能跑这个游戏」由 JavaVirtualMachine 的 CallMethod 判定。
        let info = JavaInfo(path: javaBin, majorVersion: majorVersion, fullVersion: displayVersion, architecture: normalizedArch, vendor: vendor, isValid: true)
        return info
    }
}
