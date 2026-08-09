import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// 单次游戏启动会话：绑定 launcher、日志、序号
final class GameSession: ObservableObject, Identifiable {
    let id: UUID = UUID()
    let index: Int
    let launcher: MinecraftLauncher
    @Published var logs: [String] = []
    @Published var isProcessRunning: Bool = true
    @Published var isLaunching: Bool = true
    init(index: Int, launcher: MinecraftLauncher) {
        self.index = index
        self.launcher = launcher
    }
}

enum LaunchPhase: Equatable {
    case idle
    case downloading
    case installing
    case launching
}

struct CategoryContentView: View {
    let category: Category
    let searchText: String
    @EnvironmentObject var settings: LauncherSettings
    @ObservedObject var theme = ThemeManager.shared
    
    @State private var buttonScale: CGFloat = 1.0
    @State private var isLaunching = false
    @State private var launchProgress: Double = 0.0
    @State private var usernameFieldScale: CGFloat = 1.0
    @FocusState private var isUsernameFocused: Bool
    @State private var skinButtonScale: CGFloat = 1.0
    @State private var showLogView = false
    @State private var launchPhase: LaunchPhase = .idle
    @State private var lightProgress: Double = 0.0
    @State private var darkProgress: Double = 0.2
    @State private var darkBarTarget: Double = 0.2
    @State private var closeButtonScale: CGFloat = 0.01
    @State private var closeButtonGlow: CGFloat = 0
    @State private var darkBarActive = false
    @State private var darkBarTimer: Timer?
    // 多会话支持：每次启动创建一个 GameSession
    @State private var gameSessions: [GameSession] = []

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
                closeSession(session)
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
            closeButtonOverlay
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
            launchButton(buttonWidth: buttonWidth)
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
            loadSkinImageIfNeeded()
        }
    }

    /// 确保 skinImageURL 存在，不存在则从缓存/JAR/内置皮肤加载
    private func loadSkinImageIfNeeded() {
        guard !isLaunching else { return }
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
           let skinURL = extractSkinFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
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
                        withAnimation(.punchySpring) { usernameFieldScale = 1.1 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.punchySpring) { usernameFieldScale = 1.0 }
                        }
                    }
                }
            // PCL2 风格提示（非阻塞）：超过 16 字符 / 包含非英文数字下划线时显示
            if let hint = offlineUsernameHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
    }

    /// 离线用户名提示（PCL2 PageLoginLegacy 的 HintChinese 移植）
    private var offlineUsernameHint: String? {
        let name = settings.offlineUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.utf16.count > 16 {
            return "用户名不能超过 16 个字符"
        }
        if !name.isEmpty, name.range(of: "^[0-9A-Za-z_]*$", options: .regularExpression) == nil {
            // PCL2 HintChinese 语义：1.18+ 服务端拒绝非 [0-9A-Za-z_] 用户名（Invalid characters in username）
            return "仅限英文、数字、下划线，否则 1.18+ 无法进入"
        }
        return nil
    }

    private var skinButton: some View {
        Button(action: {
            isUsernameFocused = false
            withAnimation(.punchySpring) { skinButtonScale = 1.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.punchySpring) { skinButtonScale = 1.0 }
            }
            selectSkinImage()
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

    private func launchButton(buttonWidth: CGFloat) -> some View {
        Button(action: {
            isUsernameFocused = false
            withAnimation(.punchySpring) { buttonScale = 1.15 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.punchySpring) { buttonScale = 1.0 }
            }
            guard !settings.selectedMinecraftVersion.isEmpty else {
                settings.launchErrorMessage = "请先在「游戏」分类中选择一个版本"
                settings.showLaunchAlert = true
                return
            }
            guard !isLaunching else { return }
            startLaunch()
        }) {
            ZStack(alignment: .leading) {
                if launchPhase == .downloading || launchPhase == .installing {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.6))
                        .frame(width: buttonWidth * CGFloat(lightProgress), height: 50)
                        .animation(.exaggeratedSpring, value: lightProgress)
                }
                if launchPhase == .launching {
                    Rectangle()
                        .fill(theme.accentColor.opacity(0.85))
                        .frame(width: buttonWidth * CGFloat(darkProgress), height: 50)
                        .animation(.exaggeratedSpring, value: darkProgress)
                }
                RoundedRectangle(cornerRadius: 25)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 25).fill(.ultraThinMaterial))
                ZStack {
                    if launchPhase == .idle {
                        Text("启动游戏")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                    if launchPhase == .downloading {
                        Text("Java 下载中")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if launchPhase == .installing {
                        Text("Java 安装中")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                    if launchPhase == .launching {
                        Text("启动中")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: buttonWidth, height: 50, alignment: .center)
                    }
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: launchPhase)
            }
            .frame(width: buttonWidth, height: 50)
            .mask(RoundedRectangle(cornerRadius: 25).frame(width: buttonWidth, height: 50))
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(buttonScale)
        .animation(.punchySpring, value: buttonScale)
        .disabled(isLaunching)
        .padding(.bottom, 30)
    }

    private func logPanel(logCardHeight: CGFloat) -> some View {
        Group {
            if showLogView && !gameSessions.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(gameSessions) { session in
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
        .offset(y: showLogView ? 0 : 300)
        .opacity(showLogView ? 1 : 0)
        .animation(.exaggeratedSpring, value: showLogView)
        .animation(.exaggeratedSpring, value: gameSessions.count)
    }

    private func sessionLogCard(session: GameSession, logCardHeight: CGFloat) -> some View {
        SessionLogCardView(session: session, logCardHeight: logCardHeight)
    }

    private func closeSession(_ session: GameSession) {
        if session.isProcessRunning {
            session.launcher.terminate()
            session.isProcessRunning = false
            session.isLaunching = false
        }
        let willBeEmpty = gameSessions.count == 1
        withAnimation(.exaggeratedSpring) {
            gameSessions.removeAll { $0.id == session.id }
            if willBeEmpty {
                showLogView = false
            }
        }
        // 关闭最后一个会话时复位启动状态，确保关闭按钮消失
        if willBeEmpty {
            resetLaunchState()
            withAnimation(.easeOut(duration: 0.3)) {
                launchPhase = .idle
            }
        }
    }

    private var closeButtonOverlay: some View {
        Group {
            if isLaunching || gameSessions.contains(where: { $0.isProcessRunning }) {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: {
                            let runningSessions = gameSessions.filter { $0.isProcessRunning }
                            if !runningSessions.isEmpty {
                                let alert = NSAlert()
                                alert.messageText = runningSessions.count == 1 ? "确认关闭游戏？" : "确认关闭 \(runningSessions.count) 个正在运行的游戏？"
                                alert.informativeText = "游戏进程将被终止，未保存的进度可能会丢失。"
                                alert.alertStyle = .warning
                                alert.addButton(withTitle: "关闭")
                                alert.addButton(withTitle: "取消")
                                let response = alert.runModal()
                                if response == .alertFirstButtonReturn {
                                    for s in runningSessions {
                                        s.launcher.terminate()
                                        s.isProcessRunning = false
                                        s.isLaunching = false
                                    }
                                    withAnimation(.exaggeratedSpring) {
                                        gameSessions.removeAll()
                                        showLogView = false
                                    }
                                    resetLaunchState()
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        launchPhase = .idle
                                    }
                                }
                            } else {
                                isLaunching = false
                                launchProgress = 0.0
                                lightProgress = 0.0
                                darkProgress = 0.2
                                darkBarTarget = 0.2
                                darkBarActive = false
                                stopDarkBarAnimation()
                                withAnimation(.easeOut(duration: 0.3)) {
                                    launchPhase = .idle
                                    showLogView = false
                                }
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .stroke(theme.accentColor.opacity(closeButtonGlow), lineWidth: 2.5)
                                    .frame(width: 44, height: 44)
                                    .scaleEffect(closeButtonScale * 1.8)
                                Image(systemName: "power")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(.regularMaterial).shadow(radius: 4))
                                    .scaleEffect(closeButtonScale)
                            }
                            .onAppear {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
                                    closeButtonScale = 1.3
                                    closeButtonGlow = 0.8
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                        closeButtonScale = 0.85
                                    }
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        closeButtonScale = 1.0
                                        closeButtonGlow = 0
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(20)
                        .help(gameSessions.contains(where: { $0.isProcessRunning }) ? "关闭所有游戏" : "取消启动")
                    }
                }
            }
        }
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
            if !isLaunching {
                loadAvatarFromGameOrBundle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GameVersionSelected"))) { _ in
            if !isLaunching {
                loadDefaultSkinIfNeeded()
            }
        }
        .onAppear {
            loadAvatarFromGameOrBundle()
            loadDefaultSkinIfNeeded()
        }
        .onDisappear {
            stopDarkBarAnimation()
        }
    }
    
    private func selectSkinImage() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择皮肤图片"
        openPanel.message = "请选择一张 Minecraft 皮肤图片（64×64 或 64×32）"
        openPanel.allowedContentTypes = [.png]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                do {
                    let skinManager = MinecraftSkinManager.shared
                    try skinManager.validateSkin(at: url)

                    // 保存皮肤原图到本地
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
                    try FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
                    let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")
                    let skinData = try Data(contentsOf: url)
                    try skinData.write(to: skinDestURL)

                    let avatarImage = try skinManager.cropAvatar(from: url)
                    let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                    try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                    let avatarDestURL = avatarDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                    if let pngData = avatarImage.pngData() {
                        try pngData.write(to: avatarDestURL)
                        DispatchQueue.main.async {
                            self.settings.avatarImageURL = avatarDestURL
                            self.settings.skinImageURL = skinDestURL
                        }
                        // 保存皮肤到持久化目录（供 authlib-injector 使用）
                        let offlineUUID = self.settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
                        _ = try skinManager.saveSkin(url, forUUID: offlineUUID)

                        let version = self.settings.selectedMinecraftVersion
                        let gameDirPath = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
                        if !version.isEmpty && !gameDirPath.isEmpty {
                            let gameDir = URL(fileURLWithPath: gameDirPath)
                            // 离线皮肤统一走资源包方案（PCL2 移植）：生成 resourcepacks/SL 皮肤.zip
                            // 并注入 options.txt。1.19.3+ 的默认皮肤在 entity/player/{slim,wide}/ 下，
                            // 旧版 JAR 顶层替换对 1.13+ 无效（26.2 实测不加载）。
                            do {
                                try skinManager.applySkinAsResourcePack(skinURL: url, toVersion: version, gameDir: gameDir, settings: self.settings)
                            } catch {
                                print("⚠️ 皮肤资源包生成失败: \(error.localizedDescription)")
                            }
                        }
                    } else {
                        throw LauncherError.skinValidationFailed("保存头像失败")
                    }
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "不合法的图片"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "确定")
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    func loadDefaultSkinIfNeeded() {
        guard !isLaunching else { return }
        guard settings.avatarImageURL == nil else { return }

        // 优先从皮肤文件系统缓存加载
        let offlineUUID = settings.fixedOfflineUUID.components(separatedBy: "-").joined().lowercased()
        if let cachedSkinData = MinecraftSkinManager.shared.getSkinData(forUUID: offlineUUID) {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
            try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
            let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")
            try? cachedSkinData.write(to: skinDestURL)

            let tempDir = FileManager.default.temporaryDirectory
            let tempSkinURL = tempDir.appendingPathComponent("\(offlineUUID).png")
            try? cachedSkinData.write(to: tempSkinURL)
            if let avatar = try? MinecraftSkinManager.shared.cropAvatar(from: tempSkinURL) {
                let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                try? FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                let destURL = avatarDir.appendingPathComponent("cached_\(offlineUUID).png")
                if let pngData = avatar.pngData() {
                    try? pngData.write(to: destURL)
                    settings.avatarImageURL = destURL
                    settings.skinImageURL = skinDestURL
                }
            }
            try? FileManager.default.removeItem(at: tempSkinURL)
            return
        }

        // 回退：从 JAR 提取或使用内置皮肤
        let gameDirPath2 = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
        if !settings.selectedMinecraftVersion.isEmpty && !gameDirPath2.isEmpty,
           let gameDirURL = Optional(URL(fileURLWithPath: gameDirPath2)),
           let skinURL = extractSkinFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
            try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
            let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")
            if let skinData = try? Data(contentsOf: skinURL) {
                try? skinData.write(to: skinDestURL)
                settings.skinImageURL = skinDestURL
            }
            settings.avatarImageURL = skinURL
        } else if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
            settings.skinImageURL = builtinURL
            settings.avatarImageURL = builtinURL
        }
    }
    
    func extractSkinFromGameJar(version: String, gameDir: URL) -> URL? {
        let jarURL = gameDir.appendingPathComponent("versions/\(version)/\(version).jar")
        guard FileManager.default.fileExists(atPath: jarURL.path) else { return nil }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        if let skinURL = extractSkinFile(from: jarURL, tempDir: tempDir, skinName: "steve") {
            return skinURL
        }
        if let skinURL = extractSkinFile(from: jarURL, tempDir: tempDir, skinName: "alex") {
            return skinURL
        }
        return nil
    }
    
    private func extractSkinFile(from jarURL: URL, tempDir: URL, skinName: String) -> URL? {
        let result = AppContext.shared.processPool.execute(
            "/usr/bin/unzip",
            args: ["-j", jarURL.path, "assets/minecraft/textures/entity/\(skinName).png", "-d", tempDir.path],
            timeout: 10
        )
        guard result != nil else { return nil }
        let skinURL = tempDir.appendingPathComponent("\(skinName).png")
        if FileManager.default.fileExists(atPath: skinURL.path) {
            return skinURL
        }
        return nil
    }
    
    func loadAvatarFromGameOrBundle() {
        guard !isLaunching else { return }
        if let existingURL = settings.avatarImageURL,
           FileManager.default.fileExists(atPath: existingURL.path),
           !existingURL.lastPathComponent.hasPrefix("stf") {
            return
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let skinDir = appSupport.appendingPathComponent("SL启动器/Skins")
        try? FileManager.default.createDirectory(at: skinDir, withIntermediateDirectories: true)
        let skinDestURL = skinDir.appendingPathComponent("selected_skin.png")

        guard !settings.selectedMinecraftVersion.isEmpty else {
            if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                do {
                    let croppedAvatar = try MinecraftSkinManager.shared.cropAvatar(from: builtinURL)
                    let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                    try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                    let destURL = avatarDir.appendingPathComponent("default_avatar.png")
                    if let pngData = croppedAvatar.pngData() {
                        try pngData.write(to: destURL)
                        settings.avatarImageURL = destURL
                    } else {
                        settings.avatarImageURL = builtinURL
                    }
                    settings.skinImageURL = builtinURL
                } catch {
                    settings.avatarImageURL = builtinURL
                    settings.skinImageURL = builtinURL
                }
            }
            return
        }
        do {
            let gameDirURL = URL(fileURLWithPath: settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot)
            if let skinURL = extractSkinFromGameJar(version: settings.selectedMinecraftVersion, gameDir: gameDirURL) {
                let avatarImage = try MinecraftSkinManager.shared.cropAvatar(from: skinURL)
                let avatarDir = appSupport.appendingPathComponent("SL启动器/Avatars")
                try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                let destURL = avatarDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                if let pngData = avatarImage.pngData() {
                    try pngData.write(to: destURL)
                    settings.avatarImageURL = destURL
                } else {
                    if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                        settings.avatarImageURL = builtinURL
                    }
                }
                // 保存皮肤原图
                if let skinData = try? Data(contentsOf: skinURL) {
                    try? skinData.write(to: skinDestURL)
                    settings.skinImageURL = skinDestURL
                } else {
                    settings.skinImageURL = skinURL
                }
            } else {
                if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                    settings.avatarImageURL = builtinURL
                    settings.skinImageURL = builtinURL
                }
            }
        } catch {
            if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                settings.avatarImageURL = builtinURL
                settings.skinImageURL = builtinURL
            }
        }
    }
    
    private func initLaunchState() {
        isLaunching = true
        launchPhase = .idle
        lightProgress = 0.0
        darkProgress = 0.2
        darkBarTarget = 0.2
        darkBarActive = false
        launchProgress = 0.0
    }

    private func resetLaunchState() {
        isLaunching = false
        launchProgress = 0.0
        lightProgress = 0.0
        darkProgress = 0.2
        darkBarTarget = 0.2
        darkBarActive = false
        stopDarkBarAnimation()
    }

    private func startLaunch() {
        initLaunchState()
        let gameDir = settings.selectedGameRoot.isEmpty ? nil : settings.selectedGameRoot
        let version = settings.selectedMinecraftVersion
        // PCL2 风格离线用户名校验（非空 / 无英文引号 / ≤16 字符）：
        // 否则 1.20.5+ 会因 hello 包 writeUtf(name,16) 报 "String too big" 而进服失败
        let username = settings.offlineUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameError = validateOfflineUsername(username)
        guard nameError.isEmpty else {
            resetLaunchState()
            settings.launchErrorMessage = nameError
            settings.showLaunchAlert = true
            return
        }
        let finalUsername = username.isEmpty ? "Player" : username
        // PCL2 HintChinese 语义：Minecraft 1.18+ 服务端只接受 [0-9A-Za-z_] 用户名，
        // 中文等字符会在服务端抛 "Invalid characters in username" 并断开连接（表现为「连接中断」）。
        // 启动前给明确警告，避免用户误以为启动器异常；保留「仍要启动」以兼容 1.18 之前的版本。
        if finalUsername.range(of: "^[0-9A-Za-z_]*$", options: .regularExpression) == nil {
            resetLaunchState()
            let alert = NSAlert()
            alert.messageText = "用户名可能无法进入游戏"
            alert.informativeText = "「\(finalUsername)」含非法字符，1.18+ 服务端会拒绝（连接中断），仅 1.18 前可用。仍要启动？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "仍要启动")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertSecondButtonReturn {
                return
            }
        }
        var boundLauncher: MinecraftLauncher?

        let startGame = {
            pclLaunch(
            version: version,
            username: finalUsername,
            gameDir: gameDir,
            progressHandler: { progress in
                DispatchQueue.main.async {
                    if progress > self.launchProgress {
                        self.launchProgress = progress
                    }
                    if self.launchPhase == .downloading || self.launchPhase == .installing {
                        self.lightProgress = progress
                    }
                }
            },
            phaseHandler: { phase in
                DispatchQueue.main.async {
                    switch phase {
                    case "downloading":
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                            self.launchPhase = .downloading
                        }
                    case "installing":
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                            self.launchPhase = .installing
                        }
                    case "launching":
                        self.lightProgress = 1.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                                self.launchPhase = .launching
                            }
                            self.darkProgress = 0.2
                            self.darkBarTarget = 1.0
                            self.darkBarActive = true
                            self.startDarkBarAnimation()
                        }
                    default:
                        break
                    }
                }
            },
            logHandler: { logLine in
                DispatchQueue.main.async {
                    guard let l = boundLauncher else { return }
                    if let session = self.gameSessions.first(where: { $0.launcher === l }) {
                        session.logs.append(logLine)
                    } else {
                        // session 尚未建立：暂存到 launcher，建立后 flush
                        l.pendingLogs.append(logLine)
                    }
                }
            },
            launchSuccess: {
                DispatchQueue.main.async {
                    if let l = boundLauncher,
                       let session = self.gameSessions.first(where: { $0.launcher === l }) {
                        session.isLaunching = false
                    }
                    withAnimation(.exaggeratedSpring) {
                        self.darkBarTarget = 1.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeOut(duration: 0.4)) {
                            self.launchPhase = .idle
                        }
                        self.resetLaunchState()
                    }
                }
            },
            onLauncherReady: { launcher in
                boundLauncher = launcher
                DispatchQueue.main.async {
                    let wasEmpty = self.gameSessions.isEmpty
                    let usedIndices = Set(self.gameSessions.map { $0.index })
                    var newIndex = 1
                    while usedIndices.contains(newIndex) { newIndex += 1 }
                    let session = GameSession(index: newIndex, launcher: launcher)
                    // flush 暂存日志
                    if !launcher.pendingLogs.isEmpty {
                        session.logs.append(contentsOf: launcher.pendingLogs)
                        launcher.pendingLogs.removeAll()
                    }
                    // 先触发面板弹出动画（offset/opacity 过渡）
                    if wasEmpty {
                        withAnimation(.exaggeratedSpring) {
                            self.showLogView = true
                        }
                    }
                    // 再插入 session（带 transition）
                    withAnimation(.exaggeratedSpring) {
                        self.gameSessions.append(session)
                    }
                }
            },
            completion: { launcher, result in
                DispatchQueue.main.async {
                    if let launcher = launcher,
                       let session = self.gameSessions.first(where: { $0.launcher === launcher }) {
                        session.isProcessRunning = false
                        session.isLaunching = false
                    }
                    switch result {
                    case .success(let exitCode):
                        let userTerminated = launcher?.isUserTerminated ?? false
                        if exitCode != 0 && !userTerminated {
                            self.settings.launchErrorMessage = "Minecraft 异常退出 (退出码: \(exitCode))，请查看日志"
                            self.settings.showLaunchAlert = true
                        }
                        self.resetLaunchState()
                        withAnimation(.easeOut(duration: 0.3)) {
                            self.launchPhase = .idle
                        }
                    case .failure(let error):
                        self.resetLaunchState()
                        withAnimation(.easeOut(duration: 0.3)) {
                            self.launchPhase = .idle
                            if self.gameSessions.isEmpty { self.showLogView = false }
                        }
                        self.settings.launchErrorMessage = error.localizedDescription
                        self.settings.showLaunchAlert = true
                    }
                }
            }
        )
        }
        
        // 离线皮肤：确保资源包已生成并注入（PCL2 移植，幂等 hash 判断）。
        // 后台执行避免阻塞主线程。JAR 替换对 1.13+ 无效（默认皮肤在 entity/player/{slim,wide}/ 下），
        // 资源包方案全版本生效（1.19.3+ 与旧版路径都写入）。
        let gameDirPath = settings.selectedGameRoot.isEmpty ? (AppSettings.shared.currentMinecraftDirectory?.rootURL.path ?? "") : settings.selectedGameRoot
        if let skin = settings.skinImageURL, !gameDirPath.isEmpty, !version.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try MinecraftSkinManager.shared.applySkinAsResourcePack(
                        skinURL: skin,
                        toVersion: version,
                        gameDir: URL(fileURLWithPath: gameDirPath),
                        settings: self.settings
                    )
                } catch {
                    print("皮肤资源包应用失败: \(error.localizedDescription)")
                }
                DispatchQueue.main.async {
                    startGame()
                }
            }
        } else {
            startGame()
        }
    }
    
    private func startDarkBarAnimation() {
        darkBarTimer?.invalidate()
        darkBarTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            DispatchQueue.main.async {
                guard self.darkBarActive else { return }
                if self.darkProgress < self.darkBarTarget {
                    let step = max(0.003, (self.darkBarTarget - self.darkProgress) * 0.08)
                    self.darkProgress = min(self.darkBarTarget, self.darkProgress + step)
                }
            }
        }
    }

    private func stopDarkBarAnimation() {
        darkBarTimer?.invalidate()
        darkBarTimer = nil
    }
}

/// 独立的日志卡片视图：用 @ObservedObject 监听 session.logs 变化，确保日志实时刷新
private struct SessionLogCardView: View {
    @ObservedObject var session: GameSession
    let logCardHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("启动日志\(session.index)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    NotificationCenter.default.post(name: .closeGameSession, object: session)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(session.isProcessRunning ? "关闭此游戏进程" : "移除此日志")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(session.logs.indices, id: \.self) { idx in
                            Text(session.logs[idx])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(idx)
                        }
                    }
                    .padding(4)
                }
                .frame(height: logCardHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
                .onChange(of: session.logs.count) { _ in
                    withAnimation(.exaggeratedSpring) {
                        proxy.scrollTo(session.logs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial).shadow(radius: 4))
    }
}

extension Notification.Name {
    static let closeGameSession = Notification.Name("closeGameSession")
}