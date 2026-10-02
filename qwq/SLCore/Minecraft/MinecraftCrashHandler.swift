//
//  MinecraftCrashHandler.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/7/14.
//
//  ── 本文件职责 ─────────────────────────────────────────────
//  记录「最近一次实际执行过的启动命令行」（`lastLaunchCommand`），
//  供启动链路在拼装参数后写入、崩溃排查时读取。
//
//  ── ⚠️ 2026-10-02 死代码清理 ──────────────────────────────
//  原 `exportErrorReport`（把崩溃现场打包成 zip：环境信息 + 启动命令 + 启动器日志 +
//  游戏输出 + latest.log/debug.log + 最新 crash-report + 版本 JSON）已**删除**：
//  全库（含 qwqTests）零调用方——`SLCore/Notices/Popup.swift` 的 `PopupManager.showAsync`
//  注释明确记着「本启动器当前仍缺失『崩溃后可导出错误报告』这条能力」，
//  用户看到的「导出错误报告」按钮点下去没反应，是接线缺失而非本文件 bug。
//  若未来接该能力，需重写导出（本文件已不保留实现）；TemperatureDirectory 仍为活代码
//  （ForgeInstaller 在用它），可作工作目录。
//

import Foundation
import ZIPFoundation

/// 崩溃现场相关的静态数据（2026-10-02 起仅剩启动命令记录）。
public class MinecraftCrashHandler {
    /// 最近一次实际执行过的启动命令行。由 `MinecraftLauncher.swift:71` 在拼装完参数后写入，
    /// 导出时原样落到报告里的「启动命令.command」（可直接双击复现）。
    /// 初值 `"未设置"` 用来区分「还没启动过」和「启动了但命令为空」。
    public static var lastLaunchCommand: String = "未设置"
}
