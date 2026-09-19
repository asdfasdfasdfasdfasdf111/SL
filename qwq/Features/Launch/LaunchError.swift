//
//  LaunchError.swift
//  启动用例层：启动失败原因
//
//  与 `LauncherError`（LauncherError.swift，UI 侧目录/皮肤校验错误）职责不同：
//  本类型只覆盖「启动用例」的失败分支，供 LaunchState.failed 携带并直接面向用户展示。
//

import Foundation

/// 启动用例失败原因
public enum LaunchError: Error, LocalizedError, Equatable {
    /// 实例不存在或无法创建（目录缺失 / 版本 JSON 损坏）
    case instanceNotFound(version: String)
    /// 未找到满足最低版本要求的 Java
    case javaNotFound(requiredMajorVersion: Int)
    /// 启动前文件校验或补全失败
    case fileVerificationFailed(reason: String)
    /// 进程启动失败（`Process.run()` 抛错）
    case processStartFailed(reason: String)
    /// 用户取消
    case cancelled
    /// 未归类的底层错误
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .instanceNotFound(let version):
            return "无法创建实例: \(version)"
        case .javaNotFound(let major):
            return "未找到满足版本要求 (Java \(major)+) 的 Java 安装，请先在「Java 管理」中扫描或下载 Java。"
        case .fileVerificationFailed(let reason):
            return "启动前文件校验失败：\(reason)"
        case .processStartFailed(let reason):
            return "游戏进程启动失败：\(reason)"
        case .cancelled:
            return "启动已取消"
        case .unknown(let message):
            return "启动失败：\(message)"
        }
    }
}
