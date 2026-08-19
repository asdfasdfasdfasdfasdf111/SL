import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct CategoryContentView: View {
    let category: Category
    let searchText: String
    @EnvironmentObject var settings: LauncherSettings
    @ObservedObject var theme = ThemeManager.shared
    // 启动会话/日志面板/启动进度统一由全局单例持有（启动回调零 self 捕获，UAF 根治）
    @ObservedObject var sessionManager = LaunchSessionManager.shared
    
    @State private var usernameFieldScale: CGFloat = 1.0
    @FocusState private var isUsernameFocused: Bool
    @State private var skinButtonScale: CGFloat = 1.0
    // 头像皮肤数据首帧缓存：视图创建时同步从本地（持久化皮肤 → UUID 皮肤磁盘缓存 → 内置 Steve）预载，
    // 双层渲染（头+帽）拿到数据后立即裁剪显示，首帧不再空白等待 JAR 提取
    @State private var avatarSkinData: Data? = CategoryContentView.preloadedSkinData()

    private var launchView: some View {
        GeometryReader { geometry in
            let cardWidth: CGFloat = 280
            let buttonWidth = cardWidth * 0.7
            let avatarSize = buttonWidth * 0.7
            let logCardHeight = geometry.size.height * 0.32
            // 卡片随内容区动态高度：上下各留 20pt 空隙，底部不贴边但始终延伸到底部附近。
            let cardHeight = max(0, geometry.size.height - 40)
            launchContent(cardWidth: cardWidth, buttonWidth: buttonWidth, avatarSize: avatarSize, logCardHeight: logCardHeight, cardHeight: cardHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // 关闭「窗口/页面首次出现时自动选中名称框」：macOS 上绑定了 .focused 的 TextField
        // 是窗口中第一个可聚焦控件时，AppKit 会在成为 key window 时自动将其置为 firstResponder。
        // 显式声明默认焦点为 false，让用户主动点击/按 Tab 才聚焦，而不是打开启动器就被选中。
        .defaultFocus($isUsernameFocused, false)
        // ⚠️ .defaultFocus(false) 只约束 SwiftUI 默认焦点，AppKit 仍会把窗口首个 TextField
        // 自动置为 firstResponder（表现为打开即聚焦/全选）。此处挂一个占位 NSView，
        // 在页面加入窗口、布局完成后主动 makeFirstResponder(nil) 清掉焦点，仅启动生效
        .background(FirstResponderReset())
        .onReceive(NotificationCenter.default.publisher(for: .closeGameSession)) { note in
            if let session = note.object as? GameSession {
                LaunchCoordinator.closeSession(session, sessionManager: sessionManager)
            }
        }
    }

    private func launchContent(cardWidth: CGFloat, buttonWidth: CGFloat, avatarSize: CGFloat, logCardHeight: CGFloat, cardHeight: CGFloat) -> some View {
        ZStack {
            // 透明点击层（最底层）：点击任意空白处让用户名输入框失焦（macOS 点击非焦点区不自动失焦）
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isUsernameFocused = false }
            HStack(alignment: .top, spacing: 20) {
                leftCard(cardWidth: cardWidth, avatarSize: avatarSize, buttonWidth: buttonWidth)
                    .frame(height: cardHeight, alignment: .top)
                    .zIndex(1)
                logPanel(logCardHeight: logCardHeight)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            CloseSessionButton(
                isLaunching: sessionManager.isLaunching,
                hasRunningSessions: sessionManager.hasRunningSessions,
                onTap: { LaunchCoordinator.handlePowerTap(sessionManager: sessionManager) }
            )
        }
    }
    private func leftCard(cardWidth: CGFloat, avatarSize: CGFloat, buttonWidth: CGFloat) -> some View {
        let tapLaunch: () -> Void = {
            isUsernameFocused = false
            guard !settings.selectedMinecraftVersion.isEmpty else {
                settings.launchErrorMessage = "请先在「游戏」分类中选择一个版本"
                settings.showLaunchAlert = true
                return
            }
            guard !sessionManager.isLaunching else { return }
            startLaunch()
        }
        return VStack(spacing: 16) {
            if !settings.selectedMinecraftVersion.isEmpty {
                Text("当前版本: \(settings.selectedMinecraftVersion)")
                    .font(.caption).foregroundColor(.secondary).padding(.top, 4)
            } else {
                Text("未选择版本").font(.caption).foregroundColor(.secondary).padding(.top, 4)
            }
            Spacer(minLength: 0)
            avatarView(avatarSize: avatarSize)
            usernameField
            skinButton
            Spacer(minLength: 0)
            // 占位：启动按钮放在卡片背景的 overlay 上钉底（见下方 overlay），
            // 这里 76pt 透明占位防止 VStack 内容与按钮重叠
            Color.clear.frame(height: 76)
        }
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 24).fill(.regularMaterial).shadow(radius: 12)
                .overlay(
                    LaunchButton(
                        buttonWidth: buttonWidth,
                        isLaunching: sessionManager.isLaunching,
                        launchPhase: sessionManager.launchPhase,
                        lightProgress: sessionManager.lightProgress,
                        darkProgress: sessionManager.darkProgress,
                        onTap: tapLaunch
                    )
                    .padding(.bottom, 24),
                    alignment: .bottom
                )
        )
    }

    private func avatarView(avatarSize: CGFloat) -> some View {
        ZStack {
            // 双层渲染（还原：头 + 帽层叠加消除半透明），数据来自首帧预载缓存。
            // .id(data)：@State 初始值仅在首次出现生效，皮肤数据变化时靠 id 变化强制重建并重新裁剪
            if let data = avatarSkinData {
                SkinLayerView(imageData: data, startX: 8, startY: 8, width: 8 * 5.4 / 58 * avatarSize, height: 8 * 5.4 / 58 * avatarSize)
                    .id(data)
                    .shadow(color: Color.black.opacity(0.2), radius: 1)
                SkinLayerView(imageData: data, startX: 40, startY: 8, width: 7.99 * 6.1 / 58 * avatarSize, height: 7.99 * 6.1 / 58 * avatarSize)
                    .id(data)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipped()
        .padding(6)
        .onAppear {
            // 延迟到渲染事务外：onAppear 同步写 @Published 会触发
            // "Modifying state during view update"（UAF 崩溃前兆）
            DispatchQueue.main.async {
                // 确保 skinImageURL 存在（启动进游戏时皮肤包方案需要），完成后 onChange 刷新缓存
                loadSkinImageIfNeeded()
            }
        }
        .onChange(of: settings.skinImageURL) { _ in
            refreshSkinData()
        }
    }

    /// 皮肤数据变更后刷新首帧缓存（后台读文件，避免主线程 IO）
    private func refreshSkinData() {
        guard let url = settings.skinImageURL, FileManager.default.fileExists(atPath: url.path) else { return }
        Task.detached(priority: .userInitiated) {
            if let data = try? Data(contentsOf: url) {
                await MainActor.run { self.avatarSkinData = data }
            }
        }
    }

    /// 视图创建时同步预载皮肤数据：持久化皮肤原图 → 离线 UUID 皮肤磁盘缓存 → 内置 Steve。
    /// 均为本地小文件（几 KB~几十 KB），个位数毫秒级，首帧双层裁剪立即有图
    private static func preloadedSkinData() -> Data? {
        let settings = LauncherSettings.shared
        if let url = settings.skinImageURL, FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
        if let data = MinecraftSkinManager.shared.getSkinData(forUUID: offlineUUID) {
            return data
        }
        if let builtin = Bundle.main.url(forResource: "stf", withExtension: "png") {
            return try? Data(contentsOf: builtin)
        }
        return nil
    }

    /// 确保 skinImageURL 存在，不存在则从缓存/JAR/内置皮肤加载
    private func loadSkinImageIfNeeded() {
        guard !sessionManager.isLaunching else { return }
        if settings.skinImageURL != nil, FileManager.default.fileExists(atPath: settings.skinImageURL!.path) { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
        try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")

        // 1. 优先从皮肤文件系统缓存加载
        let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
        if let cachedSkinData = MinecraftSkinManager.shared.getSkinData(forUUID: offlineUUID) {
            try? cachedSkinData.write(to: skinDestURL)
            settings.skinImageURL = skinDestURL
            return
        }

        // 2. 从 JAR 提取
        let gameDirPath = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
        if !settings.selectedMinecraftVersion.isEmpty && !gameDirPath.isEmpty,
           let gameDirURL = Optional(URL(fileURLWithPath: gameDirPath)),
           let skinURL = SkinExtractor.extractFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
            if let skinData = try? Data(contentsOf: skinURL) {
                try? skinData.write(to: skinDestURL)
                settings.skinImageURL = skinDestURL
            } else {
                settings.skinImageURL = skinURL
            }
            return
        }

        // 3. 使用内置皮肤
        if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
            settings.skinImageURL = builtinURL
        }
    }

    private var usernameField: some View {
        VStack(spacing: 6) {
            TextField("离线模式用户名", text: $settings.offlineUsername)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(isUsernameFocused ? theme.accentColor : Color.clear, lineWidth: 1.5))
                )
                .foregroundColor(.primary)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: 150)
                .scaleEffect(usernameFieldScale)
                .animation(.punchySpring, value: usernameFieldScale)
                .focused($isUsernameFocused)
                .onChange(of: isUsernameFocused) { focused in
                    if focused {
                        // ⚠️ onChange 处于视图更新事务中，withAnimation 内同步写 @State 同样会触发
                        // "Modifying state during view update"（UAF 前兆），延迟到渲染事务外
                        DispatchQueue.main.async {
                            withAnimation(.punchySpring) { usernameFieldScale = 1.1 }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.punchySpring) { usernameFieldScale = 1.0 }
                        }
                    }
                }
            // PCL2 风格提示（非阻塞）：超过 16 字符 / 包含非英文数字下划线时显示
            if let hint = offlineUsernameHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
    }

    /// 离线用户名提示（PCL2 PageLoginLegacy 的 HintChinese 移植）
    private var offlineUsernameHint: String? {
        OfflineUsernameValidator.hint(for: settings.offlineUsername)
    }

    private var skinButton: some View {
        Button(action: {
            isUsernameFocused = false
            withAnimation(.punchySpring) { skinButtonScale = 1.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.punchySpring) { skinButtonScale = 1.0 }
            }
            OfflineSkinService.selectSkinImage(settings: settings)
        }) {
            Text("选择皮肤")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.accentColor, lineWidth: 1)
                        .background(.ultraThinMaterial)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(skinButtonScale)
    }

    private func logPanel(logCardHeight: CGFloat) -> some View {
        Group {
            if sessionManager.showLogView && !sessionManager.sessions.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(sessionManager.sessions) { session in
                        sessionLogCard(session: session, logCardHeight: logCardHeight)
                            .frame(maxWidth: .infinity)
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                )
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .offset(y: sessionManager.showLogView ? 0 : 300)
        .opacity(sessionManager.showLogView ? 1 : 0)
        .animation(.exaggeratedSpring, value: sessionManager.showLogView)
        .animation(.exaggeratedSpring, value: sessionManager.sessions.count)
    }

    private func sessionLogCard(session: GameSession, logCardHeight: CGFloat) -> some View {
        SessionLogCardView(session: session, logCardHeight: logCardHeight)
    }

    var body: some View {
        Group {
            if category.name == "个性化" {
                ColorPickerView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if category.name == "启动" {
                launchView
            } else if category.name == "游戏" {
                GameCategoryView().frame(maxWidth: .infinity, maxHeight: .infinity).id(category.id)
            } else if category.name == "下载" {
                DownloadCategoryView().frame(maxWidth: .infinity, maxHeight: .infinity).id(category.id)
            } else if category.name == "联机" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 20) { }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            } else if category.name == "赞助" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                        SponsorCard(imageName: "zanzhu1", title: "赞助方式一")
                        SponsorCard(imageName: "zanzhu2", title: "赞助方式二")
                        ThanksCard()
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 20) { }.padding(32) }
                    .background(Color.clear)
                }
            }
        }
        .id(category.id)
        .onChange(of: settings.selectedMinecraftVersion) { _ in
            if !sessionManager.isLaunching {
                // 延迟到渲染事务外执行：onChange 处于视图更新事务中，同步写 @Published
                // 会触发 "Modifying state during view update" → 未定义行为 → UAF 崩溃（EXC_BAD_ACCESS 跳进位图区）
                DispatchQueue.main.async {
                    OfflineSkinService.loadAvatarFromGameOrBundle(isLaunching: sessionManager.isLaunching, settings: settings)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GameVersionSelected"))) { _ in
            if !sessionManager.isLaunching {
                DispatchQueue.main.async {
                    OfflineSkinService.loadDefaultIfNeeded(isLaunching: sessionManager.isLaunching, settings: settings)
                }
            }
        }
        .onAppear {
            // 同样延迟执行：onAppear 在视图渲染事务中触发，同步改 @Published 会破坏状态机
            DispatchQueue.main.async {
                OfflineSkinService.loadAvatarFromGameOrBundle(isLaunching: sessionManager.isLaunching, settings: settings)
                OfflineSkinService.loadDefaultIfNeeded(isLaunching: sessionManager.isLaunching, settings: settings)
            }
        }
        .onDisappear {
            sessionManager.stopDarkBarAnimation()
        }
    }
    
    /// 启动编排已整体下沉到 LaunchCoordinator（版本/用户名校验 → 皮肤准备 → pclLaunch 六段回调 → 会话登记）
    private func startLaunch() {
        LaunchCoordinator.start(settings: settings, sessionManager: sessionManager)
    }
}

/// 占用首帧焦点（0×0 不可见）：可接收焦点的占位 NSView 抢占 initialFirstResponder，
/// 并在窗口成为 key 时再次抢占，杜绝用户名输入框被 AppKit 自动置为 firstResponder（打开即全选）。
/// 仅启动头 2 秒内抢（didBecomeKey 兜底），之后让用户正常 Tab/点击聚焦，不干扰输入。
private struct FirstResponderReset: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FocusSinkView(frame: .zero)
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class FocusSinkView: NSView {
    /// NSView 默认不可聚焦，覆写为 true 才能作为 first responder 候选抢占
    override var acceptsFirstResponder: Bool { true }
    /// 仅启动头 2 秒内允许抢占（didBecomeKey 可能多次触发，避免长期偷焦点）
    private var guardUntil: Date?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        guardUntil = Date().addingTimeInterval(2)
        window.initialFirstResponder = self
        // 立即抢一次 + 监听 becomeKey 兜底（窗口首次 key 时 AppKit 才做自动聚焦，此时未必已布局）
        tryGrab(window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window
        )
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        guard let until = guardUntil, Date() < until else { return }
        // 延迟到 AppKit 完成自动聚焦之后再抢，保证压过 TextField 成为 firstResponder
        tryGrab(window)
    }

    private func tryGrab(_ window: NSWindow) {
        DispatchQueue.main.async {
            window.initialFirstResponder = self
            _ = window.makeFirstResponder(self)
        }
    }
}
