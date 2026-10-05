import SwiftUI
import AppKit
import Combine

/// UserDefaults 键名的集中表。
/// ⚠️ 这些字符串就是磁盘上的键：**改名等于丢数据**（旧键仍在盘上，但没人再读它）。
/// 属于对外契约的一部分，不要为了方便改写法。
enum UDK {
    static let accentColor = "accentColor"
    static let selectedMinecraftVersion = "selectedMinecraftVersion"
    static let selectedGameRoot = "selectedGameRoot"
    static let offlineUsername = "offlineUsername"
    static let cachedJavaPath = "cachedJavaPath"
    static let avatarImagePath = "avatarImagePath"
    static let skinImagePath = "skinImagePath"
    static let appliedSkinHash = "appliedSkinHash"
    static let fixedOfflineUUID = "fixedOfflineUUID"
    static let selectedJavaPath = "selectedJavaPath"
    static let cachedJavaPaths = "cachedJavaPaths"
    static let accountMode = "accountMode"
}

/// 主题读取兼容层。
///
/// 收敛说明：此前本类型自带 `@Published var accentColor`，其 didSet 与
/// `AppSettingsStore.accentColor` 的 didSet 会写入同一个 `UserDefaults[UDK.accentColor]`，
/// 同一份数据存在两个写入口，后写入者覆盖先写入者（两处各自持有一份内存值，
/// 任一处的改动都不会同步到另一处）。现收敛为：
/// - 唯一存储点是 `AppSettingsStore.accentColor`（设置模块已注册为能力 `settings.store`）；
/// - 本类型不再写 UserDefaults、不再持有颜色值，读写整体转发到存储点；
/// - 为保持既有读取方的实时刷新语义，init 中把存储点的 `objectWillChange` 桥接为本对象的
///   `objectWillChange`。视图失效时机与原来的 `@Published` 一致：都在值变化之前发出，且
///   SwiftUI 对 `ObservableObject` 的更新粒度是对象级。
///
/// 依据：`ObservableObject` 的默认实现合成 `objectWillChange`，它在任意 `@Published`
/// 属性变化**之前**发出值（注意是 will，不是 did）。
/// https://developer.apple.com/documentation/combine/observableobject
class ThemeManager: ObservableObject {
    /// ⚠️ 唯一实例，`private init` 强制 —— 视图全部通过 `ThemeManager.shared` 取用
    ///（很多视图把它当 `@ObservedObject` 的默认值）。不要再新增第二个实例。
    static let shared = ThemeManager()

    /// 强调色：读写均转发到唯一存储点，本类型不参与持久化。
    var accentColor: Color {
        get { AppSettingsStore.shared.accentColor }
        set { AppSettingsStore.shared.accentColor = newValue }
    }

    /// 存储点变更通知的桥接订阅，使 `@ObservedObject var theme = ThemeManager.shared`
    /// 的既有读取方无需改动即可继续收到刷新。
    /// 桥接订阅的持有者。⚠️ **必须持有**：`sink` 返回的 AnyCancellable 一旦被释放，
    /// 订阅立刻断开，之后主题色变化就再也不会触发本对象的 objectWillChange。
    private var cancellables = Set<AnyCancellable>()

    /// 唯一的初始化动作就是架起那条桥接订阅（见 cancellables 的注释）。
    private init() {
        AppSettingsStore.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

/// 「固定」的离线 UUID —— 名字有误导：它并**不**按用户名生成，永远返回同一个硬编码值。
/// 作用只是让离线模式下跨启动保持同一身份（皮肤能生效）。
/// ⚠️ 因为不随用户名变化，用不同用户名的多个离线实例在服务端看起来是同一个账号。
func fixedOfflineUUIDValue() -> String {
    return "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}

/// 全局启动器设置兼容层。
///
/// 持久化字段统一转发到 `AppSettingsStore`，本类型只保留短生命周期的 UI 状态
/// 和暂时尚未迁移的 Java 扫描状态。
///
/// 收敛说明：此前本类型对同一批键**各持一份内存值并各自写 `UserDefaults`**，
/// 与 `AppSettingsStore` 构成两个写入口 —— 后写入者覆盖先写入者，两处内存值互不同步
/// （同一机理见 `ThemeManager` 的收敛说明）。现持久化字段不再自行存储，
/// 读写整体转发，权威来源只剩 `AppSettingsStore` 一处。
class LauncherSettings: ObservableObject {
    static let shared = LauncherSettings()

    private let settings = AppSettingsStore.shared
    /// 存储点变更通知的桥接订阅。
    /// ⚠️ **必须保留**：上面这些转发字段在本类型里**不再是 `@Published`**，
    /// 它们的变化只能经 `AppSettingsStore.objectWillChange` 冒泡到这里。
    /// 这条订阅一旦断掉（或本属性被释放），写设置将不再触发本对象的 `objectWillChange` ——
    /// 订阅 `LauncherSettings` 的视图（`ContentView` 等）会**静默停止重绘**，编译期毫无提示。
    /// 契约用例见 `qwqTests/LaunchPanelStateTests.swift` 的「持久化字段写入同样要透传」。
    private var settingsCancellable: AnyCancellable?

    var selectedMinecraftVersion: String {
        get { settings.selectedMinecraftVersion }
        set { settings.selectedMinecraftVersion = newValue }
    }

    var selectedGameRoot: String {
        get { settings.selectedGameRoot }
        set { settings.selectedGameRoot = newValue }
    }

    var offlineUsername: String {
        get { settings.offlineUsername }
        set { settings.offlineUsername = newValue }
    }

    /// 当前账号模式（"offline" / "microsoft"）：转发到存储点，登录绑定经此读取。
    /// 启动页点头像弹出的账号面板切换时写入。
    var accountMode: String {
        get { settings.accountMode }
        set { settings.accountMode = newValue }
    }

    var cachedJavaPath: String? {
        get { settings.cachedJavaPath }
        set { settings.cachedJavaPath = newValue }
    }

    var avatarImageURL: URL? {
        get { settings.avatarImageURL }
        set { settings.avatarImageURL = newValue }
    }

    var skinImageURL: URL? {
        get { settings.skinImageURL }
        set { settings.skinImageURL = newValue }
    }

    /// 启动失败弹窗的开关与文案。两者分开：先置文案再开开关，避免弹窗闪一帧空文案。
    @Published var showLaunchAlert = false
    @Published var launchErrorMessage: String?
    @Published var showJavaPopup = false
    @Published var javaPopupMessage = "正在选择 Java..."

    var appliedSkinHash: String? {
        get { settings.appliedSkinHash }
        set { settings.appliedSkinHash = newValue }
    }

    var fixedOfflineUUID: String {
        get { settings.fixedOfflineUUID }
        set { settings.fixedOfflineUUID = newValue }
    }

    /// 已发现的 Java 列表。⚠️ 它**不做持久化**（每次启动重新扫描）——
    /// 不要依赖它在冷启动瞬间就可用。
    @Published var availableJavaList: [JavaInfo] = []
    /// Java 扫描是否仍在进行。初值 true：启动瞬间即视为「扫描中」，避免界面先闪一下空态。
    @Published var isJavaScanning: Bool = true

    var selectedJavaPath: String? {
        get { settings.selectedJavaPath }
        set { settings.selectedJavaPath = newValue }
    }

    private init() {
        settingsCancellable = settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
