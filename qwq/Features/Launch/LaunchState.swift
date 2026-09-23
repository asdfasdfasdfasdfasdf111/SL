//
//  LaunchState.swift
//  启动用例层：单次启动的生命周期状态
//
//  与现有 UI 侧 `LaunchPhase`（GameSession.swift）是两套东西：
//  `LaunchPhase` 只描述进度条观感（idle/preparing/downloading/installing/launching），
//  本类型描述用例层真实阶段，含文件校验、Java 选择、进程退出结果，
//  迁移完成后 UI 由本状态派生观感状态（见 README）。
//

import Foundation

/// 进度回调（0~1）。真实来源：`LaunchFix.perform(instance:onProgress:)` 的 onProgress。
public typealias LaunchProgressHandler = @Sendable (Double) -> Void

/// 一次启动从发起到结束的状态机
public enum LaunchState: Sendable, Equatable {
    /// 未开始
    case idle
    /// 准备中：目录解析、实例创建、用户名校验、皮肤/语言注入
    case preparing
    /// 文件校验中（0~1）：client / library / asset 的缺失与损坏分析
    case verifyingFiles(Double)
    /// 下载补全中（0~1）：`LaunchFix` 语义的缺失项下载
    case downloading(Double)
    /// 解析 Java：扫描等待、版本要求比对、可执行文件校验
    case resolvingJava
    /// 组装启动参数：classpath、JVM 模板替换、架构适配
    case buildingArguments
    /// 拉起进程中
    case launching
    /// 进程已启动并在运行
    case running
    /// 正在终止（用户关闭 / 电源按钮）
    case stopping
    /// 进程已退出，携带结果
    case finished(LaunchResult)
    /// 失败，携带错误
    case failed(LaunchError)

    /// 是否已进入终态（不会再产生后续状态）
    ///
    /// `nonisolated`：本属性只读枚举载荷、不触碰任何 actor 隔离状态。
    /// 未标注时会被工程默认隔离（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）推断为
    /// `@MainActor`，于是 `GameSessionStore.update` 里在 `OSAllocatedUnfairLock.withLock`
    /// 的 `@Sendable` 闭包内读它就是「main actor-isolated property can not be referenced
    /// from a Sendable closure」——Swift 6 语言模式下直接是 error，而该锁本就设计为
    /// 任意并发域可用（同文件 `observe` 的 `onTermination` 亦为 `@Sendable`）。
    /// 依据：《Concurrency》——`nonisolated` 声明不参与 actor 隔离推断，可从任意并发域调用；
    /// 其实现不得访问 actor 隔离状态（本属性满足）。
    /// 官方链接：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
    public nonisolated var isTerminal: Bool {
        switch self {
        case .finished, .failed: return true
        default: return false
        }
    }
}
