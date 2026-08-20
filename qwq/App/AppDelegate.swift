import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first else { return }
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        window.minSize = NSSize(width: 800, height: 590)
        window.maxSize = NSSize(width: 800, height: 590)
        // macOS 12 没有 Scene.defaultSize，手动设置默认窗口尺寸（900×660）并居中；
        // macOS 13+ 由 qwqApp 里的 .defaultSizeCompat 声明。
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return NSSize(width: 800, height: 590)
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        return false
    }
}