//
//  Util.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/6/18.
//

import Foundation
import ZIPFoundation
import CryptoKit

public class Util {
    // 正则编译开销远高于匹配；以下字面量一次编译、全程复用（原写在方法体内每次调用重编译）。
    private static let mainClassRegex = try? NSRegularExpression(pattern: "(?m)^Main-Class:\\s*([^\\r\\n]+)")
    private static let mavenCoordinatePattern = #"^([^:]+):([^:]+):([^:@]+)(?::([^@]+))?(?:@(.+))?$"#
    private static let mavenCoordinateRegex = try? NSRegularExpression(pattern: mavenCoordinatePattern)

    public static func getMainClass(_ jarURL: URL) -> String? {
        do {
            let archive = try Archive(url: jarURL, accessMode: .read)
            let data = try ArchiveUtil.getEntryOrThrow(archive: archive, name: "META-INF/MANIFEST.MF")
            // MANIFEST.MF 可能非 UTF-8（任意 forge jar 来源），强解包会崩；失败时按行解码兜底
            let manifest = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

            let regex = try NSRegularExpression(pattern: "(?m)^Main-Class:\\s*([^\\r\\n]+)")
            if let match = regex.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)),
               match.numberOfRanges > 1,
               let mainRange = Range(match.range(at: 1), in: manifest) {
                return String(manifest[mainRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            err("无法获取主类: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    public static func parse(mavenCoordinate: String) -> MavenCoordinate {
        let pattern = #"^([^:]+):([^:]+):([^:@]+)(?::([^@]+))?(?:@(.+))?$"#
        // 旧实现强解包：外部 JSON（版本清单/Forge 安装配置）中任何畸形库名都会直接崩溃。
        // 改为安全解析：匹配失败时把整串当 groupId 兜底返回，避免启动器崩溃。
        guard let r = mavenCoordinate.range(of: pattern, options: .regularExpression) else {
            err("无法解析 Maven 坐标: \(mavenCoordinate)")
            return MavenCoordinate(mavenCoordinate, "", "", classifier: nil, packaging: nil)
        }
        let match = String(mavenCoordinate[r])
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return MavenCoordinate(mavenCoordinate, "", "", classifier: nil, packaging: nil)
        }
        let nsrange = NSRange(match.startIndex..<match.endIndex, in: match)
        guard let result = regex.firstMatch(in: match, options: [], range: nsrange) else {
            return MavenCoordinate(mavenCoordinate, "", "", classifier: nil, packaging: nil)
        }
        func group(_ i: Int) -> String? {
            guard let range = Range(result.range(at: i), in: match) else { return nil }
            return String(match[range])
        }
        // 三组必需捕获（groupId/artifactId/version）缺失时用整串兜底，剩余分组可能为 nil
        return MavenCoordinate(
            group(1) ?? mavenCoordinate,
            group(2) ?? mavenCoordinate,
            group(3) ?? "",
            classifier: group(4),
            packaging: group(5)
        )
    }
    
    public static func toPath(mavenCoordinate: String) -> String {
        let coord = parse(mavenCoordinate: mavenCoordinate)
        return "\(coord.groupId.replacingOccurrences(of: ".", with: "/"))/\(coord.artifactId)/\(coord.version)/\(coord.artifactId)-\(coord.version)"
        + (coord.classifier != nil ? "-" + coord.classifier! : "")
        + "." + (coord.packaging != nil ? coord.packaging! : "jar")
    }
    
    public static func replaceTemplateStrings(_ strings: [String], with dict: [String: String]) -> [String] {
        return strings.map { original in
            var result = original
            for (key, value) in dict {
                result = result
                    .replacingOccurrences(of: "${\(key)}", with: value)
                    .replacingOccurrences(of: "{\(key)}", with: value)
            }
            return result
        }
    }
    
    /// 解压 ZIP 到目标目录。
    ///
    /// 返回值：`true` = 归档可读且所有条目均解压成功；`false` = 归档打不开，或至少有一个条目解压失败
    /// （失败原因已由 `err` 记录）。原实现返回 `Void`，失败只记日志，调用方无法区分成败，
    /// 于是「解压失败」被当成成功继续往下走（如 natives 缺失却在安装/启动时无人察觉）。
    /// 加 `@discardableResult` 保持对「忽略返回值」的既有调用方的源兼容。
    @discardableResult
    public static func unzip(archiveURL: URL, destination: URL, replace: Bool = true) -> Bool {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            err("无法读取文件: \(error.localizedDescription)")
            return false
        }
        
        var succeeded = true
        for entry in archive {
            do {
                // ZIP Slip 防御：拒绝绝对路径与包含 .. 的条目，防止写入目标目录之外
                let entryPath = entry.path.replacingOccurrences(of: "\\", with: "/")
                let normalizedPath = (entryPath as NSString).standardizingPath
                if normalizedPath.hasPrefix("/") || normalizedPath.components(separatedBy: "/").contains("..") {
                    // 主动跳过危险条目属安全决策，不计为解压失败（与调用方的「可见失败」语义无关）
                    err("已跳过存在路径遍历风险的条目: \(entry.path)")
                    continue
                }
                let destinationFileURL = destination.appendingPathComponent(normalizedPath)
                if FileManager.default.fileExists(atPath: destinationFileURL.path) && replace {
                    try FileManager.default.removeItem(at: destinationFileURL)
                    debug("已删除重复文件 \(destinationFileURL.lastPathComponent)")
                }
                _ = try archive.extract(entry, to: destinationFileURL)
            } catch {
                err("无法解压文件: \(error.localizedDescription)")
                succeeded = false
            }
        }
        return succeeded
    }
    
    public static func sha1OfFile(url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        
        var hasher = Insecure.SHA1()
        while true {
            let data = try fileHandle.read(upToCount: 1024 * 1024)
            if let data = data, !data.isEmpty {
                hasher.update(data: data)
            } else {
                break
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func replaceRoot(url: any URLConvertible, root: String, target: String) -> any URLConvertible {
        // 替换后字符串可能非法（URL 特殊字符），强解包会崩；失败时返回原始 URL
        let replaced = url.url.absoluteString.replacingOccurrences(of: root, with: target)
        return URL(string: replaced) ?? url
    }

    /// 运行进程并等待退出，超时后强制终止（防止 Forge 处理器/glfw-patcher 挂起导致安装线程永久阻塞）
    public static func runProcessWithTimeout(_ process: Process, timeout: TimeInterval) throws {
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        try process.run()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw MyLocalizedError(reason: "进程超时（\(Int(timeout))秒），已强制终止")
        }
    }
}

public struct MavenCoordinate {
    public let groupId: String
    public let artifactId: String
    public let version: String
    public let classifier: String?
    public let packaging: String?
    
    init(_ groupId: String, _ artifactId: String, _ version: String, classifier: String? = nil, packaging: String? = nil) {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.classifier = classifier
        self.packaging = packaging
    }
}
