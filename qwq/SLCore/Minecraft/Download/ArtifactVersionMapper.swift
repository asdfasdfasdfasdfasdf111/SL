//
//  ArtifactVersionMapperV2.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/6/14.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  **Apple Silicon 兼容适配**：在清单解析之后、拼参数之前，就地改写 `manifest.libraries`
//  里的依赖坐标与下载地址，把「官方清单里只有 x86 版本」的那些库换成能在 arm64 上跑的版本。
//
//  要解决的三个具体问题：
//  1. **LWJGL 3.x**：官方给 macOS 的 natives 是 `natives-macos`（Intel）。arm64 机器上
//     需要 `natives-macos-arm64`，而它从 LWJGL 3.3.3 起才官方提供。所以对 < 3.3.3 的版本
//     统一**钉到 3.3.2 的 natives-macos-arm64**（一个上游为 PCL 系启动器预先发布的版本）。
//  2. **JNA**：老版本 4.4.0 没有 arm64 natives，替换为 5.14.0。
//  3. **两处无法靠改版本号解决的库**（`ca.weblite:java-objc-bridge`、
//     `org.lwjgl.lwjgl:lwjgl-platform`）：直接换成第三方重新打包的 arm64 制品
//     （坐标里带 `org.glavo.hmcl` / `mmachina` 前缀），因此必须同时改 `artifact.url`
//     指向 Maven Central —— 这些包不在 Mojang 的 libraries 仓库里。
//
//  ── 边界 ───────────────────────────────────────────────────
//  - 只改坐标（`name`）、下载 URL（`artifact.url`）与落盘相对路径（`artifact.path`），
//    **不下载、不落盘**，调用时机由使用方决定。
//  - 幂等性提示：本方法是**就地改写**、不是纯函数。重复调用会基于已改过的值再改一次 ——
//    `changeVersion` 用的是 `replacingOccurrences(of: library.version, ...)`，
//    而 `library.version` 是从**当前** name 解析出来的，所以第二次调用通常是空操作，
//    但这不是设计保证，只是恰好成立。
//
//  ── 调用顺序（改动前必须确认）──────────────────────────────
//  - `SLLaunchBridge.swift:292/295`：按 Java 二进制与系统的架构兼容性，选 `.system` 或 `.x64`；
//  - `ClientManifest.deduplicateLibraries`（`:88`）内部**固定**用 `arch: .x64` 调本方法，
//    而它是由 `MinecraftLauncherArguments.buildClasspath()` 间接调用的
//    （`MinecraftLauncher.swift:64` → `buildJvmArguments` → `:57`）。
//    也就是说**这里可能覆盖前面按真实架构做过的映射**。
//    现状下 `.x64` 分支只改 natives 的 `name`、不动 `url`/`path`，所以还没有可见影响；
//    但当你要改 natives 的消费方式时，务必先把这个顺序理清。
//

import Foundation

public struct ArtifactVersionMapper {
    // MARK: - 版本替换常量（Apple Silicon 兼容适配，勿随意变更）

    /// LWJGL 3.x 在 Apple Silicon 上的钉板版本
    private static let lwjglPinnedVersion = "3.3.2"
    /// 原生即支持 arm64 的 LWJGL 版本（无需降级）
    private static let lwjglNativeArm64Version = "3.3.3"
    /// JNA 旧版本（缺少 arm64 natives）
    private static let jnaLegacyVersion = "4.4.0"
    /// JNA 替换版本（含 arm64 natives）
    private static let jnaArm64Version = "5.14.0"
    private static let objcBridgeReplacementName = "org.glavo.hmcl.mmachina:java-objc-bridge:1.1.0-mmachina.1"
    private static let lwjgl2NativesReplacementName = "org.glavo.hmcl:lwjgl2-natives:2.9.3-rc1-osx-arm64"
    private static let lwjgl2NativesJarPath = "org/glavo/hmcl/lwjgl2-natives/2.9.3-rc1-osx-arm64/lwjgl2-natives-2.9.3-rc1-osx-arm64.jar"
    private static let objcBridgeJarPath = "org/glavo/hmcl/mmachina/java-objc-bridge/1.1.0-mmachina.1/java-objc-bridge-1.1.0-mmachina.1.jar"

    private static let minecraftLibrariesBaseURL = "https://libraries.minecraft.net/"
    private static let mavenCentralBaseURL = "https://repo1.maven.org/maven2/"

    /// 就地改写清单里的依赖坐标与下载地址，使其适配目标架构。
    ///
    /// - Parameters:
    ///   - manifest: 待改写清单。**会被就地修改**（`libraries` 里的元素是引用类型）。
    ///   - arch: 目标架构。默认 `.system`（即当前机器）；
    ///     传 `.x64` 表示「用 Rosetta 转译跑」，此时**只做一件事** ——
    ///     把所有 natives 的名字统一钉到 `natives-macos`（Intel 版），然后直接返回。
    ///     `SLLaunchBridge.swift:292/295` 就是按 Java 二进制的架构兼容性在这两者之间选。
    ///
    /// 非 arm64 分支（下面这个 if）之所以足够简单，是因为 Intel 机器天然需要 Intel natives，
    /// 官方清单给的本来就是这个，只需要处理「清单写了别的版本」这一种偏差。
    public static func map(_ manifest: ClientManifest, arch: Architecture = .system) {
        if arch != .arm64 {
            for (library, _) in manifest.getNeededNatives() {
                library.name = "org.lwjgl:\(library.artifactId):\(lwjglPinnedVersion):natives-macos"
            }
            return
        }

        // 避免因 LWJGL 版本不对导致的无法启动：
        // 以下条件通过代表使用 -cp 方式添加本地库，这种方式一定会有 natives-macos-arm64，无需更改就能启动游戏；
        // 未通过则大概率没有写 arm64 架构的本地库（例如 1.18.2）。
        if manifest.getNeededNatives().isEmpty {
            return
        }

        // MARK: - 替换依赖项版本
        for library in manifest.getNeededLibraries() {
            switch library.groupId {
            case "org.lwjgl":
                if library.version.starts(with: "3.") && library.version != lwjglNativeArm64Version {
                    changeVersion(library, lwjglPinnedVersion)
                }
                library.artifact?.url = "\(minecraftLibrariesBaseURL)\(Util.toPath(mavenCoordinate: library.name))"

            case "net.java.dev.jna":
                if library.version == jnaLegacyVersion {
                    changeVersion(library, jnaArm64Version)
                }
                library.artifact?.url = "\(minecraftLibrariesBaseURL)\(Util.toPath(mavenCoordinate: library.name))"
            case "ca.weblite":
                if library.artifactId == "java-objc-bridge" {
                    library.name = objcBridgeReplacementName
                    library.artifact?.url = "\(mavenCentralBaseURL)\(Util.toPath(mavenCoordinate: library.name))"
                }
            default:
                continue
            }

            library.artifact?.path = Util.toPath(mavenCoordinate: library.name)
        }

        // MARK: - 替换本地库版本
        for (library, artifact) in manifest.getNeededNatives() {
            switch library.groupId {
            case "org.lwjgl":
                if library.version.starts(with: "3.") && library.version != lwjglNativeArm64Version {
                    changeVersion(library, lwjglPinnedVersion)
                }
                library.name = "org.lwjgl:\(library.artifactId):\(lwjglPinnedVersion):natives-macos-arm64"
                artifact.url = "\(minecraftLibrariesBaseURL)org/lwjgl/\(library.artifactId)/\(library.version)/\(library.artifactId)-\(library.version)-natives-macos-arm64.jar"
            case "org.lwjgl.lwjgl":
                if library.artifactId == "lwjgl-platform" {
                    library.name = lwjgl2NativesReplacementName
                    artifact.url = "\(mavenCentralBaseURL)\(lwjgl2NativesJarPath)"
                    artifact.path = lwjgl2NativesJarPath
                    continue
                }
            case "ca.weblite":
                if library.artifactId == "java-objc-bridge" {
                    library.name = objcBridgeReplacementName
                    artifact.url = "\(mavenCentralBaseURL)\(objcBridgeJarPath)"
                    artifact.path = objcBridgeJarPath
                    continue
                }
            default:
                continue
            }

            // artifact.url 来自第三方清单的 groupId/artifactId/version 拼接，可能含空格等非法 URL 字符
            // （非官方源损坏清单）→ URL(string:) 会返回 nil，回退保留原 path，避免强解包崩溃
            artifact.path = URL(string: artifact.url)?.path ?? artifact.path
        }
    }

    /// 把库坐标里的版本段替换成 `newVersion`。
    ///
    /// 用「字符串替换」而不是「按 `:` 重新拼 groupId:artifactId:version:classifier」，
    /// 是为了保住 classifier（即 natives 分类器 `natives-macos-arm64` 这类后缀）
    /// 以及坐标里可能存在的其它段；代价是 groupId/artifactId 里若恰好含版本号子串会被误替换
    /// （现有的 LWJGL / JNA 坐标不存在这种情况，所以可以这么写）。
    ///
    /// 时序细节：`library.name` 带 `didSet`，赋值完成后会立刻重建 `split`，
    /// 因此**这条语句之后** `library.version` 已是新值；
    /// 而本行右侧取到的仍是替换前的旧值（这正是我们要找的目标子串）。
    private static func changeVersion(_ library: ClientManifest.Library, _ newVersion: String) {
        library.name = library.name.replacingOccurrences(of: library.version, with: newVersion)
    }
}
