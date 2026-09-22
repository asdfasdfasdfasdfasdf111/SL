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
//  故 RequiredJava16/17/21 由 private static 放宽为 internal static（本文件 getMinJavaVersion 读取）；
//  findJVM / ensureDataManagerHasJava / archName 仅本文件调用，保持 private static。对外接口零变化。
//

import Foundation

extension MinecraftInstance {
    /// 根据当前 manifest/version 解析所需最低 Java 版本并自动选择最合适的 JVM
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
    public static func resolveMinJavaVersion(manifest: ClientManifest?, version: MinecraftVersion?) -> Int {
        if let manifestJava = manifest?.javaVersion, manifestJava > 0 {
            return manifestJava
        }
        guard let version else { return 8 }
        return getMinJavaVersion(version)
    }

    /// 读取指定 java 可执行文件的主版本号（读 release 文件，不启动进程）
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

    private static func findJVM(at url: URL) -> JavaVirtualMachine? {
        DataManager.shared.javaVirtualMachines.first(where: { $0.executableURL.path == url.path })
    }

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

    private static func archName(_ arch: Architecture) -> String {
        switch arch {
        case .arm64: return "arm64"
        case .x64: return "x64"
        case .fatFile: return "fat"
        case .unknown: return "unknown"
        }
    }

    public static func getMinJavaVersion(_ version: MinecraftVersion) -> Int {
        if version >= RequiredJava21 {
            return 21
        } else if version >= RequiredJava17 {
            return 17
        } else if version >= RequiredJava16 {
            return 16
        } else {
            return 8
        }
    }
    
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
