import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 800, height: 590)
        // 说明：本工程部署目标为 macOS 13.0，下面的 12.x 分支在当前配置下不会执行
        //（保留以便将来下调部署目标时仍有兜底）。
        // 窗口默认尺寸实际由根视图的 .frame(minWidth:minHeight:) 与 windowResizability 推导决定，
        // 参见 docs/APPLE_API_CHECKLIST.md 关于 contentMinSize 优先级的核对结论。
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