//
//  ArtifactVersionMapperV2.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/6/14.
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

    private static func changeVersion(_ library: ClientManifest.Library, _ newVersion: String) {
        library.name = library.name.replacingOccurrences(of: library.version, with: newVersion)
    }
}
