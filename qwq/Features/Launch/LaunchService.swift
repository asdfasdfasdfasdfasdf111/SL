//
//  LaunchService.swift
//  启动用例层：对外唯一入口
//
//  目标状态：UI（`LaunchCoordinator`）与兼容桥接（`PCLLaunchBridge`）都只调用本协议的同一个实现，
//  从而消除 `pclLaunchInternal` 与 `MinecraftInstance.launch()` 两套并存的启动流程。
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
