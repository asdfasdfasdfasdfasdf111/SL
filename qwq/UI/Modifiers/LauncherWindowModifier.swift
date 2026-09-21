//
//  LauncherWindowModifier.swift
//  模块化收口：把根视图 onAppear 里的窗口外观配置（透明标题栏 / 全尺寸内容区）
//  抽为独立修饰器，ContentView 只保留一行 `.launcherWindow()` 调用。
//
//  行为约束：
//  1. 取值方式沿用 `NSApp.windows.first`，不做多窗口筛选或重试；
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
            guard let window = NSApp.windows.first else { return }
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
