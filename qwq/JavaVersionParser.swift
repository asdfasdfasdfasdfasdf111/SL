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
        return info
    }
}
