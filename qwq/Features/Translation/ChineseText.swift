import Foundation

/// 中文字符检测纯函数（翻译服务 / 翻译源竞速共享）。
enum ChineseText {
    /// `\p{Han}` 编译一次后复用。
    ///
    /// 旧写法 `s.range(of: "\\p{Han}", options: .regularExpression)` 走 NSString 的
    /// `NSRegularExpressionSearch` 路径，每次调用都要重新编译同一个模式字符串；本方法位于
    /// `TranslationService.prefetchTranslations` 的逐 id 循环内（单次列表填充可达上万次调用），
    /// 编译开销按调用次数线性累计，且与字符串长度无关，短副标题下占比更高。
    ///
    /// `nonisolated` 与 Sendable 诊断均不需要：NSRegularExpression 官方明确「设计为不可变且线程
    /// 安全，单个实例可在多线程上同时用于匹配操作」，编译期亦判定其为 Sendable，因此静态常量可
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
