import SwiftUI

@main
struct qwqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // 启动即后台预热本地 Modrinth 全量目录，让下载/mod 页首帧即有数据（参考 PCL 的加载器秒出）
        DownloadCategoryView.warmUpLocalCatalog()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 590)  // 原 570，再增加 20 点
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 660)  // 默认高度相应增加，保持比例
    }
}

