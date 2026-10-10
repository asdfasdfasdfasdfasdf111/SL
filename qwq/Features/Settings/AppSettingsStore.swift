import AppKit
import Combine
import SwiftUI

/// 应用设置的唯一存储点。
///
/// 背景：此前设置项散落在 `ThemeManager`、`LauncherSettings` 以及各处的
/// `UserDefaults.standard.set(...)` 调用里，同一个数据有多个写入口，
/// 导致状态流向无法追踪，也难以测试。
///
/// 本类型的职责边界：
/// - 只负责“设置数据”的持有与持久化
/// - 不持有 Java、下载、启动等业务状态（那些属于各自的模块）
/// - `ThemeManager` / `LauncherSettings` 暂时保留为兼容层，逐步收窄后移除
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    /// 设置数据的落盘偏好域。生产恒为 `.standard`；测试可整体重定向到独立域
    /// （见文件末尾的 `redirectPersistenceForTesting(to:)`），使用例读写设置时
    /// **碰不到用户真实偏好**。新增字段的持久化一律经本属性，不要再直接写 `UserDefaults.standard`。
    private var store: UserDefaults = .standard

    /// 强调色的**唯一存储点与唯一写入口**。
    /// `ThemeManager.accentColor` 已收敛为对本属性的转发，不再自行写 `UserDefaults[UDK.accentColor]`；
    /// 读取方（`@ObservedObject var theme = ThemeManager.shared` 的视图、`ThemeRepository`）
    /// 保持不变，刷新由 `ThemeManager` 桥接本对象的 `objectWillChange` 保证。
    @Published var accentColor: Color {
        didSet { saveColor(accentColor, forKey: UDK.accentColor) }
    }

    @Published var selectedMinecraftVersion: String {
        didSet { store.set(selectedMinecraftVersion, forKey: UDK.selectedMinecraftVersion) }
    }

    @Published var selectedGameRoot: String {
        didSet { store.set(selectedGameRoot, forKey: UDK.selectedGameRoot) }
    }

    @Published var offlineUsername: String {
        didSet { store.set(offlineUsername, forKey: UDK.offlineUsername) }
    }

    /// 当前账号模式：`"offline"`（离线账号，默认）或 `"microsoft"`（微软正版账号）。
    /// 启动页点头像弹出的账号面板切换时写入；SLLaunchBridge 的账号选择分支据此决定
    /// 用离线身份还是微软身份（与 PCL.Mac 的「点头像切换账号」交互对齐）。
    @Published var accountMode: String {
        didSet { store.set(accountMode, forKey: UDK.accountMode) }
    }

    /// 自定义微软登录 client id（空串 = 用 `MicrosoftAuthConstants.fallbackClientID`）。
    /// 「设置 → 账号」写入。⚠️ `MicrosoftAuthService.clientID` 是 nonisolated 的，
    /// 它直接读 `UserDefaults[UDK.microsoftClientID]` 而不是本对象 —— 两者键相同，
    /// 因此这里写入后登录立刻生效，无需重启。
    @Published var microsoftClientID: String {
        didSet { store.set(microsoftClientID, forKey: UDK.microsoftClientID) }
    }

    @Published var cachedJavaPath: String? {
        didSet { store.set(cachedJavaPath, forKey: UDK.cachedJavaPath) }
    }

    @Published var avatarImageURL: URL? {
        didSet {
            if let url = avatarImageURL {
                store.set(url.path, forKey: UDK.avatarImagePath)
            } else {
                store.removeObject(forKey: UDK.avatarImagePath)
            }
        }
    }

    @Published var skinImageURL: URL? {
        didSet {
            if let url = skinImageURL {
                store.set(url.path, forKey: UDK.skinImagePath)
            } else {
                store.removeObject(forKey: UDK.skinImagePath)
            }
        }
    }

    @Published var appliedSkinHash: String? {
        didSet { store.set(appliedSkinHash, forKey: UDK.appliedSkinHash) }
    }

    @Published var fixedOfflineUUID: String {
        didSet { store.set(fixedOfflineUUID, forKey: UDK.fixedOfflineUUID) }
    }

    @Published var selectedJavaPath: String? {
        didSet { store.set(selectedJavaPath, forKey: UDK.selectedJavaPath) }
    }

    private init() {
        self.accentColor = Self.loadStoredColor(forKey: UDK.accentColor, store: store) ?? .blue
        self.selectedMinecraftVersion = store.string(forKey: UDK.selectedMinecraftVersion) ?? ""
        self.selectedGameRoot = store.string(forKey: UDK.selectedGameRoot) ?? ""
        self.offlineUsername = store.string(forKey: UDK.offlineUsername) ?? "Player"
        self.accountMode = store.string(forKey: UDK.accountMode) ?? "offline"
        self.microsoftClientID = store.string(forKey: UDK.microsoftClientID) ?? ""
        self.cachedJavaPath = store.string(forKey: UDK.cachedJavaPath)
        self.appliedSkinHash = store.string(forKey: UDK.appliedSkinHash)
        self.selectedJavaPath = store.string(forKey: UDK.selectedJavaPath)

        if let saved = store.string(forKey: UDK.fixedOfflineUUID) {
            self.fixedOfflineUUID = saved
        } else {
            let uuid = fixedOfflineUUIDValue()
            self.fixedOfflineUUID = uuid
            store.set(uuid, forKey: UDK.fixedOfflineUUID)
        }

        if let path = store.string(forKey: UDK.avatarImagePath) {
            self.avatarImageURL = URL(fileURLWithPath: path)
        } else {
            self.avatarImageURL = Bundle.main.url(forResource: "avatar", withExtension: "png")
        }

        if let path = store.string(forKey: UDK.skinImagePath) {
            self.skinImageURL = URL(fileURLWithPath: path)
        } else {
            self.skinImageURL = nil
        }

        // 清理历史遗留脏数据：占位提示串曾被存成真实用户名，长度超过 MC 16 字符上限，
        // 在 1.20.5+ 进服时 hello 包编码会失败。
        //
        // 位置约束：该分支必须放在全部存储属性初始化完成之后。`offlineUsername` 是属性包装
        // 属性，读写都要经 `_offlineUsername` 存储，属于「引用 self」；而 `fixedOfflineUUID`
        // `avatarImageURL`、`skinImageURL` 在本分支之后才被赋值。官方《Initialization》
        // Safety check 4：「An initializer cannot
        // call any instance methods, read the values of any instance properties, or refer to
        // self as a value until after the first phase of initialization is complete.」
        // 该规则由 SIL 阶段的确定初始化（Definite Initialization）诊断执行，`swiftc -typecheck`
        // 不产生 SIL 因而看不到；真实构建会直接报错
        // 「'self' used in property access 'offlineUsername' before all stored properties are initialized」。
        // https://docs.swift.org/swift-book/documentation/the-swift-programming-language/initialization/
        //
        // 与本类型其他逻辑无依赖：只改写 offlineUsername，读写的 UserDefaults key 与其他属性不重合，
        // 因此从上方移到此处不改变任何行为，只是满足初始化顺序约束。
        let legacyPlaceholder = "SL启动器（最好使用英文及下划线）"
        if self.offlineUsername == legacyPlaceholder {
            self.offlineUsername = "Player"
            store.set(self.offlineUsername, forKey: UDK.offlineUsername)
        }
    }

    private func saveColor(_ color: Color, forKey key: String) {
        // 归档侧开启安全编码，与解档侧的 unarchivedObject(ofClass:from:)（安全解档入口）策略对齐。
        // 依据：NSKeyedArchiver.requiresSecureCoding 的官方 Note「Enabling secure coding doesn't
        // change the output format of the archive」，即该开关不参与归档格式生成，改 true 不会与
        // 旧数据产生格式割裂；NSColor 符合 NSSecureCoding（官方 Conforms To 含 NSCoding/
        // NSSecureCoding），不会命中「归档不符合 NSSecureCoding 的类时抛异常」这条路径。
        // https://developer.apple.com/documentation/foundation/nskeyedarchiver/requiressecurecoding
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: NSColor(color), requiringSecureCoding: true) {
            store.set(data, forKey: key)
        }
    }

    private static func loadStoredColor(forKey key: String, store: UserDefaults) -> Color? {
        guard let data = store.data(forKey: key),
              let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return nil
        }
        return Color(nsColor)
    }

    #if DEBUG
    /// 测试专用：把本进程的设置持久化**整体重定向**到独立偏好域。
    ///
    /// 为什么需要它：测试宿主的宿主 App 就是 qwq.app 本体，测试进程里的
    /// `UserDefaults.standard` **就是用户真实偏好域**。而设置项（已选版本、游戏根目录、
    /// 皮肤哈希……）被多个套件直接驱动，过去只能靠「哨兵值 + `defer` 还原」隔离 ——
    /// 一旦宿主 abort（Xcode 26.2 隔离析构缺陷，见 `qwqTests/TESTING.md` §五），
    /// `defer` 不执行，哨兵值就留在用户真实设置里。重定向后写入在物理上落不到真实域，
    /// 不再依赖任何还原动作。
    ///
    /// ⚠️ 生产代码不得调用；Release 构建里此方法不存在
    /// （与 `MemoryCacheReclaimer.resetForTesting()`、`AccountManager.makeForTesting(store:)` 同一约定）。
    /// 还原由调用方负责（测试用 `addTeardownBlock`）；即便没还原也无害：
    /// 写入只会落到那个一次性域，用户真实设置不受影响。
    static func redirectPersistenceForTesting(to store: UserDefaults) {
        shared.store = store
    }
    #endif
}
