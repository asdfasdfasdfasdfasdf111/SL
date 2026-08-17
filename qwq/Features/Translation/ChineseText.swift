import Foundation

/// 中文字符检测纯函数（翻译服务 / 翻译源竞速共享）。
enum ChineseText {
    /// 判断字符串是否包含中文字符
    static func contains(_ s: String) -> Bool {
        s.range(of: "\\p{Han}", options: .regularExpression) != nil
    }
}
