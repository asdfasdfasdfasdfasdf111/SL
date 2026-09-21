import SwiftUI
import AppKit
import Combine

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
    static let shared = ThemeManager()

    /// 强调色：读写均转发到唯一存储点，本类型不参与持久化。
    var accentColor: Color {
        get { AppSettingsStore.shared.accentColor }
        set { AppSettingsStore.shared.accentColor = newValue }
    }

    /// 存储点变更通知的桥接订阅，使 `@ObservedObject var theme = ThemeManager.shared`
    /// 的既有读取方无需改动即可继续收到刷新。
    private var cancellables = Set<AnyCancellable>()

    private init() {
        AppSettingsStore.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

func generateFixedUUIDForSteve() -> String {
    return "f47ac10b-58cc-4372-a567-0e02b2c3d479"
}

class LauncherSettings: ObservableObject {
    static let shared = LauncherSettings()
    
    @Published var selectedMinecraftVersion: String {
        didSet { UserDefaults.standard.set(selectedMinecraftVersion, forKey: UDK.selectedMinecraftVersion) }
    }
    @Published var selectedGameRoot: String {
        didSet { UserDefaults.standard.set(selectedGameRoot, forKey: UDK.selectedGameRoot) }
    }
    @Published var offlineUsername: String {
        didSet { UserDefaults.standard.set(offlineUsername, forKey: UDK.offlineUsername) }
    }
    @Published var cachedJavaPath: String? {
        didSet { UserDefaults.standard.set(cachedJavaPath, forKey: UDK.cachedJavaPath) }
    }
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
    @Published var showLaunchAlert = false
    @Published var launchErrorMessage: String?
    @Published var showJavaPopup = false
    @Published var javaPopupMessage = "正在选择 Java..."
    @Published var appliedSkinHash: String? {
        didSet { UserDefaults.standard.set(appliedSkinHash, forKey: UDK.appliedSkinHash) }
    }
    @Published var fixedOfflineUUID: String = {
        if let saved = UserDefaults.standard.string(forKey: UDK.fixedOfflineUUID) {
            return saved
        } else {
            let newUUID = generateFixedUUIDForSteve()
            UserDefaults.standard.set(newUUID, forKey: UDK.fixedOfflineUUID)
            return newUUID
        }
    }()
    @Published var availableJavaList: [JavaInfo] = []
    @Published var isJavaScanning: Bool = true
    @Published var selectedJavaPath: String? {
        didSet { UserDefaults.standard.set(selectedJavaPath, forKey: UDK.selectedJavaPath) }
    }

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