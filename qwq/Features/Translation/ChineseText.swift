import Foundation

/// 中文字符检测纯函数（翻译服务 / 翻译源竞速共享）。
///
/// 整枚举标 `nonisolated`：工程启用 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，未标注的静态成员
/// 会被推断为主 actor 隔离；而 `TranslationService` 的只读缓存查询已改为 `nonisolated`，
/// 其实现需要在非隔离上下文同步调用 `contains(_:)`。本枚举只含常量与纯函数，无隔离状态。
/// 依据：SE-0449《Allow `nonisolated` to prevent global actor inference》——允许在类型声明上写
/// `nonisolated` 以阻止全局 actor 推断（实现于 Swift 6.1，本机工具链 6.2.3；纯编译期语义，
/// 不引入 OS 版本要求，macOS 13.0 目标不受影响）。
/// 官方链接：https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md
nonisolated enum ChineseText {
    /// `\p{Han}` 编译一次后复用。
    ///
    /// 旧写法 `s.range(of: "\\p{Han}", options: .regularExpression)` 走 NSString 的
    /// `NSRegularExpressionSearch` 路径，每次调用都要重新编译同一个模式字符串；本方法位于
    /// `TranslationService.prefetchTranslations` 的逐 id 循环内（单次列表填充可达上万次调用），
    /// 编译开销按调用次数线性累计，且与字符串长度无关，短副标题下占比更高。
    ///
    /// 无需 `nonisolated(unsafe)`：NSRegularExpression 官方明确「设计为不可变且线程安全，
    /// 单个实例可在多线程上同时用于匹配操作」，编译期亦判定其为 Sendable，因此静态常量可
    /// 直接跨并发域共享（本文件实测加 `nonisolated(unsafe)` 反而触发"多余"告警）。
    /// 官方链接：https://developer.apple.com/documentation/foundation/nsregularexpression
    ///   （Concurrency and Thread Safety：NSRegularExpression is designed to be immutable and thread safe）
    private static let hanRegex = try? NSRegularExpression(pattern: "\\p{Han}")

    /// 判断字符串是否包含中文字符。
    /// 匹配模式、范围（整个字符串）与选项（无）与旧实现完全一致，故结果不变。
    static func contains(_ s: String) -> Bool {
        guard let hanRegex else { return false }
        return hanRegex.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }
}
