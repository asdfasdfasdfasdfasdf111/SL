//
//  LaunchArgumentBuilder.swift
//  启动用例层：启动参数组装
//
//  对应现有实现：
//  - `MinecraftLauncher.buildJvmArguments(_:)` → JVM 参数（模板 `${natives_directory}`、`${classpath}` 等经
//    `Util.replaceTemplateStrings` 替换后产出）
//  - `MinecraftLauncher.buildClasspath()` → 收集 `[URL]`（支持库 + 客户端 JAR），再以 ":" 连接成字符串
//  - `MinecraftLauncher.buildGameArguments(_:)` → 游戏参数
//
//  classpath 参数按 `buildClasspath()` 的真实中间形态取 `[URL]`：连接符 ":" 由实现方在模板替换时处理，
//  协议层保留路径列表，便于校验「classpath 项是否真实存在」。
//

import Foundation

/// 启动参数组装器：把一次启动请求编译成 `Process.arguments`
public protocol LaunchArgumentBuilder: Sendable {
    /// - Parameters:
    ///   - request: 启动请求
    ///   - java: 最终选定的 Java 可执行文件（`MinecraftInstance.config.javaURL`）
    ///   - classpath: 支持库 + 客户端 JAR 的绝对文件路径列表（`MinecraftLauncher.buildClasspath()` 的中间产物）
    /// - Returns: 完整参数数组，顺序为 [JVM 参数..., 主类, 游戏参数...]
    func buildArguments(for request: LaunchRequest, java: URL, classpath: [URL]) -> [String]
}

/// classpath 连接符（macOS/Linux）。`buildClasspath()` 与清单模板 `${classpath_separator}` 均使用 ":"。
public let LaunchClasspathSeparator: String = ":"
