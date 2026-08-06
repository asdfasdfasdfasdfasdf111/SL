import SwiftUI

@main
struct qwqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 590)  // 原 570，再增加 20 点
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 660)  // 默认高度相应增加，保持比例
    }
}

