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
func generateFixedUUIDForSteve() -> String {
    return "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}

/// 全局启动器设置（单例）。每一项都是 `@Published` + `UserDefaults` 双写：
/// 内存里供 SwiftUI 订阅，磁盘上供下次启动恢复。
/// ⚠️ 与 ThemeManager 的收敛方向**相反** —— 这里每个 setter 都自己直写 UserDefaults，
/// 没有统一存储点；因此同一份数据只能有这一个写入口，外部不要再写同名键。
class LauncherSettings: ObservableObject {
    static let shared = LauncherSettings()
    
    /// 当前选中的游戏版本（空串 = 未选择）。界面多处据此显示「当前版本 / 未选择版本」。
    @Published var selectedMinecraftVersion: String {
        didSet { UserDefaults.standard.set(selectedMinecraftVersion, forKey: UDK.selectedMinecraftVersion) }
    }
    @Published var selectedGameRoot: String {
        didSet { UserDefaults.standard.set(selectedGameRoot, forKey: UDK.selectedGameRoot) }
    }
    /// 离线模式用户名。⚠️ 长度由 `OfflineUsernameValidator` 校验，但**本字段不拦截** ——
    /// 非法值会一路带到启动流程（见 init 里对历史脏数据的清理）。
    @Published var offlineUsername: String {
        didSet { UserDefaults.standard.set(offlineUsername, forKey: UDK.offlineUsername) }
    }
    @Published var cachedJavaPath: String? {
        didSet { UserDefaults.standard.set(cachedJavaPath, forKey: UDK.cachedJavaPath) }
    }
    /// 头像图路径。nil 表示不给（init 会回落到内置图 `stf.png`）。
    /// ⚠️ 存的是 `url.path` 字符串而非文件书签：文件被移动或改名后这里会变成悬空路径。
    @Published var avatarImageURL: URL? {
        didSet {
            if let url = avatarImageURL {
                UserDefaults.standard.set(url.path, forKey: UDK.avatarImagePath)
            } else {
                UserDefaults.standard.removeObject(forKey: UDK.avatarImagePath)
            }
        }
    }
    @Published var skinImageURL: URL? {
        didSet {
            if let url = skinImageURL {
                UserDefaults.standard.set(url.path, forKey: UDK.skinImagePath)
            } else {
                UserDefaults.standard.removeObject(forKey: UDK.skinImagePath)
            }
        }
    }
    /// 启动失败弹窗的开关与文案。两者分开：先置文案再开开关，避免弹窗闪一帧空文案。
    @Published var showLaunchAlert = false
    @Published var launchErrorMessage: String?
    @Published var showJavaPopup = false
    @Published var javaPopupMessage = "正在选择 Java..."
    @Published var appliedSkinHash: String? {
        didSet { UserDefaults.standard.set(appliedSkinHash, forKey: UDK.appliedSkinHash) }
    }
    /// 离线 UUID。用**立即执行的闭包**初始化：首次运行生成一次并落盘，之后每次都读回同一个值。
    /// ⚠️ 逻辑写在属性初始化器里，每个实例构造时都会跑 —— 靠 `private init()` 的单例约束，
    /// 实际只会执行一次。
    @Published var fixedOfflineUUID: String = {
        if let saved = UserDefaults.standard.string(forKey: UDK.fixedOfflineUUID) {
            return saved
        } else {
            let newUUID = generateFixedUUIDForSteve()
            UserDefaults.standard.set(newUUID, forKey: UDK.fixedOfflineUUID)
            return newUUID
        }
    }()
    /// 已发现的 Java 列表。⚠️ 它**不做持久化**（每次启动重新扫描）——
    /// 不要依赖它在冷启动瞬间就可用。
    @Published var availableJavaList: [JavaInfo] = []
    /// Java 扫描是否仍在进行。初值 true：启动瞬间即视为「扫描中」，避免界面先闪一下空态。
    @Published var isJavaScanning: Bool = true
    @Published var selectedJavaPath: String? {
        didSet { UserDefaults.standard.set(selectedJavaPath, forKey: UDK.selectedJavaPath) }
    }

    /// 从 UserDefaults 恢复全部字段。`private init` + `static let shared` 构成单例 ——
    /// 这也是上面 `fixedOfflineUUID` 的初始化闭包只会执行一次的原因。
    /// ⚠️ 恢复逻辑**必须在这里**（不能放进属性的默认值）：默认值表达式在 init 之前求值，
    /// 那时读不到已存在的 UserDefaults 值。
    private init() {
        self.selectedMinecraftVersion = UserDefaults.standard.string(forKey: UDK.selectedMinecraftVersion) ?? ""
        self.selectedGameRoot = UserDefaults.standard.string(forKey: UDK.selectedGameRoot) ?? ""
        self.offlineUsername = UserDefaults.standard.string(forKey: UDK.offlineUsername) ?? "Player"
        // 清理历史遗留脏数据：曾把输入框占位提示「SL启动器（最好使用英文及下划线）」存成真实用户名，
        // 该串 17 个字符 > MC 16 字符上限，1.20.5+ 进服时 hello 包编码直接抛
        // "String too big (was 17 characters, max 16)"（Failed to encode packet 'serverbound/minecraft:hello'）
        if self.offlineUsername == "SL启动器（最好使用英文及下划线）" {
            self.offlineUsername = "Player"
            UserDefaults.standard.set(self.offlineUsername, forKey: UDK.offlineUsername)
        }
        self.cachedJavaPath = UserDefaults.standard.string(forKey: UDK.cachedJavaPath)
        self.appliedSkinHash = UserDefaults.standard.string(forKey: UDK.appliedSkinHash)
        self.selectedJavaPath = UserDefaults.standard.string(forKey: UDK.selectedJavaPath)
        if let path = UserDefaults.standard.string(forKey: UDK.avatarImagePath) {
            self.avatarImageURL = URL(fileURLWithPath: path)
        } else {
            if let builtinURL = Bundle.main.url(forResource: "stf", withExtension: "png") {
                self.avatarImageURL = builtinURL
            } else {
                self.avatarImageURL = nil
            }
        }
        if let path = UserDefaults.standard.string(forKey: UDK.skinImagePath) {
            self.skinImageURL = URL(fileURLWithPath: path)
        } else {
            self.skinImageURL = nil
        }
    }
}