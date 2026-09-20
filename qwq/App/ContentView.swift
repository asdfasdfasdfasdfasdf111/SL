import SwiftUI
import AppKit
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
    // 启动相关界面状态（Java 提示气泡、启动失败提示）
    @ObservedObject private var launchPanel = LaunchPanelState.shared
    // 下载详情页独立页面 + 全局圆形下载按钮（对标 PCL.Mac AppRouter：
    // 详情页为整页替换渲染的独立页面，圆按钮为 ContentView 顶层全局 overlay）
    
    var body: some View {
        ZStack {
            // 顶部标题栏与分类导航永久保留；下载详情只替换导航栏下方的内容区。
            // 不能在这里整页替换，否则会把用户要求保留的导航栏一并卸载。
            mainContent

            // 全局弹窗/提示/圆按钮：放在页面切换层之外，不随页面卸载
            JavaSelectionPopup(message: launchPanel.javaPopupMessage, isPresented: $launchPanel.showJavaPopup)
                .position(x: 450, y: 200)
                .zIndex(100)

            if dropInstall.showModInstallSheet {
                ModInstallSelectionView(
                    modName: dropInstall.pendingModName,
                    modVersion: dropInstall.pendingModVersion,
                    instances: dropInstall.modInstallInstances,
                    onConfirm: { selected in
                        dropInstall.confirmModInstall(instances: selected)
                    },
                    onCancel: {
                        dropInstall.cancelModInstall()
                    }
                )
                .zIndex(200)
            }

            if dropInstall.showModpackInstallSheet {
                ModpackFolderPickerView(
                    packName: dropInstall.pendingModpackName,
                    onConfirm: { folderURL in
                        dropInstall.confirmModpackInstall(folderURL: folderURL)
                    },
                    onCancel: {
                        dropInstall.cancelModpackInstall()
                    }
                )
                .zIndex(200)
            }

            if interaction.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(ThemeManager.shared.accentColor, lineWidth: 3)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(ThemeManager.shared.accentColor.opacity(0.08))
                    )
                    .padding(8)
                    .allowsHitTesting(false)
                    .zIndex(150)
            }

            // 圆形毛玻璃下载按钮：全局顶层（对标 PCL.Mac installTaskButtonOverlay），
            // 任何页面可见可点；点击 toggle 进/出详情页（无返回键，再次点击回到刚才的页面）。
            // zIndex(40) 高于详情页(30)：详情页打开时按钮仍可见可点。
            if navigation.isDownloadCircleVisible {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 15, y: 6)

                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                }
                .scaleEffect(navigation.downloadCircleScale)
                .opacity(navigation.downloadCircleOpacity)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(40)
                .onTapGesture {
                    // 动画由 DownloadDetailManager.toggle 内部统一触发（弹簧曲线）
                    navigation.toggleDownloadDetail()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 550)
        // 全局用户提示层（PopupManager / hint 的唯一可见出口）：仅顶部横幅区域可点，
        // 其余区域点击穿透到下方界面；不参与、不改变原有视图层级。
        .overlay { NoticeOverlay() }
        .environmentObject(settings)
        // 切换分类时自动收起下载详情（下载与圆按钮保持，仅关闭覆盖层）
        .onChange(of: navigation.selectedCategory) { _ in
            navigation.handleSelectedCategoryChange()
        }
        .alert("启动失败", isPresented: $launchPanel.showLaunchAlert, presenting: launchPanel.launchErrorMessage) { _ in
            Button("确定") { launchPanel.clearLaunchError() }
        } message: { error in
            Text(error)
        }
        // Java 预扫描经 Java 模块入口触发，根视图不再直接持有 JavaManager
        .onAppear {
            DefaultJavaRepository.shared.preScan()
        }
        // 窗口外观（透明标题栏 / 全尺寸内容区 / 最小尺寸 800×550）由独立修饰器负责
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
                // 标题栏（早期版本样式）：
                // 整个头部（标题行 + 分类行）共享毛玻璃背景，与早期版本一致
                VStack(alignment: .leading, spacing: 0) {
                    // 第一行：应用大标题 + 右侧留白，左侧对齐，顶部留出窗口可拖拽区域空间
                    HStack {
                        Text("SL启动器")
                            .font(.largeTitle.bold())
                        Spacer()
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    // 第二行：分类导航靠左对齐
                    AnimatedCategoryPicker(selectedCategory: $navigation.selectedCategory, categories: navigation.categories)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .zIndex(20)
                }
                .background(BlurView(material: .contentBackground, blendingMode: .withinWindow).ignoresSafeArea(edges: .top))
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5).padding(.horizontal, 32)
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
                CategoryContentView(category: category, searchText: interaction.searchText)
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
        ContentView().frame(width: 900, height: 650)
    }
}