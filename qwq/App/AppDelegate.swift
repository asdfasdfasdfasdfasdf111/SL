import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first else { return }
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
        // 说明：本工程部署目标为 macOS 13.0，下面的 12.x 分支在当前配置下不会执行
        //（保留以便将来下调部署目标时仍有尺寸兜底）。
        if #unavailable(macOS 13.0) {
            let size = NSSize(width: 900, height: 660)
            let screenFrame = NSScreen.main?.visibleFrame ?? .zero
            let origin = NSPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.midY - size.height / 2
            )
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        // 应用图标缩放到 0.7 倍
        if let icon = NSImage(named: "AppIcon") {
            let scale: CGFloat = 0.7
            let newSize = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: newSize),
                      from: NSRect(origin: .zero, size: icon.size),
                      operation: .copy,
                      fraction: 1.0)
            resized.unlockFocus()
            NSApp.applicationIconImage = resized
        }
    }
}