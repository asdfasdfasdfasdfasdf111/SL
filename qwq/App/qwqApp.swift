import SwiftUI

@main
struct qwqApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // 崩溃自捕获：崩溃后把线程堆栈写到 ~/Library/Logs/qwq_crash.log（LLDB 拦截时系统不落 .ips）
        CrashReporter.install()
        // 启动即后台预热本地 Modrinth 全量目录，让下载/mod 页首帧即有数据（参考 PCL 的加载器秒出）
        LocalModCatalog.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 590)  // 原 570，再增加 20 点
        }
        .windowStyle(.hiddenTitleBar)
        // 默认窗口尺寸 900×660：macOS 13+ 的 Scene.defaultSize 与 SceneBuilder 条件语句
        // 在 12 上不可用，改由 AppDelegate.applicationDidFinishLaunching 统一设置。
    }
}

