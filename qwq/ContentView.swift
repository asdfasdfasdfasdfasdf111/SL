import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selectedCategory: Category = Category.all.first!
    @State private var searchText = ""
    @State private var dragOffset: CGFloat = 0
    @StateObject private var settings = LauncherSettings.shared
    private let categories = Category.all
    private var selectedIndex: Int { categories.firstIndex(of: selectedCategory) ?? 0 }

    @State private var showModInstallSheet = false
    @State private var showModpackInstallSheet = false
    @State private var modInstallInstances: [GameInstance] = []
    @State private var pendingModURL: URL?
    @State private var pendingModVersion: String = ""
    @State private var pendingModName: String = ""
    @State private var pendingModpackURL: URL?
    @State private var pendingModpackName: String = ""
    @State private var isDropTargeted = false
    private let dragDropHandler = DragDropHandler()
    private let versionDetector = ModVersionDetector()
    // 下载详情页独立页面 + 全局圆形下载按钮（对标 PCL.Mac AppRouter：
    // 详情页为整页替换渲染的独立页面，圆按钮为 ContentView 顶层全局 overlay）
    @ObservedObject private var downloadDetail = DownloadDetailManager.shared
    
    var body: some View {
        ZStack {
            BlurView(material: .fullScreenUI, blendingMode: .behindWindow).ignoresSafeArea()
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    return dragDropHandler.handleDrop(providers: providers)
                }
                .onAppear {
                    dragDropHandler.onJarDropped = { url in
                        handleModDrop(url: url)
                    }
                    dragDropHandler.onModpackDropped = { url in
                        handleModpackDrop(url: url)
                    }
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
                    AnimatedCategoryPicker(selectedCategory: $selectedCategory, categories: categories)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .zIndex(20)
                }
                .background(BlurView(material: .contentBackground, blendingMode: .withinWindow).ignoresSafeArea(edges: .top))
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5).padding(.horizontal, 32)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    HStack(spacing: 0) {
                        ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                            CategoryContentView(category: category, searchText: searchText)
                                .frame(width: width)
                        }
                    }
                    .offset(x: -CGFloat(selectedIndex) * width + dragOffset)
                    .animation(.spring(response: 0.6, dampingFraction: 0.65, blendDuration: 0.15), value: selectedIndex)
                    .gesture(
                        DragGesture()
                            .onChanged { dragOffset = $0.translation.width }
                            .onEnded { value in
                                let threshold = width * 0.25
                                var newIndex = selectedIndex
                                if value.translation.width < -threshold && selectedIndex < categories.count - 1 {
                                    newIndex = selectedIndex + 1
                                } else if value.translation.width > threshold && selectedIndex > 0 {
                                    newIndex = selectedIndex - 1
                                }
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.65, blendDuration: 0.15)) {
                                    selectedCategory = categories[newIndex]
                                    dragOffset = 0
                                }
                            }
                    )
                }
                .background(BlurView(material: .fullScreenUI, blendingMode: .behindWindow))
            }
            JavaSelectionPopup(message: settings.javaPopupMessage, isPresented: $settings.showJavaPopup)
                .position(x: 450, y: 200)
                .zIndex(100)

            if showModInstallSheet {
                ModInstallSelectionView(
                    modName: pendingModName,
                    modVersion: pendingModVersion,
                    instances: modInstallInstances,
                    onConfirm: { selected in
                        installModToInstances(modURL: pendingModURL, instances: selected)
                        showModInstallSheet = false
                    },
                    onCancel: {
                        showModInstallSheet = false
                    }
                )
                .zIndex(200)
            }

            if showModpackInstallSheet {
                ModpackFolderPickerView(
                    packName: pendingModpackName,
                    onConfirm: { folderURL in
                        installModpack(packURL: pendingModpackURL, to: folderURL)
                        showModpackInstallSheet = false
                    },
                    onCancel: {
                        showModpackInstallSheet = false
                    }
                )
                .zIndex(200)
            }

            if isDropTargeted {
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

            // 下载详情页：独立页面（对标 PCL.Mac router.append(.installing) 后 getLastView() 整页替换），
            // 带非线性动画整页切换，不叠加在宿主视图图层上。
            if downloadDetail.isPresented {
                DownloadDetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        BlurView(material: .fullScreenUI, blendingMode: .behindWindow)
                            .ignoresSafeArea()
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
                    .zIndex(30)
            }

            // 圆形毛玻璃下载按钮：全局顶层（对标 PCL.Mac installTaskButtonOverlay），
            // 任何页面可见可点；点击 toggle 进/出详情页（无返回键，再次点击回到刚才的页面）。
            // zIndex(40) 高于详情页(30)：详情页打开时按钮仍可见可点。
            if downloadDetail.showCircleButton {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 55, height: 55)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 15, y: 6)

                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                }
                .scaleEffect(downloadDetail.circleScale)
                .opacity(downloadDetail.circleOpacity)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(40)
                .onTapGesture {
                    // 动画由 DownloadDetailManager.toggle 内部统一触发（弹簧曲线）
                    downloadDetail.toggle()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 550)
        .environmentObject(settings)
        .alert("启动失败", isPresented: $settings.showLaunchAlert, presenting: settings.launchErrorMessage) { _ in
            Button("确定") { settings.launchErrorMessage = nil }
        } message: { error in
            Text(error)
        }
        .onAppear {
            if let window = NSApp.windows.first {
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.minSize = NSSize(width: 800, height: 550)
                var frame = window.frame
                if frame.size.height > window.minSize.height {
                    frame.size.height = window.minSize.height
                    window.setFrame(frame, display: true, animate: true)
                }
            }
            JavaManager.shared.preScanJavaAsync()
        }
    }
    private func handleModDrop(url: URL) {
        let modName = url.deletingPathExtension().lastPathComponent

        guard let versionInfo = versionDetector.detectVersion(from: url) else {
            settings.launchErrorMessage = "无法检测模组「\(modName)」的 Minecraft 版本"
            settings.showLaunchAlert = true
            return
        }

        let instances = findMatchingInstances(for: versionInfo.versionRange)
        if instances.isEmpty {
            settings.launchErrorMessage = "未找到与模组「\(modName)」（需要 \(versionInfo.versionRange)）匹配的游戏版本"
            settings.showLaunchAlert = true
            return
        }

        pendingModURL = url
        pendingModName = modName
        pendingModVersion = versionInfo.versionRange
        modInstallInstances = instances
        showModInstallSheet = true
    }

    private func handleModpackDrop(url: URL) {
        let packName = url.deletingPathExtension().lastPathComponent
        pendingModpackURL = url
        pendingModpackName = packName
        showModpackInstallSheet = true
    }

    private func findMatchingInstances(for versionRange: String) -> [GameInstance] {
        let roots = MinecraftVersionManager.findGameRootDirectories()
        var seen = Set<String>()
        var instances: [GameInstance] = []

        for root in roots {
            let normalized = (root as NSString).standardizingPath
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let versions = MinecraftVersionManager.getVersions(from: normalized)
            for version in versions {
                if versionDetector.versionMatches(modVersion: versionRange, gameVersion: version) {
                    instances.append(GameInstance(rootPath: normalized, version: version))
                }
            }
        }

        let savedRoot = settings.selectedGameRoot
        if !savedRoot.isEmpty {
            let normalized = (savedRoot as NSString).standardizingPath
            if !seen.contains(normalized) {
                let versions = MinecraftVersionManager.getVersions(from: normalized)
                for version in versions {
                    if versionDetector.versionMatches(modVersion: versionRange, gameVersion: version) {
                        instances.append(GameInstance(rootPath: normalized, version: version))
                    }
                }
            }
        }

        return instances
    }

    private func installModToInstances(modURL: URL?, instances: [GameInstance]) {
        guard let modURL = modURL else { return }
        let modFileName = modURL.lastPathComponent

        for instance in instances {
            // 游戏启动时 gameDir = <rootPath>/versions/<version>，mods 在版本文件夹内
            let modsDir = URL(fileURLWithPath: instance.rootPath).appendingPathComponent("versions/\(instance.version)/mods")
            do {
                try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
                let destURL = modsDir.appendingPathComponent(modFileName)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: modURL, to: destURL)
            } catch {
                print("安装模组到 \(instance.rootPath) 失败: \(error.localizedDescription)")
            }
        }

        let count = instances.count
        settings.javaPopupMessage = "模组已安装到 \(count) 个实例"
        settings.showJavaPopup = true
    }

    private func installModpack(packURL: URL?, to folderURL: URL) {
        guard let packURL = packURL else { return }

        Task.detached(priority: .userInitiated) {
            do {
                try await ModpackInstaller().install(packURL: packURL, to: folderURL)
                await MainActor.run {
                    settings.javaPopupMessage = "整合包安装完成"
                    settings.showJavaPopup = true
                }
            } catch {
                await MainActor.run {
                    settings.launchErrorMessage = "整合包安装失败: \(error.localizedDescription)"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().frame(width: 900, height: 650)
    }
}