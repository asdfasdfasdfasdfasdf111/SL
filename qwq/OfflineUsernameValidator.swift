import Foundation

// MARK: - 离线用户名合法性提示（自 CategoryContentView 拆出，PCL2 语义）
// 与 PCLCore.validateOfflineUsername（启动前硬校验）互补：这里只算「提示文案」，
// 不弹窗、不打断，供输入框下方内联展示。

enum OfflineUsernameValidator {
    /// 返回用户名的合法性提示（无问题返回 nil）。
    /// - 超过 16 字符（MC hello 包 writeUtf(name,16) 上限）
    /// - 含非 [0-9A-Za-z_] 字符（1.18+ 服务端拒绝，Invalid characters in username）
    static func hint(for raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.utf16.count > 16 {
            return "用户名不能超过 16 个字符"
        }
        if !name.isEmpty, name.range(of: "^[0-9A-Za-z_]*$", options: .regularExpression) == nil {
            // PCL2 HintChinese 语义：1.18+ 服务端拒绝非 [0-9A-Za-z_] 用户名（Invalid characters in username）
            return "仅限英文、数字、下划线，否则 1.18+ 无法进入"
        }
        return nil
    }
}
