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

    private var launchView: some View {
        GeometryReader { geometry in
            let cardWidth: CGFloat = 280
            let buttonWidth = cardWidth * 0.7
            let avatarSize = buttonWidth * 0.7
            let logCardHeight = geometry.size.height * 0.32
            launchContent(cardWidth: cardWidth, buttonWidth: buttonWidth, avatarSize: avatarSize, logCardHeight: logCardHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onReceive(NotificationCenter.default.publisher(for: .closeGameSession)) { note in
            if let session = note.object as? GameSession {
                LaunchCoordinator.closeSession(session, sessionManager: sessionManager)
            }
        }
    }

    private func launchContent(cardWidth: CGFloat, buttonWidth: CGFloat, avatarSize: CGFloat, logCardHeight: CGFloat) -> some View {
        ZStack {
            // 透明点击层（最底层）：点击任意空白处让用户名输入框失焦（macOS 点击非焦点区不自动失焦）
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isUsernameFocused = false }
            HStack(alignment: .top, spacing: 20) {
                leftCard(cardWidth: cardWidth, avatarSize: avatarSize, buttonWidth: buttonWidth)
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
        VStack(spacing: 16) {
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
            Spacer()
            LaunchButton(
                buttonWidth: buttonWidth,
                isLaunching: sessionManager.isLaunching,
                launchPhase: sessionManager.launchPhase,
                lightProgress: sessionManager.lightProgress,
                darkProgress: sessionManager.darkProgress,
                onTap: {
                    isUsernameFocused = false
                    guard !settings.selectedMinecraftVersion.isEmpty else {
                        settings.launchErrorMessage = "请先在「游戏」分类中选择一个版本"
                        settings.showLaunchAlert = true
                        return
                    }
                    guard !sessionManager.isLaunching else { return }
                    startLaunch()
                }
            )
        }
        .frame(width: cardWidth)
        .background(RoundedRectangle(cornerRadius: 24).fill(.regularMaterial).shadow(radius: 12))
    }

    private func avatarView(avatarSize: CGFloat) -> some View {
        ZStack {
            if let skinURL = settings.skinImageURL,
               let data = try? Data(contentsOf: skinURL) {
                SkinLayerView(imageData: data, startX: 8, startY: 16, width: 8 * 5.4 / 58 * avatarSize, height: 8 * 5.4 / 58 * avatarSize)
                    .shadow(color: Color.black.opacity(0.2), radius: 1)
                SkinLayerView(imageData: data, startX: 40, startY: 16, width: 7.99 * 6.1 / 58 * avatarSize, height: 7.99 * 6.1 / 58 * avatarSize)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipped()
        .padding(6)
        .onAppear {
            // 延迟到渲染事务外：onAppear 同步写 @Published 会触发
            // "Modifying state during view update"（UAF 崩溃前兆）
            DispatchQueue.main.async {
                loadSkinImageIfNeeded()
            }
        }
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
