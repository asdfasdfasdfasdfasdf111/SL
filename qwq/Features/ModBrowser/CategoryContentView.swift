import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// 右侧主内容区：按左侧分类（`category.kind`）分派到不同页面。
///
/// 本视图自身只实现「启动」页那一整套（头像 / 用户名 / 启动按钮 / 日志面板 / 电源按钮），
/// 其余分类转交对应视图：个性化 → ColorPickerView、游戏 → GameCategoryView、
/// 下载 → DownloadCategoryView、联机与赞助 → 就地内联的内容。
///
/// **架构约定**：启动页的业务决策都已下沉到 ViewModel ——
/// LaunchAvatarSkinViewModel（头像皮肤管道）与 LaunchEntryViewModel（启动入口决策）。
/// 本视图只订阅它们的 `@Published` 展示状态、转发意图，自身不做校验也不起网络。
///
/// ✅ 分派判据（2026-10-02 结构化）：`category.kind`（`CategoryKind` 枚举，见 Category.swift）。
/// 此前用 `category.name` 中文字符串（"个性化" / "启动" / "游戏" …）比较，
/// 分类名改名/本地化会静默落进空网格分支且无编译错误；现 switch 穷尽由编译器保证。
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

    /// 微软账号登录（设备码流程）的状态机与副作用编排归
    /// Features/Account/MicrosoftLoginViewModel.swift：账号行按钮驱动它发起登录，
    /// 设备码覆盖层卡片订阅它的 `phase` 渲染；登录成功经 `AccountManager.upsert`
    /// 持久化并设为已选账号。`@StateObject` 的理由同上：生命周期绑在本视图上。
    @StateObject private var microsoftLogin = MicrosoftLoginViewModel()

    /// 用户名输入框聚焦时的放大反馈（1.0 ↔ 1.1），配合 `.bouncySpring`。
    @State private var usernameFieldScale: CGFloat = 1.0
    @FocusState private var isUsernameFocused: Bool
    @State private var skinButtonScale: CGFloat = 1.0

    /// 点头像弹出的账号切换面板开关（PCL.Mac 交互：点头像 → 弹账号列表 → 点项切换）。
    /// 面板本身随头像的 ZStack 覆盖显示，不额外占卡片布局空间。
    @State private var showAccountPanel = false

    // MARK: - 启动卡片的自适应缩放基准

    /// 缩放基准窗口高度：与 Scene 的 `.defaultSize(height: 660)` 对齐 —— 默认窗口下卡片按 1:1 渲染。
    private static let designWindowHeight: CGFloat = 660
    /// 缩放基准窗口宽度：默认宽度下卡片按 1:1 渲染（对应启动页左卡 + 日志区的横向排布）。
    private static let designWidth: CGFloat = 900
    /// 缩放下限：窗口很矮（最小高度 500）时卡片缩到 0.68，再小字就看不清了。
    private static let minCardScale: CGFloat = 0.68
    /// 缩放上限：窗口拉很高时最多放到 1.15 倍，避免卡片跟着无限长大。
    private static let maxCardScale: CGFloat = 1.15

    /// 启动页外层：用 GeometryReader 按窗口尺寸算出卡片 / 按钮 / 头像的尺寸，再交给内容层。
    /// 所有尺寸都从 `cardWidth` 一个基准按比例推出来，改一处即可整体缩放。
    ///
    /// **整卡缩放（2026-10-05）**：此前 `cardWidth` 写死 280，窗口拉大拉小卡片都纹丝不动
    /// （用户报告：「左侧卡片不会自我缩放」）。现在按窗口高度相对设计基准等比缩放整张卡片。
    /// 为什么是给 `.scaleEffect` 一个比例、而不是直接把 `cardWidth` 改小：卡片内部的字号、
    /// 内边距、按钮高度都是固定值，只缩外框会让内容溢出并错位 —— 必须整块缩放才不变形。
    /// 比例同时夹在 `minCardScale…maxCardScale`：窗口很矮时不至于缩到看不清，
    /// 窗口很高时也不让卡片一直长下去（再大只是留白，撑满反而难看）。
    private var launchView: some View {
        GeometryReader { geometry in
            // ⚠️ 自适应必须同时看宽和高：此前只按高度缩放，窗口变宽时左栏纹丝不动
            // （用户反馈「根本没有自适应」）。改为按「高度比例 / 宽度比例」取较小值，
            // 保证整卡在任何宽高下都完整落在窗口内、且等比放大/缩小。
            let scaleByHeight = geometry.size.height / Self.designWindowHeight
            let scaleByWidth = geometry.size.width / Self.designWidth
            let cardScale = min(Self.maxCardScale, max(Self.minCardScale, min(scaleByHeight, scaleByWidth)))
            let cardWidth: CGFloat = 280
            let buttonWidth = cardWidth * 0.7
            let avatarSize = buttonWidth * 0.7
            let logCardHeight = geometry.size.height * 0.32
            // 固定卡片高度：防止 Spacer 吸收 HStack 额外高度导致拉伸。
            // ⚠️ 这个数字是各子元素高度的**手工累加**（上下留白 + 头像 + 间距 + 用户名框 +
            // 启动按钮 + 预留日志位 + 皮肤按钮 + 间距 + 版本文案）——
            // 增删卡片内元素时必须同步改它，否则卡片会被内容撑开或压扁。
            // 这里算的是**设计尺寸**（缩放前）；整卡缩放由 `cardScale` 在内容层统一施加。
            let cardHeight: CGFloat = 20 + avatarSize + 12 + 44 + 50 + 80 + 64 + 4 + 28 + 44
            launchContent(cardWidth: cardWidth, buttonWidth: buttonWidth, avatarSize: avatarSize, logCardHeight: logCardHeight, cardHeight: cardHeight, cardScale: cardScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // 关闭「窗口/页面首次出现时自动选中名称框」：macOS 上绑定了 .focused 的 TextField
        // 是窗口中第一个可聚焦控件时，AppKit 会在成为 key window 时自动将其置为 firstResponder。
        // 显式声明默认焦点为 false，让用户主动点击/按 Tab 才聚焦，而不是打开启动器就被选中。
        .defaultFocus($isUsernameFocused, false)
        // 启动页出现时恢复已选微软账号（AccountManager 有可用账号 → 账号行直接显示已登录）
        .onAppear { microsoftLogin.loadStoredAccount() }
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
    private func launchContent(cardWidth: CGFloat, buttonWidth: CGFloat, avatarSize: CGFloat, logCardHeight: CGFloat, cardHeight: CGFloat, cardScale: CGFloat) -> some View {
        ZStack {
            // 透明点击层（最底层）：点击任意空白处让用户名输入框失焦（macOS 点击非焦点区不自动失焦）
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isUsernameFocused = false }
            HStack(alignment: .top, spacing: 20) {
                leftCard(cardWidth: cardWidth, avatarSize: avatarSize, buttonWidth: buttonWidth, cardHeight: cardHeight)
                    // 整卡等比缩放。`scaleEffect` **不改变布局尺寸**（只改渲染），
                    // 所以必须再套一层按缩放后尺寸的 frame —— 否则卡片会「看起来变小、
                    // 但仍占着原来的位置」，右侧留下一段假空隙、日志面板也不跟着靠拢。
                    // 锚点取 .topLeading：卡片左上角不动，向右下方向缩放，与卡片在页面里的定位一致。
                    .scaleEffect(cardScale, anchor: .topLeading)
                    .frame(width: cardWidth * cardScale, height: cardHeight * cardScale, alignment: .topLeading)
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
            // 微软登录设备码卡片：**居中覆盖层**（与皮肤补丁卡同一层约定）。
            // 只有「等用户在浏览器输入设备码」期间显示；登录成功/取消/失败时
            // 条件不再成立自动移除（登录失败文案显示在账号面板的微软项下）。
            if microsoftLogin.isWaitingForCode {
                MicrosoftLoginCardView(viewModel: microsoftLogin)
                    .zIndex(10)
                    .transition(.opacity)
                    .animation(.punchySpring, value: microsoftLogin.phase)
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
            // 头像下方区域：**同一位置两种内容二选一**（PCL.Mac 的 normalPanel ↔ accountListPanel）。
            // 展开账号面板时用面板**替换**「用户名 + 皮肤按钮」，而不是叠在它们上面 ——
            // 之前的写法按估算高度把面板 padding 到下面，估算偏小就压在皮肤按钮上（用户实测
            // 「堆叠重合、没有间隙」）。换成同位替换后，面板与外层 VStack 的 16pt 间距就是
            // 真实间隙，且两块内容高度接近，卡片不会被撑高。
            Group {
                if showAccountPanel {
                    accountPanel
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85, anchor: .top).combined(with: .opacity),
                            removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity)
                        ))
                } else {
                    VStack(spacing: 16) {
                        usernameField
                        skinButton
                    }
                    .transition(.opacity)
                }
            }
            .animation(.bouncySpring, value: showAccountPanel)
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
        // PCL.Mac 交互：点头像弹出账号切换面板（微软/离线），看 `accountPanel`。
        // 点击时先让用户名输入框失焦（面板在头像正下方覆盖展开，不挡输入框）。
        .onTapGesture {
            isUsernameFocused = false
            withAnimation(.bouncySpring) { showAccountPanel.toggle() }
        }
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
                .animation(.bouncySpring, value: usernameFieldScale)
                .focused($isUsernameFocused)
                .onChange(of: isUsernameFocused) { focused in
                    if focused {
                        // ⚠️ onChange 处于视图更新事务中，withAnimation 内同步写 @State 同样会触发
                        // "Modifying state during view update"（UAF 前兆），延迟到渲染事务外
                        DispatchQueue.main.async {
                            withAnimation(.bouncySpring) { usernameFieldScale = 1.1 }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.bouncySpring) { usernameFieldScale = 1.0 }
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
            withAnimation(.bouncySpring) { skinButtonScale = 1.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.bouncySpring) { skinButtonScale = 1.0 }
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

    /// 账号切换面板（PCL.Mac 交互：点头像 → 弹账号列表 → 点项切换）。
    /// 两行账号项（微软 / 离线），当前选中的打勾；点击即切换 `settings.accountMode`。
    /// 微软项按登录状态机变脸：未登录=登录入口、等待授权=禁用并提示、失败=重试、已登录=档案名。
    /// 版式与左卡片同料（`.regularMaterial` + 细描边），宽度对齐卡片内元素。
    private var accountPanel: some View {
        VStack(spacing: 2) {
            accountRow(
                icon: "person.badge.key.fill",
                title: microsoftRowTitle,
                subtitle: microsoftRowSubtitle,
                selected: settings.accountMode == "microsoft",
                enabled: !isWaitingForMicrosoftCode,
                action: selectMicrosoftAccount
            )

            Divider().padding(.horizontal, 6)

            accountRow(
                icon: "person.crop.circle.fill",
                title: settings.offlineUsername.isEmpty ? "离线账号" : settings.offlineUsername,
                subtitle: "离线 · 本地皮肤",
                selected: settings.accountMode == "offline",
                enabled: true,
                action: {
                    settings.accountMode = "offline"
                    withAnimation(.bouncySpring) { showAccountPanel = false }
                }
            )
        }
        .padding(6)
        .frame(width: 216)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    /// 面板里的单行账号项：图标 + 标题/副标题 + 选中勾。
    /// `enabled: false` 时整行灰掉且不响应点击（用于「等浏览器授权」期间）。
    private func accountRow(
        icon: String,
        title: String,
        subtitle: String,
        selected: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: { if enabled { action() } }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(selected ? theme.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(enabled ? .primary : .secondary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// 是否正在等用户在浏览器完成授权（面板的微软项此时禁用）。
    private var isWaitingForMicrosoftCode: Bool {
        if case .waitingForCode = microsoftLogin.phase { return true }
        return false
    }

    private var microsoftRowTitle: String {
        switch microsoftLogin.phase {
        case .signedIn(let account): return account.name
        case .waitingForCode: return "等待浏览器授权…"
        case .failed: return "重试登录"
        case .idle: return "登录微软账号"
        }
    }

    private var microsoftRowSubtitle: String {
        switch microsoftLogin.phase {
        case .signedIn: return "正版账号"
        case .waitingForCode: return "已在浏览器打开验证页"
        case .failed(let message): return message
        case .idle: return "正版 · 在线皮肤"
        }
    }

    /// 点微软项：已登录 → 切到微软模式；正等授权 → 无操作（行已禁用）；
    /// 其余（未登录 / 上次失败）→ 收面板并重新发起设备码登录。
    private func selectMicrosoftAccount() {
        switch microsoftLogin.phase {
        case .signedIn:
            settings.accountMode = "microsoft"
            withAnimation(.bouncySpring) { showAccountPanel = false }
        case .waitingForCode:
            break
        case .failed, .idle:
            withAnimation(.bouncySpring) { showAccountPanel = false }
            microsoftLogin.startLogin()
        }
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

    // 分派入口：按 `category.kind`（语义身份）切页面，2026-10-02 起不再比较
    // `name` 中文字符串（改文案不再静默破坏路由）。switch 穷尽由编译器保证——
    // 新增 `CategoryKind` 成员而这里漏分支会直接编译报错。
    var body: some View {
        Group {
            switch category.kind {
            case .launcher:
                launchView
            case .game:
                GameCategoryView(theme: theme).frame(maxWidth: .infinity, maxHeight: .infinity).id(category.id)
            case .download:
                DownloadCategoryView(theme: theme).frame(maxWidth: .infinity, maxHeight: .infinity).id(category.id)
            case .online:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 20) { }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            // 赞助页：两张赞助方式卡 + 一张感谢卡，纯静态内容。
            case .sponsor:
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 20) {
                        SponsorCard(imageName: "sponsor1", title: "赞助方式一")
                        SponsorCard(imageName: "sponsor2", title: "赞助方式二")
                        ThanksCard()
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
