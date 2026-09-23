//
//  LaunchService.swift
//  启动用例层：对外唯一入口
//
//  目标状态：UI（`LaunchCoordinator`）与兼容桥接（`SLLaunchBridge`）都只调用本协议的同一个实现，
//  从而收敛到 `slLaunchInternal` 单一启动流程（原 `MinecraftInstance.launch(_:)` 流程 A 已删除）。
//  迁移步骤见同目录 README.md。
//

import Foundation

/// 启动用例门面
public protocol LaunchService: Sendable {
    /// 执行完整启动流程：准备 → 文件校验/补全 → Java 选择 → 参数组装 → 拉起进程 → 等待退出。
    /// 抛出 `LaunchError` 表示启动失败（进程未成功拉起）。
    @discardableResult
    func launch(_ request: LaunchRequest) async throws -> LaunchResult

    /// 终止指定会话的游戏进程
    func terminate(sessionID: UUID) async
}
