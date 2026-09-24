import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 取主窗口：优先 mainWindow，其次 keyWindow，再次任意可见窗口。
        // 不用 NSApp.windows.first——窗口顺序无官方保证、且可能含屏幕外窗口
        // （AppKit 文档：NSApp.windows 不保证顺序，可能包含不可见/离屏窗口）。
        // 取不到时不再静默 return，而是显式报错，避免「标题栏外观设置悄悄没生效」无从排查。
        guard let window = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible }) else {
            NSLog("SLAppDelegate: 启动期未取到主窗口，标题栏透明化/全尺寸内容区设置已跳过")
            return
        }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // 此处不再声明 window.minSize：窗口最小尺寸的唯一来源是根视图 qwqApp.swift 的
        // .frame(minWidth: 800, minHeight: 590)（内容约束）。
        // 官方明文：NSWindow.contentMinSize「This method takes precedence over the minSize
        // property.」——https://developer.apple.com/documentation/appkit/nswindow/contentminsize
        // 故在 AppKit 侧写 minSize（度量对象是含标题栏的 frame，与内容区不同）不会改变
        // 内容区最小尺寸的实际效果，属冗余声明。此前本处写 800×590、LauncherWindowModifier
        // 写 800×550，两处数值不一致且均被内容约束压过，已一并删除并统一为 800×590。
        // 下调部署目标后亦无需在此补声明：contentMinSize 的优先级不随系统版本变化，
        // 且 WindowGroup 默认 .automatic 策略在非 Settings 场景即等价 .contentMinSize
        //（https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)，macOS 13.0+）。

        // 应用图标缩放到 0.7 倍。改用 NSImage(size:flipped:drawingHandler:) 初始化器，
        // 不使用已弃用的 lockFocus()/unlockFocus()（SDK 头文件 API_DEPRECATED）。
        if let icon = NSImage(named: "AppIcon") {
            let scale: CGFloat = 0.7
            let newSize = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let resized = NSImage(size: newSize, flipped: false) { rect in
                icon.draw(in: rect,
                          from: NSRect(origin: .zero, size: icon.size),
                          operation: .copy,
                          fraction: 1.0)
                return true
            }
            NSApp.applicationIconImage = resized
        }
    }
}