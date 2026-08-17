import Cocoa

class CustomWindow: NSWindow {
    // 可拖动区域的高度（与标题栏高度一致，建议 30）
    var dragRegionHeight: CGFloat = 30
    
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // 禁用默认的全窗口拖动
        self.isMovableByWindowBackground = false
        self.titlebarAppearsTransparent = true
        self.styleMask.insert(.fullSizeContentView)
        self.minSize = NSSize(width: 800, height: 590)  // 原 570，再增加 20 点
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = event.locationInWindow
        // 如果鼠标按下的位置在顶部可拖动区域内，则准备拖动
        if location.y <= dragRegionHeight {
            // 开始拖动（通过 mouseDragged 实现）
            super.mouseDown(with: event)
        } else {
            // 不在可拖动区域，正常传递事件给下层视图
            super.mouseDown(with: event)
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        let location = event.locationInWindow
        if location.y <= dragRegionHeight {
            self.performDrag(with: event)
        } else {
            super.mouseDragged(with: event)
        }
    }
}
