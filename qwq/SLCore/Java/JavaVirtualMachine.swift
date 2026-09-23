//
//  JavaEntity.swift
//  SL启动器
//
//  一个 JVM 的模型：可执行文件路径、架构、版本、以及**调用方式**。
//
//  `callMethod` 是本类型的核心：它回答「这个 java 在当前机器上能不能跑、怎么跑」，
//  挑 Java 的整套策略（优先原生直接跑，没有才退而用 Rosetta 转译）建立在它之上 ——
//  见 SLCore/Minecraft/MinecraftInstanceJava.swift 的 findSuitableJava。
//
//  ⚠️ 文件头注释里的名字（JavaEntity.swift）与当前文件名不一致：本文件被改过名，
//  头注释没跟着改，属文档残留。
//
//  Created by YiZhiMCQiu on 2025/5/18.
//

import Foundation

/// `Identifiable` 的 id 是**每次构造新生成的 UUID**：同一条 java 路径调用两次 `of()`
/// 也会得到两个不同的 id。因此 id 只用于 SwiftUI 列表 identity，
/// **不要拿它判断「是不是同一个 JVM」** —— 那个判断请用 `==`（只比可执行文件路径）。
public class JavaVirtualMachine: Identifiable, Equatable {
    /// 错误哨兵值：`of()` 拿到非法路径时返回它。
    /// ⚠️ 这是一个**共享的可变实例**（version / displayVersion / implementor 都是 var），
    /// 谁改了它，所有持有 `Error` 的调用方都会跟着变。
    /// 判定方式一律是 `isError`，不要拿某条具体路径去比较。
    static let Error = JavaVirtualMachine(arch: .unknown, version: -1, displayVersion: "错误", executableURL: URL(fileURLWithPath: "Error"), callMethod: .incompatible, _isError: true)
    
    public let arch: Architecture
    public var version: Int
    public var displayVersion: String
    public var implementor: String?
    public let executableURL: URL
    public let callMethod: CallMethod
    public let isJdk: Bool?
    /// 是否为哨兵值。底层 `_isError` 是 `Bool?`，nil 与 false 都算「正常」——
    /// 这样构造普通实例时不必显式传这个参数。
    public var isError: Bool {
        get {
            return _isError ?? false
        }
    }
    /// 是否由用户手工添加（而非自动扫描发现）。UI 据此区分展示方式与清理策略。
    public var isAddedByUser: Bool {
        get {
            return _isAddedByUser ?? false
        }
    }
    private var _isError: Bool?
    private var _isAddedByUser: Bool?
    
    // 每次构造都不同，仅用于 SwiftUI 列表 identity，不表示「同一个 JVM」。
    public let id = UUID()
    
    /// `_isError` / `_isAddedByUser` 刻意以下划线开头：提示它们「只给哨兵值与 `of()` 用」，
    /// 一般调用方不必传。
    public init(arch: Architecture, version: Int, displayVersion: String, implementor: String? = nil, executableURL: URL, callMethod: CallMethod, isJdk: Bool? = nil, _isError: Bool? = nil, _isAddedByUser: Bool? = nil) {
        self.arch = arch
        self.version = version
        self.displayVersion = displayVersion
        self.implementor = implementor
        self.executableURL = executableURL
        self.callMethod = callMethod
        self.isJdk = isJdk
        self._isError = _isError
        self._isAddedByUser = _isAddedByUser
    }
    
    /// UI 上的类型标签。`isJdk` 为 nil（未知，例如 `/usr/bin/java` 这种转发壳）时
    /// 一律显示 "Java"，不去猜 JDK 还是 JRE。
    func getTypeLabel() -> String {
        guard let isJdk = isJdk else {
            return "Java"
        }
        return isJdk ? "JDK" : "JRE"
    }
    
    /// 后台补测版本号（`of()` 没能从 release 文件读到时的兜底，见 `of()` 末尾）。
    /// ⚠️ 它会**直接改写本实例**的 version / displayVersion —— 属副作用；
    /// 调用方若已缓存过旧值，需要自行刷新。
    private func asyncDetectVersion() async {
        (version, displayVersion) = JavaVirtualMachine.detectVersion(url: executableURL)
    }
    
    /// 由 java 可执行文件路径构造模型。**永不抛错、永不返回 nil** ——
    /// 路径非法时返回共享的哨兵值 `Error`（用 `isError` 判定）。
    ///
    /// 版本号优先读 java 目录下的 `release` 文件（便宜，不起进程）；
    /// 两个候选位置都找不到时才**异步**跑一次 `java -version`。
    /// 因此 `of()` 刚返回时 version 可能是 0，稍后会被自己更新。
    public static func of(_ executableURL: URL, _ addedByUser: Bool? = nil) -> JavaVirtualMachine {
        // 判断文件是否合法
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            err("\(executableURL) not found!")
            return Error
        }
        guard executableURL.isFileURL else {
            err("\(executableURL.path) 不是文件!")
            return Error
        }
        
        // 设置架构及调用方式
        let arch: Architecture = .getArchOfFile(executableURL)
        let callMethod: CallMethod?
        // 调用方式判定三条分支：
        //   架构一致或通用二进制 → 原生直接跑；
        //   不一致但本机是 arm64 → 只能靠 Rosetta 转译（可用，但有性能损耗）；
        //   其余（本机 x64 却拿到 arm64 的 java）→ 不可用。
        if arch == Architecture.system || arch == .fatFile {
            callMethod = .direct
        } else if Architecture.system == .arm64 {
            callMethod = .transition
        } else {
            callMethod = .incompatible
        }
        
        // 获取版本信息
        // release 文件的两种常见位置：`<java_home>/release` 与 `<java_home>/../release`
        // （不同发行版的 bin 层级深浅不一，这里把两种都试一遍）。
        let releaseURLs = [
            executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("release"),
            executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("release")
        ]
        var version: Int = 0
        var displayVersion: String = "未知"
        var asyncDetect: Bool = true
        var implementor: String?
        
        for releaseURL in releaseURLs {
            if FileManager.default.fileExists(atPath: releaseURL.path) {
                let release = PropertiesParser.parse(fileURL: releaseURL)
                if let javaVersion = release["JAVA_VERSION"] {
                    displayVersion = javaVersion
                    // release 文件可能损坏/含非数字段（如空段），强解包会崩；失败回退 0（按未知版本处理）
                    // 主版本号取法：`1.8.0_392` 时代真版本在**第二段**（1.8 即 Java 8），
                    // 所以以 "1." 开头时取下标 1，否则取下标 0（`17.0.9` → 17）。
                    // 1.x 实际只有 1.0~1.8，故这个近似在真实数据上成立。
                    let parts = displayVersion.split(separator: ".")
                    let versionPart = parts.isEmpty ? "" : String(parts[displayVersion.starts(with: "1.") && parts.count > 1 ? 1 : 0])
                    version = Int(versionPart) ?? 0
                } else {
                    err("加载 \(executableURL.path) 时出现错误: 未找到键 JAVA_VERSION 对应的值")
                }
                implementor = release["IMPLEMENTOR"]
                asyncDetect = false
                break
            }
        }
        
        // 检查是否为 JDK
        var isJdk: Bool? = nil
        // 判定是否 JDK：看同目录下有没有 javac。
        // `/usr/bin/java` 是个转发壳，「同目录」对它没有意义，所以整个判定跳过 ——
        // 于是它的 isJdk 保持 nil，UI 显示 "Java"。
        if executableURL.path != "/usr/bin/java" {
            if FileManager.default.fileExists(atPath: executableURL.deletingLastPathComponent().appendingPathComponent("javac").path) {
                isJdk = true
            } else {
                isJdk = false
            }
        }
        
        let jvm = JavaVirtualMachine(arch: arch, version: version, displayVersion: displayVersion, implementor: implementor, executableURL: executableURL, callMethod: callMethod ?? .incompatible, isJdk: isJdk, _isAddedByUser: addedByUser)
        if asyncDetect {
            Task {
                await jvm.asyncDetectVersion()
            }
        }
        return jvm
    }
    
    /// 跑一次 `java -version` 并从输出里正则抓版本号（读不到 release 文件时的兜底路径）。
    ///
    /// 三个关键点：
    /// - stdout 与 stderr **都接进同一个 pipe**：不同发行版把版本信息印在不同的流上；
    /// - 用两个信号量先等进程退出、再等把管道读干，避免「进程已退出但管道还有未读数据」的竞态，
    ///   保证下面用 `data` 时是安全的；
    /// - 10 秒超时后**强杀进程**并返回 `(0, "未知")`，绝不无限等待。
    /// 任何失败都回落到 `(0, "未知")`，不抛错。
    private static func detectVersion(url: URL) -> (version: Int, displayVersion: String) {
        do {
            let process = Process()
            process.executableURL = url
            process.arguments = ["-version"]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            let sem = DispatchSemaphore(value: 0)
            let drain = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in sem.signal() }
            var data = Data()
            DispatchQueue.global().async {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                drain.signal()
            }
            if sem.wait(timeout: .now() + 10) == .timedOut {
                process.terminate()
                return (0, "未知")
            }
            drain.wait()  // 进程已退出 ⇒ 读必完成，再安全使用 data
            guard let output = String(data: data, encoding: .utf8) else {
                throw MyLocalizedError(reason: "Output decoding failed")
            }
            
            // 抓形如 `openjdk version "17.0.9"` / `java version "1.8.0_392"` 中引号里的内容。
            let versionPattern = #"(?:openjdk|java)\s+version\s+"([0-9]{1,3}(?:[\.\-\+][\w\.\+]+)?)""#
            let regex = try NSRegularExpression(pattern: versionPattern, options: .caseInsensitive)
            if let match = regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)),
                let range = Range(match.range(at: 1), in: output) {
                let displayVersion = String(output[range])
            
                // 主版本号 = 第一个点号之前的数字（`17.0.9` → 17）。
                // ⚠️ 这里**没有**「1.8 时代取第二段」的特判，与上面读 release 文件的写法不一致：
                // `java -version` 报 `1.8.0_392` 时这里会得到 **1**（而不是 8）。
                // 后果是 Java 8 只走这条兜底路径被发现时，会被「最低 Java 8」的要求判为不满足，
                // 进而被 findSuitableJava 过滤掉（见 MinecraftInstanceJava.swift）。
                let majorVersionString = displayVersion.split(separator: ".").first?.split(separator: "-").first ?? ""
                if let majorVersion = Int(majorVersionString) {
                    return (majorVersion, displayVersion)
                }
            }
            throw MyLocalizedError(reason: "\(url.path) 中的 Java 版本未找到")
        } catch {
            err("无法检测 java 版本: \(error.localizedDescription)")
        }
        return (0, "未知")
    }
    
    /// 判等**只看可执行文件路径**：同一个 java 被扫描到多次仍算一个；
    /// 但内容相同、路径不同的两份 java 会被当作两个（这是刻意的 —— 两条路径都可能被用到）。
    /// arch / version / isJdk 以及 id 都不参与判等。
    public static func == (jvm1: JavaVirtualMachine, jvm2: JavaVirtualMachine) -> Bool {
        return jvm1.executableURL == jvm2.executableURL
    }
}

/// JVM 在当前机器上的调用方式。
/// - `direct`：架构一致（或通用二进制），原生直跑；
/// - `transition`：架构不一致但本机是 arm64 —— 靠 Rosetta 转译，可用但有性能损耗；
/// - `incompatible`：跑不了（例如本机 x64 拿到 arm64 的 java）。
/// `findSuitableJava` 优先选 `direct`，没有才退而取 `transition`，`incompatible` 直接排除。
public enum CallMethod {
    case direct, transition, incompatible
    /// UI 文案。⚠️ 它是 internal（无 `public`）：界面侧若要展示这几个字，
    /// 只能自己再写一遍映射，不能引用这里。
    func getDisplayName() -> String {
        switch self {
        case .direct: "直接运行"
        case .transition: "转译"
        case .incompatible: "不兼容"
        }
    }
}
