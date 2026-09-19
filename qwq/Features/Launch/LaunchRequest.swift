//
//  LaunchRequest.swift
//  启动用例层：一次启动请求的完整入参（值类型，可跨任务传递）
//
//  字段来源对照（均为现有代码中真实存在的入参，未新增概念）：
//  - version / gameRoot      ← pclLaunch(version:gameDir:) 与 LauncherSettings.selectedMinecraftVersion/selectedGameRoot
//  - instanceID              ← MinecraftInstance.id（实例已存在时直接定位，省去目录探测）
//  - runningDirectory        ← MinecraftInstance.runningDirectory（= gameRoot/versions/<version>）
//  - offlineUsername         ← LaunchOptions.playerName（OfflineAccount 名称）
//  - javaExecutable          ← LaunchOptions.javaPath / MinecraftConfig.javaURL
//  - memoryMB                ← MinecraftConfig.maxMemory（Int32，单位 MB，默认 4096）
//  - extraJVMArgs            ← 用户自定义 JVM 参数（当前由 MinecraftLauncher.buildJvmArguments 内联处理）
//  - skipResourceCheck       ← LaunchOptions.skipResourceCheck / MinecraftConfig.skipResourcesCheck
//  - isDemo                  ← LaunchOptions.isDemo
//  - qualityOfServiceRawValue← MinecraftConfig.qualityOfService.rawValue（QualityOfService(rawValue:)）
//

import Foundation

/// 启动目标：实例优先，否则按版本 + 根目录解析
public struct LaunchRequest: Sendable, Equatable {

    // MARK: - 目标定位

    /// 已存在的实例标识（`MinecraftInstance.id`）。与 `version` 二选一；非空时跳过目录探测。
    public var instanceID: UUID?
    /// 版本号（`MinecraftInstance.version.displayName`，如 "1.20.1"）。
    public var version: String
    /// 游戏根目录（`MinecraftDirectory.rootURL`，其下含 versions/、libraries/、assets/）。
    public var gameRoot: URL
    /// 版本运行目录（`MinecraftInstance.runningDirectory`）。nil 时由用例层按 gameRoot/versions/<version> 推导。
    public var runningDirectory: URL?

    // MARK: - 账号

    /// 离线用户名（PCL2 校验：非空 / 无英文引号 / ≤16 字符）。
    public var offlineUsername: String

    // MARK: - 运行时参数

    /// 显式指定的 Java 可执行文件。nil 时由用例层按最低 Java 版本自动选择。
    public var javaExecutable: URL?
    /// 最大堆内存（MB），对应 `-Xmx`。
    public var memoryMB: Int
    /// 附加 JVM 参数，追加在清单参数之后。
    public var extraJVMArgs: [String]
    /// 游戏窗口初始尺寸（可选；未设置时沿用游戏内 options.txt）。
    public var windowSize: LaunchWindowSize?
    /// 跳过启动前文件/资源校验（`MinecraftConfig.skipResourcesCheck`）。
    public var skipResourceCheck: Bool
    /// 演示模式（`LaunchOptions.isDemo`）。
    public var isDemo: Bool
    /// 进程 QoS 原始值，对应 `QualityOfService(rawValue:)`。0 表示未指定，由用例层回落到 `.default`。
    public var qualityOfServiceRawValue: Int

    public init(
        instanceID: UUID? = nil,
        version: String,
        gameRoot: URL,
        runningDirectory: URL? = nil,
        offlineUsername: String,
        javaExecutable: URL? = nil,
        memoryMB: Int = 4096,
        extraJVMArgs: [String] = [],
        windowSize: LaunchWindowSize? = nil,
        skipResourceCheck: Bool = false,
        isDemo: Bool = false,
        qualityOfServiceRawValue: Int = 0
    ) {
        self.instanceID = instanceID
        self.version = version
        self.gameRoot = gameRoot
        self.runningDirectory = runningDirectory
        self.offlineUsername = offlineUsername
        self.javaExecutable = javaExecutable
        self.memoryMB = memoryMB
        self.extraJVMArgs = extraJVMArgs
        self.windowSize = windowSize
        self.skipResourceCheck = skipResourceCheck
        self.isDemo = isDemo
        self.qualityOfServiceRawValue = qualityOfServiceRawValue
    }

    /// 推导后的版本运行目录：`MinecraftInstance.runningDirectory` 等价路径。
    public var resolvedRunningDirectory: URL {
        runningDirectory ?? gameRoot
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }
}

/// 游戏窗口尺寸（像素）。值为 0 表示该项交由游戏自行决定。
public struct LaunchWindowSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int = 0, height: Int = 0) {
        self.width = width
        self.height = height
    }
}
