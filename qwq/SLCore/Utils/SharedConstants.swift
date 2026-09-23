//
//  Constants.swift
//  SL启动器
//
//  Created by YiZhiMCQiu on 2025/5/20.
//

import Foundation

/// 全局共享的常量（目录 / URL / 版本号）。
///
/// 显式 `nonisolated`：工程启用 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不标注会被推断为
/// 主 actor 隔离，于是**每一个**从非隔离上下文（下载层 `NetDownloader` / `NetSliceFetcher`
/// 都在 `nonisolated` 路径上）读取 `SharedConstants.shared.logURL` 之类的调用点都会报
/// 「main actor-isolated static property 'shared' cannot be accessed from outside of the actor」
/// —— 编译器已证实的有 4 处，且这些调用点被迫为取一个常量而 `await` 切回主线程。
/// 本类型全部成员都是 `let`（在 `init` 中一次性赋值、之后不可变），类型为 Sendable 的
/// `URL` / `String`，因此整类型脱离主 actor 是**语义正确**的，而不是为了消警告的妥协。
/// 依据：SE-0449《Allow `nonisolated` to prevent global actor inference》——允许在类型声明上
/// 写 `nonisolated` 阻止全局 actor 推断；实现于 Swift 6.1（本机工具链 6.2.3）。
/// 该写法是编译期语义，不引入任何 OS 版本要求，macOS 13.0 目标不受影响。
/// 官方链接：https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md
/// （同类用法在本工程已有先例：`Services/CacheManager.swift` 的 `LRUCache`。）
public nonisolated struct SharedConstants {
    public static let shared = SharedConstants()
    
    public let applicationContentsURL: URL
    public let applicationResourcesURL: URL
    public let logURL: URL
    public let applicationSupportURL: URL = URL.applicationSupportDirectory.appendingPathComponent("SL启动器")
    public let temperatureURL: URL
    public let authlibInjectorURL: URL
    
    /// 已删除的成员：`public let dateFormatter = DateFormatter()`（连同 init 里为它设置的
    /// `dateFormat` / `timeZone` 两行）。全库（含 `qwqTests`）**没有任何读取点**——
    /// 它是纯粹的死状态：每次访问 `SharedConstants.shared` 都会多构造一个 `DateFormatter`，
    /// 并在 `init` 里做两次本地化较重的配置，却从未被使用。
    /// 若将来确需共享格式化器，请**不要**加回本类型：`DateFormatter` 不是线程安全的，
    /// 而本类型现在是非隔离的、可被任意线程读取；那种场景应改用 `Date.FormatStyle`（值语义、
    /// 无共享可变状态），或在使用方各自持有实例。
    /// 注：日志时间戳的格式化器在 `SLCore/LogManager.swift` 的 `LogStore` 内，
    /// 由串行队列保护，与本类型无关。
    
    public let version = "Beta 0.1.1"
    public let branch: String
    
    private init() {
        self.applicationContentsURL = Bundle.main.bundleURL.appendingPathComponent("Contents")
        self.applicationResourcesURL = self.applicationContentsURL.appendingPathComponent("Resources")
        self.logURL = applicationSupportURL.appendingPathComponent("Logs").appendingPathComponent("app.log")
        self.temperatureURL = applicationSupportURL.appendingPathComponent("Temp")
        self.authlibInjectorURL = applicationSupportURL.appendingPathComponent("authlib-injector.jar")
        
        let branch = Bundle.main.object(forInfoDictionaryKey: "BRANCH") as? String
        self.branch = (branch?.isEmpty ?? true) ? "本地构建" : branch!
    }
}
