import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = NSSize(width: 800, height: 590)
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