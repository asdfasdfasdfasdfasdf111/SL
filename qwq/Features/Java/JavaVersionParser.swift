//
//  JavaVersionParser.swift
//  模块化拆分：Java 版本解析（从 JavaManager.swift 拆出）
//  优先读 release 文件，失败回退 java -version，再用 file 命令检测架构
//

import Foundation

enum JavaVersionParser {

    /// 解析 java 可执行文件的版本信息（不写缓存；缓存写入由调用方 JavaManager 完成）
    static func parse(at path: String) -> JavaInfo? {
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
            // 启动成功后再起读取线程：与 ProcessPool 同款写法，避免「未连接管道的 read 永久阻塞」泄漏线程
            DispatchQueue.global().async {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                drain.signal()
            }
            if sem.wait(timeout: .now() + 10) == .timedOut {
                task.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                drain.wait()  // 回收后台读取线程，避免超时后线程泄漏
                return nil
            }
            drain.wait()  // 进程已退出 ⇒ 读必完成，再安全使用 data
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
            let fileSem = DispatchSemaphore(value: 0)
            let fileDrain = DispatchSemaphore(value: 0)
            fileTask.terminationHandler = { _ in fileSem.signal() }
            var fileData = Data()
            do {
                try fileTask.run()
            } catch {
                // 启动失败：架构探测不可用，保持 unknown 回落，直接返回（不进入等待，避免空等 10 秒）
                let normalizedArch = arch == "x64" ? "x64" : (arch == "arm64" ? "aarch64" : arch)
                return JavaInfo(path: javaBin, majorVersion: majorVersion, fullVersion: displayVersion, architecture: normalizedArch, vendor: vendor, isValid: true)
            }
            // 启动成功后再起读取线程：与 ProcessPool 同款写法，避免未连接管道的 read 永久阻塞
            DispatchQueue.global().async {
                fileData = filePipe.fileHandleForReading.readDataToEndOfFile()
                fileDrain.signal()
            }
            // 超时视为探测失败：kill 进程并回收读取线程，arch 保持 unknown 回落（绝不继续使用未完成的缓冲）
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

        let normalizedArch = arch == "x86_64" ? "x64" : (arch == "arm64" ? "aarch64" : arch)

        let info = JavaInfo(path: javaBin, majorVersion: majorVersion, fullVersion: displayVersion, architecture: normalizedArch, vendor: vendor, isValid: true)
        return info
    }
}
