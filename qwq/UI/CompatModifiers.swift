import SwiftUI

// macOS 12 兼容层：把 macOS 13 才有的 SwiftUI 修饰符包成带 #available 的等价物。
// 项目最低部署目标为 macOS 12，这些 API 在 12 上不存在。

extension View {
    /// macOS 13 的 View.defaultFocus(_:_:) 的向后兼容版本；macOS 12 上不做默认焦点声明。
    @ViewBuilder
    func defaultFocusCompat(_ condition: FocusState<Bool>.Binding, _ value: Bool) -> some View {
        if #available(macOS 13.0, *) {
            self.defaultFocus(condition, value)
        } else {
            self
        }
    }

    /// macOS 13 的 View.contentTransition(.opacity) 的向后兼容版本；macOS 12 上无过渡动画。
    @ViewBuilder
    func contentTransitionOpacityCompat() -> some View {
        if #available(macOS 13.0, *) {
            self.contentTransition(.opacity)
        } else {
            self
        }
    }
}
