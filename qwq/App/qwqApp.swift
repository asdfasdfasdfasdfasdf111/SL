//
//  qwqApp.swift
//  应用入口：Scene 声明（主窗口 / 默认尺寸 / 菜单命令 / 设置场景）。
//
//  职责：① 首帧之前完成三件一次性初始化 —— 崩溃自捕获安装（CrashReporter.install）、
//           本地 Modrinth 全量目录后台预热（LocalModCatalog.warmUp）、
//           内存压力订阅注册（MemoryCacheReclaimer.register）；
//        ② 声明 WindowGroup 与**窗口最小尺寸 800×590 的唯一来源**（内容约束）；
//        ③ 声明「分类」菜单与 ⌘1…⌘6（经 NavigationIntent 单槽送到 ContentView）；
//        ④ 声明「设置…」（⌘,）的 Settings 场景（内容镜像「个性化」页）。
//  边界：不含任何界面布局与业务逻辑（内容全在 ContentView 及其子树）。
//        窗口最小尺寸**不得**在他处重复声明：AppDelegate 与窗口修饰器里的旧声明已删，
//        因为 `NSWindow.contentMinSize` 的取值会被这里的内容约束压过，重复声明只会造成
//        两处数值不一致（历史上就出现过 800×590 与 800×550 并存）。
//  关键约束：`init()` 在主线程、且早于首帧 —— **任何同步 IO 都会直接推迟窗口出现**。
//        因此这里只允许两类动作：装处理器（CrashReporter）与把重活丢到后台
//        （LocalModCatalog.warmUp 内部就是 Task.detached）。新增初始化前先确认它不读盘。
//

import SwiftUI

@main
struct SLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // 崩溃自捕获：崩溃后把线程堆栈写到 ~/Library/Logs/SL_crash.log（LLDB 拦截时系统不落 .ips）
        CrashReporter.install()
        // 内存压力订阅：把「各子系统缓存回收」登记为内存压力事件的订阅者。
        // 必须在这里（装配期）登记，AppContext 只发事件、不认识缓存属主。仅登记闭包，不读盘。
        MemoryCacheReclaimer.register()
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
        // 默认窗口尺寸 900×660（居中由系统处理）。
        //
        // 这一行曾经丢过，经过如下：e62d7f3（降到 macOS 12.0）把原来的 `.defaultSize(...)` 删掉，
        // 改用 AppDelegate 里 `if #unavailable(macOS 13.0)` 的兜底；17cca21 把部署目标回退到 13.0
        // 后该分支永不执行，兜底从未生效；更晚的 e624d33 那次窗口尺寸审计只覆盖 minSize，
        // 没发现 defaultSize 已丢 —— 期间全库没有任何地方声明默认尺寸。
        // 2026-09-23 恢复：`.defaultSize` 是 Scene 级 API，自 macOS 13.0 起可用，
        // 正好等于本项目部署目标，无需任何可用性守卫。
        .defaultSize(width: 900, height: 660)
        // 菜单栏命令：「分类」菜单 + ⌘1…⌘6。
        //
        // 之前全库没有任何 `.commands { }` / `CommandGroup` / `keyboardShortcut`（评审第 10 条）：
        // 没有偏好设置入口、没有菜单命令、没有快捷键，全部操作只能靠鼠标点导航。
        // 这里补上最常用的一类（分类切换）。菜单在 Scene 级、导航状态在视图级，
        // 两者不在同一视图树，故经 `NavigationIntent` 单槽中转，见该文件说明。
        .commands {
            CommandMenu("分类") {
                // 身份用 `category.id` 而不是枚举下标：`Category` 自身是 `Identifiable`，
                // 且 `Category.all` 是 `static let`（每个实例只建一次、UUID 稳定），
                // 所以 id 是「活得比视图久」的稳定身份；下标只是位置，任何顺序调整都会错配复用。
                // （`enumerated()` 保留是因为快捷键 ⌘N 要用到序号。）
                ForEach(Array(Category.all.enumerated()), id: \.element.id) { index, category in
                    Button(category.name) {
                        NavigationIntent.shared.requestCategory(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        // 「设置…」（⌘,）：`Settings` 场景由系统自动在 App 菜单里生成入口，无需手工建菜单项。
        // 内容直接镜像「个性化」页（见 SettingsScene 的说明）。
        Settings {
            SettingsScene()
        }
    }
}

