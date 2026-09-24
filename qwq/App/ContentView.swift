//
//  ContentView.swift
//  应用根视图（窗口内容层）。
//
//  职责：三段式结构 ——
//    ① 主内容 `mainContent`：毛玻璃背景 + HomeHeader 标题栏 + categoryCanvas 分类画布；
//    ② 全局叠加层 `RootOverlays`（弹窗 / 提示 / 下载圆按钮）：放在页面切换层**之外**，
//       因此不随页面卸载；它必须声明在 mainContent 之后（同 zIndex 时由声明顺序决定上下）；
//    ③ 全局提示横幅 `NoticeOverlay`（PopupManager / hint 的唯一可见出口）。
//  边界：本视图**只渲染、只转发事件**，不含业务决策 ——
//    页面导航归 NavigationState、拖拽安装归 DropInstallCoordinator、
//    启动提示归 LaunchPanelState（注入式：本视图只订阅、不创建）、
//    下载详情开关归 DownloadDetailManager（经 NavigationState 透传）。
//  关键约束：
//    · 六个分类页在 `categoryCanvas` 里是**整排常驻**的（HStack，不是惰性容器），
//      各页 onAppear 因此会在冷启动时全部触发 —— 这是"首屏即有数据"的刻意设计，
//      改动容器类型前先读各页 onAppear 的副作用清单（版本扫描 / 目录预热 / 取数）。
//    · 菜单栏「分类」命令经 NavigationIntent 单槽中转后落到本视图的 NavigationState，
//      应用后必须 `consume()`，否则同一请求会在后续重绘中重复生效。
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var settings = LauncherSettings.shared
    // 页面导航状态（当前分类 / 画布拖拽位移 / 下载详情页开关）统一由 NavigationState 持有
    @StateObject private var navigation = NavigationState()
    // 根视图即时交互状态（搜索词 / 拖入高亮）由 HomeInteractionState 持有
    @StateObject private var interaction = HomeInteractionState()

    // 拖拽安装的业务决策（文件分流 / 实例匹配 / 安装 / 提示）全部收在协调器内，
    // 本视图只转发拖拽事件、按协调器状态渲染弹窗。
    @StateObject private var dropInstall = DropInstallCoordinator()
    // 启动相关界面状态（Java 提示气泡、启动失败提示）。由场景入口注入，
    // 本视图只订阅、不创建（@ObservedObject 不拥有对象，不得写默认值）
    @ObservedObject var launchPanel: LaunchPanelState
    // 下载详情页独立页面 + 全局圆形下载按钮：
    // 详情页为整页替换渲染的独立页面，圆按钮为 ContentView 顶层全局 overlay。
    
    var body: some View {
        ZStack {
            // 顶部标题栏与分类导航永久保留；下载详情只替换导航栏下方的内容区。
            // 不能在这里整页替换，否则会把用户要求保留的导航栏一并卸载。
            mainContent

            // 全局弹窗/提示/圆按钮：放在页面切换层之外，不随页面卸载。
            // 必须置于 mainContent 之后：本层与 mainContent 的 zIndex 同为默认值，
            // 由声明顺序决定上下关系，调换位置会使全部叠加层落到主内容之下。
            // 各叠加层之间的层级与顺序由 RootOverlays 内部保留。
            RootOverlays(launchPanel: launchPanel,
                         dropInstall: dropInstall,
                         interaction: interaction,
                         navigation: navigation)
        }
        // 全局用户提示层（PopupManager / hint 的唯一可见出口）：仅顶部横幅区域可点，
        // 其余区域点击穿透到下方界面；不参与、不改变原有视图层级。
        .overlay { NoticeOverlay(center: NoticeCenter.shared, theme: ThemeManager.shared) }
        .environmentObject(settings)
        // 切换分类时自动收起下载详情（下载与圆按钮保持，仅关闭覆盖层）
        .onChange(of: navigation.selectedCategory) { _ in
            navigation.handleSelectedCategoryChange()
        }
        // 菜单栏「分类」命令（⌘1…⌘6）：请求经 NavigationIntent 单槽送达，应用后立即消费，
        // 避免同一请求在后续重绘中重复生效。写 selectedCategory 会照常触发上面的 onChange
        // （切换分类时收起下载详情），不绕过既有行为。
        .onReceive(NavigationIntent.shared.$pendingCategoryIndex) { index in
            guard let index, navigation.categories.indices.contains(index) else { return }
            navigation.selectedCategory = navigation.categories[index]
            NavigationIntent.shared.consume()
        }
        // 启动 / 下载失败提示已由 RootOverlays 里的任务气泡（TaskPill）承担，
        // 不再使用系统 alert：同一份状态（showLaunchAlert / launchErrorMessage）换一种呈现，
        // 状态源与写入方一个都没动。
        // Java 预扫描经 Java 模块入口触发，根视图不再直接持有 JavaManager
        .onAppear {
            DefaultJavaRepository.shared.preScan()
            // 仅 DEBUG：无人值守启动开关（默认空实现，见 DebugAutoLaunch.swift）
            DebugAutoLaunch.maybeStart()
        }
        // 窗口外观（透明标题栏 / 全尺寸内容区）由独立修饰器负责；
        // 窗口最小尺寸（800×590）的唯一声明处是 qwqApp.swift 的根视图 frame，
        // 本视图不再重复声明（原先嵌套的 800×550 被外层 590 包住、不参与实际取值）
        .launcherWindow()
    }

    /// 主内容页（分类导航 + 内容区 + 拖拽背景），与下载详情页互斥整页切换：
    /// 详情页打开时本视图从视图树卸载，关闭后重建（状态靠全局单例/磁盘缓存兜底）。
    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            BlurView(material: .fullScreenUI, blendingMode: .behindWindow).ignoresSafeArea()
                .onDrop(of: [.fileURL], isTargeted: $interaction.isDropTargeted) { providers in
                    return dropInstall.handle(providers: providers)
                }
            VStack(alignment: .leading, spacing: 0) {
                // 标题栏（早期版本样式）：标题行 + 分类导航 + 底部分隔线，整体由 HomeHeader 负责
                HomeHeader(selectedCategory: $navigation.selectedCategory, categories: navigation.categories)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack {
                        if navigation.isShowingDownloadDetail {
                            DownloadDetailView()
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        } else {
                            categoryCanvas(width: width)
                        }
                    }
                    .clipped()
                }
                .background(BlurView(material: .fullScreenUI, blendingMode: .behindWindow))
            }
        }
    }
    /// 旧版分类画布：所有分类页完整横向排布，点击导航或拖拽时整页连续滑动；
    /// 从第 1 项跳到第 5 项会真实经过中间页面，拖拽中内容实时跟手。
    /// 位置状态（当前下标 + 拖拽位移）由 NavigationState 持有，本函数只做渲染与手势转发。
    private func categoryCanvas(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(navigation.categories) { category in
                CategoryContentView(category: category,
                                    searchText: interaction.searchText,
                                    theme: ThemeManager.shared,
                                    sessionManager: LaunchSessionManager.shared)
                    .frame(width: width)
            }
        }
        .offset(x: -CGFloat(navigation.selectedIndex) * width + navigation.dragOffset)
        .animation(NavigationState.canvasSpring, value: navigation.selectedIndex)
        .gesture(
            // 手势构造、逐帧位移写入与 withAnimation 调用点仍留在视图层：迁入状态层
            // 并不减少视图职责（DragGesture 必须在此构造、translation 必须逐帧回写），
            // 反而把手势识别与事务语义引入 ViewModel。此处只把曲线/阈值/裁决归口。
            DragGesture(minimumDistance: NavigationState.canvasDragMinimumDistance)
                .onChanged { value in
                    guard NavigationState.isHorizontalDrag(value.translation) else { return }
                    navigation.dragOffset = value.translation.width
                }
                .onEnded { value in
                    guard NavigationState.isHorizontalDrag(value.translation) else {
                        withAnimation(NavigationState.canvasSpring) {
                            navigation.dragOffset = 0
                        }
                        return
                    }
                    let targetIndex = navigation.canvasTargetIndex(translationWidth: value.translation.width,
                                                                    canvasWidth: width)
                    withAnimation(NavigationState.canvasSpring) {
                        navigation.selectedCategory = navigation.categories[targetIndex]
                        navigation.dragOffset = 0
                    }
                }
        )
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(launchPanel: LaunchPanelState.shared).frame(width: 900, height: 650)
    }
}