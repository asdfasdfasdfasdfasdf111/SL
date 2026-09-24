//
//  Util.swift
//  SL启动器
//
//  通用工具集：读 jar 清单、解析 Maven 坐标、模板字符串替换、解压、算 SHA-1、URL 换根。
//
//  ⚠️ 本类型是「一堆静态函数的容器」而非真正的领域抽象 —— 它同时服务下载、安装、
//  启动三条链路。往这里加函数之前，先想想是不是该落到更贴切的类型里。
//
//  性能约定：正则一律在文件顶部**静态预编译**（`static let`），绝不在函数体内
//  `try? NSRegularExpression(...)` —— 正则编译的开销远高于匹配本身。
//
//  Created by YiZhiMCQiu on 2025/6/18.
//

import Foundation
import ZIPFoundation
import CryptoKit

/// 静态工具命名空间（成员全是 `static`，不该被实例化）。
public class Util {
    // 正则编译开销远高于匹配；以下字面量一次编译、全程复用（原写在方法体内每次调用重编译）。
    private static let mainClassRegex = try? NSRegularExpression(pattern: "(?m)^Main-Class:\\s*([^\\r\\n]+)")
    /// Maven 坐标正则的**源串**单独留一份：只用于构造下面的 regex，
    /// 把模式文本摆在这里是为了排查「它到底匹配什么」时一眼能看见。
    /// 分组含义：1 groupId、2 artifactId、3 version、4 classifier、5 packaging。
    private static let mavenCoordinatePattern = #"^([^:]+):([^:]+):([^:@]+)(?::([^@]+))?(?:@(.+))?$"#
    private static let mavenCoordinateRegex = try? NSRegularExpression(pattern: mavenCoordinatePattern)

    /// 从 jar 的 META-INF/MANIFEST.MF 中读取 `Main-Class`。**失败一律返回 nil**
    /// （不是 zip / 没有该条目 / 没有 Main-Class 行 / 正则没匹配上），细节只进日志 ——
    /// 调用方必须自己准备兜底主类。
    public static func getMainClass(_ jarURL: URL) -> String? {
        do {
            let archive = try Archive(url: jarURL, accessMode: .read)
            let data = try ArchiveUtil.getEntryOrThrow(archive: archive, name: "META-INF/MANIFEST.MF")
            // MANIFEST.MF 可能非 UTF-8（任意 forge jar 来源），强解包会崩；失败时按行解码兜底
            // 兜底用的是 `String(decoding:as:)` —— 把非法字节替换成 U+FFFD，而不是「按行解码」。
            // 目的只是让一份字节有问题的清单不至于整体读不出来。
            let manifest = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

            // 复用文件顶部静态预编译的 mainClassRegex，避免每次调用都重新编译（原实现在方法体内重复编译）
            guard let regex = Self.mainClassRegex else { return nil }
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
    
    /// 解析 Maven 坐标 `groupId:artifactId:version[:classifier][@packaging]`。
    ///
    /// **永不失败**：畸形字符串会被整串塞进 groupId / artifactId 并记一条日志。
    /// 于是后续 `toPath` 会拼出一个必然 404 的路径 —— 症状表现为「下载失败」，
    /// 而不是崩溃或一条清晰的参数错误。
    public static func parse(mavenCoordinate: String) -> MavenCoordinate {
        // 复用文件顶部静态预编译的 mavenCoordinateRegex（mavenCoordinatePattern 仅用于构造它），
        // 避免每次调用都重新编译正则，并消除原实现「先 range(of:) 再对子串编译正则二次匹配」的冗余。
        // 匹配失败（畸形库名）时按整串兜底返回，避免启动器崩溃（语义与原实现一致）。
        guard let regex = Self.mavenCoordinateRegex else {
            err("无法编译 Maven 坐标正则")
            return MavenCoordinate(mavenCoordinate, "", "", classifier: nil, packaging: nil)
        }
        let nsrange = NSRange(mavenCoordinate.startIndex..., in: mavenCoordinate)
        guard let result = regex.firstMatch(in: mavenCoordinate, options: [], range: nsrange) else {
            err("无法解析 Maven 坐标: \(mavenCoordinate)")
            return MavenCoordinate(mavenCoordinate, "", "", classifier: nil, packaging: nil)
        }
        func group(_ i: Int) -> String? {
            guard let range = Range(result.range(at: i), in: mavenCoordinate) else { return nil }
            return String(mavenCoordinate[range])
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
    
    /// 把 Maven 坐标转成仓库内的相对路径：groupId 的点换成斜杠，
    /// 末尾附 `-classifier` 与 `.packaging`（两者都缺省为无 / `jar`）。
    /// 这是官方仓库与镜像仓库**共用的路径规则** —— 两边都靠它拼 URL。
    public static func toPath(mavenCoordinate: String) -> String {
        let coord = parse(mavenCoordinate: mavenCoordinate)
        return "\(coord.groupId.replacingOccurrences(of: ".", with: "/"))/\(coord.artifactId)/\(coord.version)/\(coord.artifactId)-\(coord.version)"
        + (coord.classifier != nil ? "-" + coord.classifier! : "")
        + "." + (coord.packaging != nil ? coord.packaging! : "jar")
    }
    
    /// 把启动参数里的占位符替换成实际值，同时支持 `${key}` 与 `{key}` 两种写法
    /// （Mojang 新/旧两代清单各用一种）。
    ///
    /// ⚠️ 两种写法的替换**顺序不能交换**：`${key}` 里包含子串 `{key}`，
    /// 若先替换 `{key}`，`${key}` 会变成 `$<值>`（凭空多出一个 `$`）。
    /// 这正是实现里先 `${...}` 后 `{...}` 的原因。
    ///
    /// ⚠️ 字典里**没有的 key 会原样保留**（占位符不会被清空），它会一路带进 JVM 命令行，
    /// 最终表现为游戏侧的参数解析错误，而不是启动器提前给出提示。
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
    /// - Parameter replace: 目标已存在同名文件时，是否**先删除再解压**。默认 true（覆盖）。
    ///   传 false 则保留已有文件、直接让 `Archive.extract` 去写
    ///   （ZIPFoundation 对已存在条目的处理不是覆盖，可能抛错并被下面 catch 记下）。
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
                // replace = false 时保留已有文件；true 时先删掉再解，确保拿到的是归档里的版本。
                // ⚠️ 目录条目必须跳过这一步删除：目录条目同样会命中 `fileExists`（此前解出的子文件
                // 已隐式把该目录建出来），删掉它等于连刚解出的一整棵子树一起删，而函数仍返回 true
                // → 子文件静默缺失（natives 目录尤其致命）。目录条目交给下面的 extract 自行创建即可。
                if entry.type != .directory,
                   FileManager.default.fileExists(atPath: destinationFileURL.path) && replace {
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
    
    /// 流式算整文件 SHA-1（1MB 块，内存占用与文件大小无关），返回小写十六进制。
    /// 与 `FileChecker` 里那套「出错就 `try?` 吞掉」不同，这里**读取出错会向上抛** ——
    /// 调用方能区分「文件读不了」与「算出来了」。缓存层（CacheStorage）依赖这个区别。
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
    
    /// 把 URL 中的 `root` 前缀替换成 `target`（用于把「未列出」版本的清单地址改写到镜像）。
    /// 这是**纯字符串前缀替换**，不做域名/路径校验；替换后若拼不出合法 URL，就原样返回入参。
    /// 返回 `any URLConvertible` 是为了直接回填给 SwiftyJSON 的 `.url` 属性。
    public static func replaceRoot(url: any URLConvertible, root: String, target: String) -> any URLConvertible {
        // 替换后字符串可能非法（URL 特殊字符），强解包会崩；失败时返回原始 URL
        guard let resolved = url.url else { return url }
        let replaced = resolved.absoluteString.replacingOccurrences(of: root, with: target)
        return URL(string: replaced) ?? url
    }

    /// 运行进程并等待退出，超时后强制终止（防止 Forge 处理器/glfw-patcher 挂起导致安装线程永久阻塞）。
    ///
    /// 终止是**两级**的：先 `terminate()`（SIGTERM，给进程 0.5 秒收尾机会），
    /// 仍在运行才 `kill(SIGKILL)` 硬杀。超时**抛错**而不是返回 false，
    /// 让调用方无法把这次失败当成正常结束。
    ///
    /// ⚠️ 本方法是同步阻塞的：在哪个线程调用，就占用哪个线程整整 `timeout` 的时间。
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

/// Maven 坐标的解析结果。三段必需信息是非可选 String，
/// 但**解析失败时它们会被塞进整串坐标**而不是抛错（见 `Util.parse`）——
/// 因此不能把「字段非空」当作「解析成功」的证据。
public struct MavenCoordinate {
    public let groupId: String
    public let artifactId: String
    public let version: String
    public let classifier: String?
    public let packaging: String?
    
    /// 构造器是 internal（没有 `public`）：外部只能通过 `Util.parse(mavenCoordinate:)`
    /// 拿到实例，从而保证所有解析都经过同一套畸形输入兜底逻辑。
    init(_ groupId: String, _ artifactId: String, _ version: String, classifier: String? = nil, packaging: String? = nil) {
        self.groupId = groupId
        self.artifactId = artifactId
        self.version = version
        self.classifier = classifier
        self.packaging = packaging
    }
}
