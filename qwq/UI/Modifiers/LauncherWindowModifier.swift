//
//  LauncherWindowModifier.swift
//  模块化收口：把根视图 onAppear 里的窗口外观配置（透明标题栏 / 全尺寸内容区）
//  抽为独立修饰器，ContentView 只保留一行 `.launcherWindow()` 调用。
//
//  行为约束：
//  1. 取值优先 `NSApp.mainWindow ?? NSApp.keyWindow`，退回 `NSApp.windows.first`：
//     原写法直接取 `windows.first` 不保证顺序、可能命中不可见窗口；启动极早期 onAppear 先触发时
//     mainWindow/keyWindow 仍可能为 nil，故再退回 windows.first 兜底（宁可落到不确定的窗口，也别完全漏配）。
//  2. 只设置窗口外观，**不再写 `window.minSize`**：窗口最小尺寸的唯一来源是根视图
//     qwqApp.swift 的 .frame(minWidth: 800, minHeight: 590)。官方明文
//     NSWindow.contentMinSize「This method takes precedence over the minSize property.」
//     （https://developer.apple.com/documentation/appkit/nswindow/contentminsize ），
//     故此处原写的 800×550 既不生效、又与内容约束的 590 不一致，已删除；
//     原先「后写覆盖 AppDelegate 的 minSize」的因果链只对被压过的那个属性成立。
//  3. 仅处理窗口外观，不承担其他启动副作用（Java 预扫描仍由根视图触发）。
//

import SwiftUI
import AppKit

/// 根窗口外观配置：透明标题栏 + 全尺寸内容区。
private struct LauncherWindowModifier: ViewModifier {

    func body(content: Content) -> some View {
        content.onAppear {
            // 优先取真正的「主窗口 / 关键窗口」，避免 `windows.first` 命中顺序不保证、可能含不可见窗口的列表项；
            // 启动极早期 onAppear 先触发时 mainWindow/keyWindow 可能仍为 nil，退回 windows.first 兜底。
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first else { return }
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // 不在此处声明 window.minSize，原因见文件头行为约束 2
        }
    }
}

extension View {
    /// 为启动器根视图应用根窗口外观配置。
    func launcherWindow() -> some View {
        modifier(LauncherWindowModifier())
    }
}
