//
//  Hint.swift
//  轻量提示入口：把一行文字送进统一的提示通道。
//
//  历史：本文件原属 `SLCore/Stubs.swift`。那个名字会让读者以为它是桩实现，但 `hint` 是
//  **已接入真实提示通道**的活跃 API（`NoticeCenter` → 根视图上的 `NoticeOverlay`），
//  因此单独成文并取一个实事求是的文件名。
//
//  职责：`hint(_:_:)` 与其级别枚举 `HintType`。
//  边界：只做「写日志 + 投递提示」，不含任何界面代码；实际展示由
//        `UI/Notices/NoticeCenter.swift` 与根视图上的 `NoticeOverlay` 承担。
//
//  注释引用约定：一律写「文件 + 符号/场景」，**不写行号**（行号会随任何一次编辑漂移）。
//

import Foundation

/// 轻量提示。**已接入真实提示通道**（`NoticeCenter` → 根视图上的 `NoticeOverlay`）。
///
/// 行为：写一条日志，并把消息按级别转成 `Notice` 投递到 `NoticeCenter`，
/// 用户会在界面顶部看到对应横幅（`info` / `success` 自动消失，`warning` / `error` 需手动关闭）。
/// 投递是异步且线程安全的，因此本函数可从任意线程调用，调用后不会阻塞等待。
///
/// 使用方（均为活跃调用）：
///  - `SLCore/SLLaunchBridge.swift`——未实现账号告警（`.critical`）；
///  - `SLCore/Minecraft/Launch/MinecraftLauncherArguments.swift`——内存上限非法并回退（`.critical`）；
///  - `SLCore/Minecraft/Launch/LaunchFix.swift`——启动前补全存在无法修复的缺项（`.critical`）；
///  - `SLCore/Minecraft/Launch/MinecraftLauncher.swift`——游戏日志文件不可写（`.critical`）。
public func hint(_ message: String, _ type: HintType = .info) {
    log("[Hint] \(message)")
    let level = NoticeLevel(type)
    NoticeCenter.shared.post(
        Notice(level: level, title: level.defaultTitle, message: message)
    )
}
/// 提示级别。使用方：本文件的 `hint(_:_:)` 默认参数，以及
/// `UI/Notices/NoticeCenter.swift` 的 `NoticeLevel.init(_ type: HintType)` 映射；
/// 三个 case 在 `qwqTests/NoticeCenterTests.swift` 有断言覆盖。
public enum HintType { case info, finish, critical }
