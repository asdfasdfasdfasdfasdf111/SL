//
//  MinecraftInstanceJava.swift
//  SL启动器
//
//  实例的 Java 解析职责（从 MinecraftInstance.swift 逐字搬移，逻辑与文案未变）：
//  - resolveAndApplyJava：沿用有效缓存或自动选取合适的 JVM 并写回配置
//  - resolveMinJavaVersion / getMinJavaVersion：最低 Java 版本判定
//  - readJavaMajorVersion：读 release 文件解析主版本号（不启动进程）
//  - findJVM / ensureDataManagerHasJava / archName：DataManager 查询与登记、架构名
//  - findSuitableJava：按 callMethod 优先级选取候选 JVM
//
//  跨文件访问级别说明（依据 references/swift-language/access-control.md 与 extensions.md，
//  官方链接 https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/
//  与 .../extensions/）：扩展不能声明存储属性，且 `private` 仅对同一封闭声明及其同文件成员可见。
//  findJVM / ensureDataManagerHasJava / archName 仅本文件调用，保持 private static。对外接口零变化。
//
//  ── 这个文件在解决什么 ─────────────────────────────────────
//  「这个实例该用哪个 Java？」—— 三件事要同时满足：版本够（≥ 游戏要求）、架构对
//  （Apple Silicon 上优先原生 arm64，实在没有才允许 Rosetta 转译）、文件真的还在。
//  本文件只负责**选**，启动时怎么用（走 direct 还是 transition）由 `SLLaunchBridge` 决定。
//
//  ── 一条修复记录（勿回退）────────────────────────────────────
//  `resolveAndApplyJava` 的失败分支会执行 `config.javaURL = nil` 把失效的缓存清掉。
//  而 `javaURL` 的 setter 曾经写成 `value.path`（对 `URL!` 隐式强解包），
//  赋 nil 会**直接崩溃**（最小复现已证实是 `Unexpectedly found nil while implicitly
//  unwrapping`）。触发条件很常见：用户换了更高版本的游戏、或删掉了原先的 JDK ——
//  只要缓存里的 Java 校验不过就会走到这一行。setter 现已改为 `value?.path ?? ""`，
//  本行保持原样即可。
//

import Foundation

extension MinecraftInstance {
    /// 根据当前 manifest/version 解析所需最低 Java 版本并自动选择最合适的 JVM
    ///
    /// 流程（三段）：
    /// 1. 算出这个版本要求的最低 Java（`resolveMinJavaVersion`）；
    /// 2. **先用缓存**：配置里记着 Java 时，校验「文件仍在 + 能读出主版本 + 版本达标」，
    ///    全过就沿用（并顺手登记进 `DataManager`，让界面其它部分也能看到），直接返回；
    /// 3. 任一项不过就**清掉缓存**（`config.javaURL = nil`，见文件头的修复记录），
    ///    再走 `findSuitableJava` 重新挑，挑到就写回配置。
    ///
    /// - Returns: 选定的 JVM；一个都挑不出来时返回 `nil`（调用方据此弹「没有可用 Java」）。
    ///
    /// 注意**选定后不在这里持久化**：`config` 改了，但要等调用方
    /// （通常是 `SLLaunchBridge.swift:282`）调 `saveConfig()` 才落盘。
    @discardableResult
    public func resolveAndApplyJava() -> JavaVirtualMachine? {
        let minJavaVersion = Self.resolveMinJavaVersion(manifest: manifest, version: version)

        // 若用户缓存的 Java 仍满足版本要求，且可执行文件实际存在，保留之
        if let currentURL = config.javaURL {
            if FileManager.default.isExecutableFile(atPath: currentURL.path),
               let currentMajor = Self.readJavaMajorVersion(at: currentURL),
               currentMajor >= minJavaVersion {
                debug("沿用缓存 Java: \(currentURL.path) (major=\(currentMajor), 需要>=\(minJavaVersion))")
                // 确保同步到 DataManager，以便其他 UI 组件能看到
                Self.ensureDataManagerHasJava(currentURL)
                return Self.findJVM(at: currentURL)
            } else {
                warn("缓存的 Java 不满足当前版本 (需要>=\(minJavaVersion)) 或已失效，重新选择")
                // 清掉失效缓存，避免下次启动又走一遍校验。setter 已做 nil 安全处理。
                config.javaURL = nil
            }
        }

        guard let jvm = Self.findSuitableJava(version, minJavaVersion: minJavaVersion, manifest: manifest) else {
            return nil
        }
        config.javaURL = jvm.executableURL
        debug("自动选择 Java: \(jvm.executableURL.path) (major=\(jvm.version), 需要>=\(minJavaVersion))")
        return jvm
    }

    /// 解析最低 Java 版本：优先 manifest.javaVersion，无则根据 MC 版本推断
    ///
    /// 顺序是有讲究的：清单自己写明了 `javaVersion.majorVersion` 就以它为准
    /// （加载器或整合包可能改过这个要求），只有清单没写才按版本号估。
    ///
    /// 清单和版本**都缺**时返回 **8** —— 这是「无从判断就用最宽松的」，不是「原版要 8」。
    public static func resolveMinJavaVersion(manifest: ClientManifest?, version: MinecraftVersion?) -> Int {
        if let manifestJava = manifest?.javaVersion, manifestJava > 0 {
            return manifestJava
        }
        guard let version else { return 8 }
        return getMinJavaVersion(version)
    }

    /// 读取指定 java 可执行文件的主版本号（读 release 文件，不启动进程）
    ///
    /// 为什么不跑 `java -version`：那要起一个进程、解析 stderr 文本，既慢又脆
    /// （不同发行版输出格式不一）。JDK 目录里必然带一份 `release` 文件，里面有
    /// `JAVA_VERSION="21.0.1"` 这样一行，读文件即可。
    ///
    /// 路径推算：`javaURL` 是 `<jdk>/Contents/Home/bin/java`（或 `<jdk>/bin/java`），
    /// 往上两级是 JDK 根，再上**一级**是 macOS 的 `Contents/Home` —— 两个候选都试一遍，
    /// 所以 JRE/JDK、有无 `Contents/Home` 包装都覆盖到了。
    ///
    /// 版本号解析有个经典坑：老版本写作 `1.8.0_202`，主版本号是 **8** 而不是 1。
    /// 所以首位是 1 时取第二段（取不到就当 8）。
    ///
    /// - Returns: 主版本号；两处候选都读不到 / 没有 `JAVA_VERSION=` 行时返回 `nil`
    ///   （调用方 `resolveAndApplyJava` 会当作「这个 Java 不可用」处理）。
    public static func readJavaMajorVersion(at javaURL: URL) -> Int? {
        let base = javaURL.deletingLastPathComponent().deletingLastPathComponent()
        let candidates: [URL] = [
            base.appendingPathComponent("release"),
            base.deletingLastPathComponent().appendingPathComponent("release"),
        ]
        for releaseURL in candidates {
            guard let content = try? String(contentsOf: releaseURL, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                if line.hasPrefix("JAVA_VERSION=") {
                    let values = line.replacingOccurrences(of: "JAVA_VERSION=", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                        .split(separator: ".")
                        .compactMap { Int($0) }
                    if let first = values.first {
                        return first == 1 ? (values.count > 1 ? values[1] : 8) : first
                    }
                }
            }
        }
        return nil
    }

    /// 在已登记的 JVM 里按可执行文件路径查找。
    /// 只查 `DataManager` 的登记表，不碰磁盘 —— 表里没有就当作「未登记」。
    private static func findJVM(at url: URL) -> JavaVirtualMachine? {
        DataManager.shared.javaVirtualMachines.first(where: { $0.executableURL.path == url.path })
    }

    /// 把磁盘上发现的一个 Java 补登进 `DataManager`（已登记则什么都不做）。
    ///
    /// 两种调用场景：用户手动选了 `DataManager` 还没扫描到的 JDK；
    /// 以及 `resolveAndApplyJava` 沿用缓存时同步一次。
    ///
    /// `callMethod` 的推断规则（决定后续能不能用）：
    /// - 文件架构 == 系统架构 → `.direct`（原生直跑）；
    /// - 否则若系统是 arm64 → `.transition`（用 Rosetta 转译跑 x64 Java）；
    /// - 其余 → `.incompatible`（x64 机器上的 arm64 Java，跑不了）。
    ///
    /// `register` 走 `DispatchQueue.main.async`：`DataManager` 是主线程对象，
    /// 而本方法可能被后台的实例扫描调用到。代价是**登记是延迟生效的** ——
    /// 紧接着读 `javaVirtualMachines` 可能还看不到这一条。
    private static func ensureDataManagerHasJava(_ url: URL) {
        guard findJVM(at: url) == nil else { return }
        let arch = Architecture.getArchOfFile(url)
        let callMethod: CallMethod = arch == Architecture.system ? .direct : (Architecture.system == .arm64 ? .transition : .incompatible)
        let major = readJavaMajorVersion(at: url) ?? 0
        let jvm = JavaVirtualMachine(
            arch: arch,
            version: major,
            displayVersion: "\(major)",
            implementor: nil,
            executableURL: url,
            callMethod: callMethod,
            isJdk: nil
        )
        DispatchQueue.main.async {
            DataManager.shared.javaVirtualMachines.append(jvm)
        }
    }

    /// 架构枚举 → 展示用短名。只用于日志，不参与任何判断。
    private static func archName(_ arch: Architecture) -> String {
        switch arch {
        case .arm64: return "arm64"
        case .x64: return "x64"
        case .fatFile: return "fat"
        case .unknown: return "unknown"
        }
    }

    /// 按版本号推断最低 Java 要求。
    ///
    /// ⚠️ **别再写回 `version >= RequiredJava21` 那种比较**（原实现，已证实会退化）：
    /// `MinecraftVersion.<` 是按**发布时间**比较的，而发布时间要反查版本清单、查不到就落到
    /// 1970-01-01 这个兜底值（见 `MinecraftVersion.swift` 文件头「维护提示 1」）。于是：
    /// - 版本不在清单里 —— 带加载器后缀的自定义目录名（`1.20.1-forge`）正是模组实例的常态：
    ///   该版本 releaseDate = 1970，而三个阈值是真实日期 → `>=` 全假 → 一律落到最下面的 **8**；
    /// - 清单整体还没加载：双方都是 1970 → `>=` 全真 → 一律返回 **21**。
    /// 两种都会让游戏起不来（1.20.1 要 17，给 8 给 21 都失败），且报错方向与真实原因无关。
    ///
    /// 因此这里统一委托 `JavaRequirement.minimumMajor`：它按**版本号数字**推导，且与本工程其它
    /// 入口（`VersionUtils.requiredJavaVersionForMinecraft`、`DownloadCategoryViewModel`）
    /// 用的是同一个函数 —— 口径只有一处。
    public static func getMinJavaVersion(_ version: MinecraftVersion) -> Int {
        JavaRequirement.minimumMajor(forMinecraftVersion: version.displayName)
    }
    
    /// 从已登记的 JVM 里挑一个能用的。
    ///
    /// - Parameters:
    ///   - version: 目标游戏版本（仅在没传 `minJavaVersion` 时用它推算）。
    ///   - minJavaVersion: 显式最低要求，覆盖上面的推算。
    ///   - manifest: 同上，用于推算清单声明的要求。
    ///
    /// 筛选与优先级：
    /// 1. **先剔除** `version <= 0`（没读出版本号，等于不可信）与
    ///    `callMethod == .incompatible`（架构上根本跑不了）的候选；
    /// 2. 候选**按版本号升序**排列后线性扫描 —— 这一步是刻意的：
    ///    优先返回**满足要求里最低的那个** `.direct`，而不是最新的。
    ///    理由是新版 Java 常引入与老 Mod 不兼容的行为，用「够用就好」的策略更稳；
    /// 3. `.direct` 命中即返回；否则记住**第一个** `.transition`（Rosetta）作为兜底
    ///    （`transitionCandidate == nil` 的存在就是为了「只记第一个」）。
    ///
    /// 一个都挑不出来时会连续打三条 warn（版本 / 最低要求 / 候选数），
    /// 这是出「没有可用 Java」提示时唯一的现场证据，别删。
    public static func findSuitableJava(_ version: MinecraftVersion, minJavaVersion: Int? = nil, manifest: ClientManifest? = nil) -> JavaVirtualMachine? {
        let resolvedMin = minJavaVersion ?? resolveMinJavaVersion(manifest: manifest, version: version)
        let validJVMs = DataManager.shared.javaVirtualMachines.filter { $0.version > 0 && $0.callMethod != .incompatible }

        debug("寻找 Java: 版本=\(version.displayName), 最低 Java=\(resolvedMin), 候选 JVM=\(validJVMs.count)")
        for jvm in validJVMs {
            debug("  候选: \(jvm.executableURL.path) (major=\(jvm.version), arch=\(archName(jvm.arch)), callMethod=\(jvm.callMethod))")
        }

        // 优先选择：callMethod == .direct 且 version >= min
        // 次选：callMethod == .transition（Rosetta）且 version >= min
        var directCandidate: JavaVirtualMachine?
        var transitionCandidate: JavaVirtualMachine?
        for jvm in validJVMs.sorted(by: { $0.version < $1.version }) {
            if jvm.version < resolvedMin { continue }
            if jvm.callMethod == .direct {
                directCandidate = jvm
                break
            }
            if transitionCandidate == nil && jvm.callMethod == .transition {
                transitionCandidate = jvm
            }
        }

        let result = directCandidate ?? transitionCandidate
        if let result {
            debug("选定 Java: \(result.executableURL.path) (major=\(result.version), callMethod=\(result.callMethod))")
        } else {
            warn("未找到可用 Java")
            warn("  版本: \(version.displayName)")
            warn("  最低 Java 版本: \(resolvedMin)")
            warn("  可用 JVM 数量: \(validJVMs.count)")
        }
        return result
    }
}
