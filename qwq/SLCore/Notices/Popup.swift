//
//  Popup.swift
//  弹窗：模型与投递入口（已接入统一提示通道）。
//
//  历史：本文件原属 `SLCore/Stubs.swift`。拆分后这里只装「弹窗」这一件事，
//  且**没有一个是空实现** —— 两个方法都真的把 `PopupModel` 投递成 `Notice`。
//
//  职责：弹窗的四个模型类型（`PopupButton` / `PopupButtonStyle` / `PopupType` / `PopupModel`）
//        与投递入口 `PopupManager`。
//  边界：不含界面绘制（展示由 `UI/Notices/NoticeCenter.swift` 与 `NoticeOverlay` 承担）；
//        `showAsync` 当前无生产侧调用方，保留原因见其注释，**不得因「无调用方」删除**。
//
//  注释引用约定：一律写「文件 + 符号/场景」，**不写行号**（行号会随任何一次编辑漂移）。
//

import Foundation
import Combine

/// 弹窗按钮模型。
/// 使用方：`SLCore/Minecraft/Download/MinecraftInstallTask.swift`、`LoaderInstallTasks.swift`
/// （`[PopupButton.ok]`）；另有 `UI/Notices/NoticeCenter.swift` 的映射实现
/// 与 `qwqTests/NoticeCenterTests.swift` 的构造。
public struct PopupButton {
    public let label: String
    public let style: PopupButtonStyle
    public static let ok = PopupButton(label: "确定", style: .normal)
    public init(label: String, style: PopupButtonStyle = .normal) {
        self.label = label
        self.style = style
    }
}
/// 按钮样式。使用方：`PopupButton` 的默认参数、`UI/Notices/NoticeCenter.swift`、
/// `qwqTests/NoticeCenterTests.swift`（`.danger`）。
public enum PopupButtonStyle { case normal, accent, danger }
/// 弹窗类型。使用方：`UI/Notices/NoticeCenter.swift`（`NoticeLevel(_ type: PopupType)`）、
/// `qwqTests/NoticeCenterTests.swift`。
public enum PopupType { case info, warning, error }
/// 弹窗内容模型。使用方：`PopupManager.show(_:)` / `showAsync(_:)`（本文件）、
/// `UI/Notices/NoticeCenter.swift`（`Notice(_ model: PopupModel)`）、
/// `qwqTests/NoticeCenterTests.swift`。
public struct PopupModel {
    public let type: PopupType
    public let title: String
    public let message: String
    public let buttons: [PopupButton]
    public init(_ type: PopupType, _ title: String, _ message: String, _ buttons: [PopupButton]) {
        self.type = type; self.title = title; self.message = message; self.buttons = buttons
    }
}

/// 弹窗管理器。**已接入真实提示通道**（`NoticeCenter` → 根视图上的 `NoticeOverlay`）。
///
/// 实现约定：
///  - `show(_:)` 把 `PopupModel` 转成 `Notice` 投递到 `NoticeCenter`，随即返回（不等待用户）；
///  - `showAsync(_:)` 同样投递，但会**真正等待用户点选按钮**，并返回被点按钮的下标；
///  - 两者签名与调用点保持不变，旧调用方无需改动。
///
/// 使用方：`SLCore/Minecraft/Download/MinecraftInstallTask.swift`、`LoaderInstallTasks.swift`（`show`）。
///
/// `showAsync` 目前**无调用方**——它唯一的调用点（旧启动流程里的崩溃弹窗）已随该流程一并删除。
/// 保留原因（见 `Features/Launch/Adapters/LAUNCH_FLOW.md` 第三节「失去调用方的能力」）：
/// 本启动器当前仍缺失「崩溃后可导出错误报告」这条能力，`showAsync` 是它的现成实现；
/// 且其底层 `NoticeCenter.presentAndWait` 有单元测试覆盖（`qwqTests/NoticeCenterTests.swift`），
/// 删除会让该等待机制连同测试覆盖一起失去生产侧入口。补齐能力时直接接线即可。
@MainActor
public class PopupManager: ObservableObject {
    public static let shared = PopupManager()
    private init() {}

    /// 展示弹窗：转成 `Notice` 投递到统一提示通道。不等待用户操作，调用后立即返回。
    /// 使用方：`SLCore/Minecraft/Download/MinecraftInstallTask.swift`、`LoaderInstallTasks.swift`。
    public func show(_ model: PopupModel) async {
        NoticeCenter.shared.post(Notice(model))
    }

    /// 展示弹窗并等待用户点选，返回被点击按钮在 `model.buttons` 中的**下标**。
    ///
    /// 返回值约定（重要，调用方据此分支）：
    ///  - `0` —— 用户点了第 0 个按钮，或直接关闭了提示，或 UI 承载者未挂载（兜底），
    ///           或等待超过兜底超时（300s）。即「默认 / 取消」语义。
    ///  - `n > 0` —— 用户点击了第 n 个按钮（例如崩溃提示里下标 1 的「导出错误报告」）。
    ///
    /// 注意：仅在 `NoticeOverlay` 已挂载时才会真正等待；否则立即返回 0，
    /// 与非阻塞场景保持兼容，绝不会把调用方永久挂起。
    ///
    /// 使用方：当前**无生产侧调用方**（唯一调用点随旧启动流程删除）；
    /// 作为「崩溃后导出错误报告」能力的现成实现保留，接线说明见类型注释。
    public func showAsync(_ model: PopupModel) async -> Int {
        await NoticeCenter.shared.presentAndWait(Notice(model))
    }
}
