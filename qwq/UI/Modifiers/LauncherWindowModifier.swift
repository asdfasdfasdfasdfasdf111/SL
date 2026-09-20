//
//  LauncherWindowModifier.swift
//  模块化收口：把根视图 onAppear 里的窗口外观配置（透明标题栏 / 全尺寸内容区 / 最小尺寸）
//  抽为独立修饰器，ContentView 只保留一行 `.launcherWindow()` 调用。
//
//  行为约束：
//  1. 取值方式沿用 `NSApp.windows.first`，不做多窗口筛选或重试；
//  2. 赋值顺序与参数值（800×550）与抽取前逐字一致——该配置在
//     AppDelegate.applicationDidFinishLaunching 之后执行并覆盖其 minSize（590），
//     顺序或数值变化会直接改变窗口最小尺寸；
//  3. 仅处理窗口外观，不承担其他启动副作用（Java 预扫描仍由根视图触发）。
//

import SwiftUI
import AppKit

/// 根窗口外观配置：透明标题栏 + 全尺寸内容区 + 最小尺寸。
private struct LauncherWindowModifier: ViewModifier {

    func body(content: Content) -> some View {
        content.onAppear {
            guard let window = NSApp.windows.first else { return }
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 800, height: 550)
        }
    }
}

extension View {
    /// 为启动器根视图应用根窗口外观配置。
    func launcherWindow() -> some View {
        modifier(LauncherWindowModifier())
    }
}
