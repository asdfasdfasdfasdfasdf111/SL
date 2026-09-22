//
//  DebugAutoLaunch.swift
//  仅 DEBUG 构建存在的「无人值守启动」开关。
//
//  为什么需要它：启动链路（`LaunchCoordinator` → `MinecraftInstanceLaunchService` → `pclLaunch`
//  → `LaunchFix` → Java 解析 → 进程拉起）的风险点全部只在**真实执行**时才暴露，而真实执行
//  目前有两条环境门槛：驱动 UI 需要辅助功能权限（`AXIsProcessTrusted` 为 false 时点不到按钮），
//  跑 XCTest 需要 testmanagerd（受限沙箱里 XPC 握手不通）。本开关给出第三条路：
//  用环境变量触发一次与点击「启动游戏」**完全相同**的调用，无需任何 UI 交互。
//
//  用法：
//      SL_DEBUG_AUTO_LAUNCH=1 /path/to/qwq.app/Contents/MacOS/qwq
//  加 `SL_DEBUG_AUTO_LAUNCH_DELAY=15` 可改延迟秒数（默认 3）。
//
//  Release 构建里本类型只剩空实现，不引入任何行为。
//

#if DEBUG

import Foundation

enum DebugAutoLaunch {

    /// 环境变量开启时，延迟若干秒自动发起一次启动（等价于点击「启动游戏」）。
    ///
    /// 延迟是必要的：`LaunchCoordinator.start` 依赖窗口已建立、`LauncherSettings`
    /// 已从磁盘装载完毕；在 `onAppear` 里同步调用会在这些前提之前跑。
    @MainActor
    static func maybeStart() {
        let env = ProcessInfo.processInfo.environment
        guard env["SL_DEBUG_AUTO_LAUNCH"] == "1" else { return }
        let delay = Double(env["SL_DEBUG_AUTO_LAUNCH_DELAY"] ?? "") ?? 3
        NSLog("[DebugAutoLaunch] SL_DEBUG_AUTO_LAUNCH=1，\(delay) 秒后自动发起启动")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            LaunchCoordinator.start(settings: LauncherSettings.shared,
                                    sessionManager: LaunchSessionManager.shared)
        }
    }
}

#else

enum DebugAutoLaunch {
    @MainActor static func maybeStart() {}
}

#endif
