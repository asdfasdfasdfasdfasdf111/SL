import SwiftUI

@main
struct SLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // 崩溃自捕获：崩溃后把线程堆栈写到 ~/Library/Logs/SL_crash.log（LLDB 拦截时系统不落 .ips）
        CrashReporter.install()
        // 启动即后台预热本地 Modrinth 全量目录，让下载/mod 页首帧即有数据（参考 PCL 的加载器秒出）
        LocalModCatalog.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(launchPanel: LaunchPanelState.shared)
                // 窗口最小尺寸的唯一声明处（800×590）：WindowGroup 默认 .automatic 策略在
                // 非 Settings 场景等价 .contentMinSize，窗口最小尺寸由本内容约束推导。
                // 依据：NSWindow.contentMinSize「takes precedence over the minSize property」
                // https://developer.apple.com/documentation/appkit/nswindow/contentminsize
                // 与 Scene.windowResizability(_:) 的默认值说明（macOS 13.0+）
                // https://developer.apple.com/documentation/swiftui/scene/windowresizability(_:)
                // AppKit 侧（AppDelegate / LauncherWindowModifier）原有的 minSize 声明
                // 均被本约束压过，已删除；数值以本行为准，勿在他处再声明。
                .frame(minWidth: 800, minHeight: 590)
        }
        .windowStyle(.hiddenTitleBar)
        // 默认窗口尺寸 900×660：macOS 13+ 的 Scene.defaultSize 与 SceneBuilder 条件语句
        // 在 12 上不可用，改由 AppDelegate.applicationDidFinishLaunching 统一设置。
    }
}

