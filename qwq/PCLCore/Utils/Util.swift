//
//  Util.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/6/18.
//

import Foundation
import ZIPFoundation
import CryptoKit

public class Util {
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
    
    public static func formatJSON(_ jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            let prettyData = try JSONSerialization.data(
                withJSONObject: jsonObject,
                options: [.prettyPrinted]
            )
            return String(data: prettyData, encoding: .utf8)
        } catch {
            err("JSON格式化失败: \(error.localizedDescription)")
            return nil
        }
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
    
    public static func unzip(archiveURL: URL, destination: URL, replace: Bool = true) {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            err("无法读取文件: \(error.localizedDescription)")
            return
        }
        
        for entry in archive {
            do {
                // ZIP Slip 防御：拒绝绝对路径与包含 .. 的条目，防止写入目标目录之外
                let entryPath = entry.path.replacingOccurrences(of: "\\", with: "/")
                let normalizedPath = (entryPath as NSString).standardizingPath
                if normalizedPath.hasPrefix("/") || normalizedPath.components(separatedBy: "/").contains("..") {
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
            }
        }
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
    
    public static func getFileName(url: URL) -> String? {
        var urlString = url.absoluteString
        if urlString.hasSuffix("/") { return nil }
        
        if let qIndex = urlString.firstIndex(of: "?") {
            urlString = String(urlString[..<qIndex])
        }
        
        if let lastBackslash = urlString.lastIndex(of: "/") {
            let fileNameStart = urlString.index(after: lastBackslash)
            urlString = String(urlString[fileNameStart...])
        }
        return urlString
    }
    
    public static func replaceRoot(url: any URLConvertible, root: String, target: String) -> any URLConvertible {
        // 替换后字符串可能非法（URL 特殊字符），强解包会崩；失败时返回原始 URL
        let replaced = url.url.absoluteString.replacingOccurrences(of: root, with: target)
        return URL(string: replaced) ?? url
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
