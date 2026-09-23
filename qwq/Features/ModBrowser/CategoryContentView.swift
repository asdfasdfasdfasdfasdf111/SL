import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// 右侧主内容区：按左侧分类（`category.name`）分派到不同页面。
///
/// 本视图自身只实现「启动」页那一整套（头像 / 用户名 / 启动按钮 / 日志面板 / 电源按钮），
/// 其余分类转交对应视图：个性化 → ColorPickerView、游戏 → GameCategoryView、
/// 下载 → DownloadCategoryView、联机与赞助 → 就地内联的内容。
///
/// **架构约定**：启动页的业务决策都已下沉到 ViewModel ——
/// LaunchAvatarSkinViewModel（头像皮肤管道）与 LaunchEntryViewModel（启动入口决策）。
/// 本视图只订阅它们的 `@Published` 展示状态、转发意图，自身不做校验也不起网络。
///
/// ⚠️ 分派依据是 `category.name` 的**中文字符串**（"个性化" / "启动" / "游戏" …）——
/// 分类名一旦改名或本地化，这里会静默落进最后的 else 分支（空网格），不会有编译错误。
struct CategoryContentView: View {
    /// 当前分类。本视图**只读它的 name** 做分派，不读其它字段。
    let category: Category
    /// 搜索框内容。⚠️ 在本视图内**未被使用**（联机/占位分支都是空网格）——
    /// 属预留参数，供后续在这些分类里接搜索用。
    let searchText: String
    @EnvironmentObject var settings: LauncherSettings
    /// 主题与启动会话均属全局单例（外部持有），由调用方注入；本视图只订阅，不持有
    @ObservedObject var theme: ThemeManager
    // 启动会话/日志面板/启动进度统一由全局单例持有（启动回调零 self 捕获，UAF 根治）
    @ObservedObject var sessionManager: LaunchSessionManager

    /// 头像皮肤数据管道与皮肤生命周期决策归 ViewModels/LaunchAvatarSkinViewModel.swift，
    /// 本视图只订阅其 @Published 展示状态并转发意图
    /// ⚠️ 用 `@StateObject` 而非 `@ObservedObject`：这两个 ViewModel 的生命周期要
    /// **绑定在本视图上**（自己创建、自己持有），而不是由调用方注入 ——
    /// 与同文件里 theme / sessionManager 的注入式写法相反。
    @StateObject private var skinViewModel = LaunchAvatarSkinViewModel()

    /// 启动按钮的入口决策（版本前置校验 + 重复启动拦截 + 转交 LaunchCoordinator）归
    /// ViewModels/LaunchEntryViewModel.swift，本视图只清焦点并转发点击
    @StateObject private var launchEntry = LaunchEntryViewModel()

    /// 高清皮肤补丁询问卡片的状态机与副作用编排归 Features/Skin/SkinPatchCoordinator.swift：
    /// 「选到原版不支持的皮肤尺寸」时由皮肤服务层发通知（服务层不认识本页的协调器），
    /// 本视图订阅后转交它查询/安装，再把它的 `state` 渲染成居中覆盖层。
    /// `@StateObject` 的理由同上：生命周期绑在本视图上，自己创建、自己持有。
    @StateObject private var skinPatch = SkinPatchCoordinator()

    /// 用户名输入框聚焦时的放大反馈（1.0 ↔ 1.1），配合 `.punchySpring`。
    @State private var usernameFieldScale: CGFloat = 1.0
    @FocusState private var isUsernameFocused: Bool
    @State private var skinButtonScale: CGFloat = 1.0

    /// 启动页外层：用 GeometryReader 按窗口尺寸算出卡片 / 按钮 / 头像的尺寸，再交给内容层。
    /// 所有尺寸都从 `cardWidth` 一个基准按比例推出来，改一处即可整体缩放。
    private var launchView: some View {
        GeometryReader { geometry in
            let cardWidth: CGFloat = 280
            let buttonWidth = cardWidth * 0.7
            let avatarSize = buttonWidth * 0.7
            let logCardHeight = geometry.size.height * 0.32
            // 固定卡片高度：防止 Spacer 吸收 HStack 额外高度导致拉伸。
            // ⚠️ 这个数字是各子元素高度的**手工累加**（上下留白 + 头像 + 间距 + 用户名框 +
            // 启动按钮 + 预留日志位 + 皮肤按钮 + 间距 + 版本文案）——
            // 增删卡片内元素时必须同步改它，否则卡片会被内容撑开或压扁。
            let cardHeight: CGFloat = 20 + avatarSize + 12 + 44 + 50 + 80 + 64 + 4 + 28
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

    /// 内容层：最底是透明点击层（点空白处让输入框失焦）+ 左卡片 + 右侧日志面板 + 右下电源按钮。
    private func launchContent(cardWidth: CGFloat, buttonWidth: CGFloat, avatarSize: CGFloat, logCardHeight: CGFloat, cardHeight: CGFloat) -> some View {
        ZStack {
            // 透明点击层（最底层）：点击任意空白处让用户名输入框失焦（macOS 点击非焦点区不自动失焦）
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isUsernameFocused = false }
            HStack(alignment: .top, spacing: 20) {
                leftCard(cardWidth: cardWidth, avatarSize: avatarSize, buttonWidth: buttonWidth, cardHeight: cardHeight)
                    .zIndex(1)
                logPanel(logCardHeight: logCardHeight)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            CloseSessionButton(
                isLaunching: sessionManager.isLaunching,
                hasRunningSessions: sessionManager.hasRunningSessions,
                onTap: { LaunchCoordinator.handlePowerTap(sessionManager: sessionManager) }
            )
            // 高清皮肤补丁询问卡片：**居中覆盖层**。
            // 放在 ZStack 最后 = 最上层；用条件插入而不是 offset/opacity 隐藏 ——
            // 与日志面板相反，这张卡片不该在隐藏时占位（它是一张要盖住内容的弹层，
            // 常驻空位纯属浪费，且会让 `.transition` 失去插入/移除的语义）。
            if skinPatch.state.isVisible {
                SkinPatchCardView(coordinator: skinPatch, theme: theme)
                    .zIndex(10)
                    // 插入/移除只做淡入淡出：缩放式入场由卡片自己负责
                    //（`SkinPatchCardView` 内的 showContent），两处都缩放会叠成双重动画。
                    .transition(.opacity)
                    .animation(.punchySpring, value: skinPatch.state.presentationKey)
            }
        }
    }
    /// 左侧主卡片：自上而下＝版本文案 → 头像 → 用户名输入 → 皮肤按钮 →（弹簧）→ 启动按钮。
    /// 中间的 `Spacer(minLength: 0)` 把启动按钮推到卡片底部。
    private func leftCard(cardWidth: CGFloat, avatarSize: CGFloat, buttonWidth: CGFloat, cardHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            if !settings.selectedMinecraftVersion.isEmpty {
                Text("当前版本: \(settings.selectedMinecraftVersion)")
                    .font(.caption).foregroundColor(.secondary).padding(.top, 4)
            } else {
                Text("未选择版本").font(.caption).foregroundColor(.secondary).padding(.top, 4)
            }
            avatarView(avatarSize: avatarSize)
            usernameField
            skinButton
            Spacer(minLength: 0)
            LaunchButton(
                buttonWidth: buttonWidth,
                isLaunching: sessionManager.isLaunching,
                launchPhase: sessionManager.launchPhase,
                lightProgress: sessionManager.lightProgress,
                darkProgress: sessionManager.darkProgress,
                onTap: {
                    isUsernameFocused = false
                    // 版本前置校验与重复启动拦截在 LaunchEntryViewModel；
                    // 启动编排本体已在 LaunchCoordinator（版本/用户名再校验 → 皮肤准备 →
                    // 构造 LaunchRequest 六段事件 → 会话登记）
                    launchEntry.requestLaunch()
                }
            )
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(RoundedRectangle(cornerRadius: 24).fill(.regularMaterial).shadow(radius: 12))
    }

    /// 头像：头 + 帽**两层**图片叠加渲染（帽子单独一层是为了正确处理半透明像素）。
    /// 两张图都由 ViewModel 在后台裁剪好，本视图只按比例摆放 —— 布局重算不触发 CoreImage。
    private func avatarView(avatarSize: CGFloat) -> some View {
        ZStack {
            // 双层渲染（还原：头 + 帽层叠加消除半透明）。
            // headImage/hatImage 由 ViewModel 后台裁剪，布局重算零 CoreImage
            if let headImage = skinViewModel.headImage {
                SkinLayerView(image: headImage, width: 8 * 5.4 / 58 * avatarSize, height: 8 * 5.4 / 58 * avatarSize)
                    .shadow(color: Color.black.opacity(0.2), radius: 1)
            }
            if let hatImage = skinViewModel.hatImage {
                SkinLayerView(image: hatImage, width: 7.99 * 6.1 / 58 * avatarSize, height: 7.99 * 6.1 / 58 * avatarSize)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipped()
        .padding(6)
        .onAppear {
            // 首帧裁剪兜底与皮肤 URL 准备（含渲染事务外延迟）均在 ViewModel 内完成
            skinViewModel.handleAvatarAppear()
        }
        .onChange(of: settings.skinImageURL) { _ in
            skinViewModel.reloadSkinDataFromFile()
        }
        .onChange(of: skinViewModel.avatarSkinData) { _ in
            skinViewModel.refreshSkinData()
        }
    }

    /// 离线用户名输入框：聚焦时背景浮现 + 描边高亮 + 放大反馈，并附一行非阻塞提示文案。
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
                        .opacity(isUsernameFocused ? 1 : 0)
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

    /// 离线用户名提示（PCL2 PageLoginLegacy 的 HintChinese 移植）。
    /// 返回 nil 表示「没有要说的」，视图侧整块不渲染 —— 而不是留一个空文案占位。
    private var offlineUsernameHint: String? {
        OfflineUsernameValidator.hint(for: settings.offlineUsername)
    }

    /// 「选择皮肤」按钮：点击先让输入框失焦、播一次弹跳，再交给 OfflineSkinService 开选图面板。
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

    /// 日志面板：仅在 `showLogView` 且确有会话时渲染内容，否则整块从下方 300pt 处淡出。
    /// ⚠️ 面板**不在布局里消失**（用 offset 而非条件插入），所以始终占着它的位置 ——
    /// 这是为了让「显示/隐藏」走同一套动画，代价是隐藏时也占位。
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

    /// 薄封装：把会话与高度转交给 `SessionLogCardView`，本视图不参与日志渲染。
    private func sessionLogCard(session: GameSession, logCardHeight: CGFloat) -> some View {
        SessionLogCardView(session: session, logCardHeight: logCardHeight)
    }

    // 分派入口：按分类名切页面。分支顺序即优先级，最后的 else 是「还没做的分类」占位。
    var body: some View {
        Group {
            if category.name == "个性化" {
                ColorPickerView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if category.name == "启动" {
                launchView
            } else if category.name == "游戏" {
                GameCategoryView(theme: theme).frame(maxWidth: .infinity, maxHeight: .infinity).id(category.id)
            } else if category.name == "下载" {
                DownloadCategoryView(theme: theme).frame(maxWidth: .infinity, maxHeight: .infinity).id(category.id)
            } else if category.name == "联机" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 20) { }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            // 赞助页：两张赞助方式卡 + 一张感谢卡，纯静态内容。
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
                // ⚠️ 这是**占位分支**：网格内容为空数组，实际上什么都不显示。
                // 它兜住的是所有未在上面列出的分类（也包含「联机」之后可能新增的分类）。
                // 原先以 ScrollViewReader 包裹但从未调用 scrollTo（proxy 无读取点）：
                // ScrollViewReader 的官方用途即经 proxy 做编程式滚动，无调用时仅为惰性包装，
                // 不参与布局、不影响滚动，故移除包装保留 ScrollView 本体。
                ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 20) { }.padding(32) }
                    .background(Color.clear)
            }
        }
        .id(category.id)
        .onChange(of: settings.selectedMinecraftVersion) { _ in
            // 非启动中才刷新头像；渲染事务外延迟与刷新编排均在 ViewModel 内
            skinViewModel.handleSelectedMinecraftVersionChange(isLaunching: sessionManager.isLaunching)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GameVersionSelected"))) { _ in
            skinViewModel.handleGameVersionSelected(isLaunching: sessionManager.isLaunching)
        }
        // 「皮肤选完了，尺寸已分类」→ 决定是弹补丁询问卡片、还是收起它。
        // 尺寸文案由服务层经 userInfo 带过来：`OfflineSkinService` 是无视图依赖的静态服务，
        // 不认识本页的协调器，故用通知解耦（与上面 GameVersionSelected 同一套路）。
        .onReceive(NotificationCenter.default.publisher(for: .skinSizeClassified)) { note in
            if let pixelSize = note.userInfo?["pixelSize"] as? String {
                skinPatch.beginCheck(pixelSize: pixelSize)
            } else {
                // 换成了原版尺寸（或尺寸不合法被拒）：之前那张卡片描述的是旧尺寸，直接收起
                skinPatch.dismiss()
            }
        }
        .onAppear {
            // 准备变体（头像 + 默认皮肤）的渲染事务外延迟在 ViewModel 内，与收口前一致
            skinViewModel.handleViewAppear()
        }
        .onDisappear {
            skinViewModel.handleViewDisappear()
        }
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

/// 抢焦点的占位视图。0×0、不可见，只为在窗口成为 key 时抢在 TextField 之前
/// 成为 firstResponder —— AppKit 的自动聚焦只发生在「窗口尚无 firstResponder」时，
/// 先占住它就不会落到用户名输入框上。
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

    /// 抢占焦点。`async` 到下一个 runloop tick 是必要的 —— 调用点
    ///（viewDidMoveToWindow / didBecomeKey）都还在 AppKit 的布局与焦点协商过程中，
    /// 立刻改 firstResponder 会被随后的自动聚焦覆盖掉。
    private func tryGrab(_ window: NSWindow) {
        DispatchQueue.main.async {
            window.initialFirstResponder = self
            _ = window.makeFirstResponder(self)
        }
    }
}
