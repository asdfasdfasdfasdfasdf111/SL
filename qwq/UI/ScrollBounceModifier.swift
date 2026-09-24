//
//  ScrollBounceModifier.swift
//  给滚动视图关掉「内容不足一屏也要回弹」的橡皮筋效果，并且把可用性判断收在一处。
//
//  为什么需要它：`scrollBounceBehavior(_:)` 是 **macOS 13.3** 才有的 API，而本工程部署目标是
//  **13.0**，直接用会编译不过（或需要 `@available` 标注扩散到所有调用点）。
//  这里用一次 `#available(macOS 13.3, *)` 包住，调用方拿到的永远是「能用就用、不能用就原样」，
//  不必各自重复写可用性守卫。官方链接
//  https://developer.apple.com/documentation/swiftui/view/scrollbouncebehavior(_:axes:)
//
//  用 `.basedOnSize` 而不是 `.always` 的原因：本工程的滚动区（卡片副标题可滚动、
//  详情页头部长版本号可滚动、版本选择区可滚动）在多数情况下内容并没有超出可见高度，
//  保持 `.always` 会出现「内容明明全在，手指一拖它却晃」的假反馈。
//  `.basedOnSize` 只在内容确实溢出时才允许回弹，符合「能滚才滚」的直觉。
//
//  现有调用点（3 处）：`ContentCard`、`DetailPageHeader`、`VersionSelectionSection`。
//

import SwiftUI

/// 把 `scrollBounceBehavior(.basedOnSize)` 包成「可用性安全」的修饰器。
struct ScrollBounceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.3, *) {
            // 这些滚动区全是**横向**的，必须显式指定 `.horizontal`：
            // `scrollBounceBehavior` 的 `axes` 参数默认是 `[.vertical]`，不写只对纵向滚动视图生效，
            // 对横向滚动区等于「挂了但没生效」（这是此前静默失效的根因）。
            content.scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            // macOS 13.0–13.2：API 不存在，保持系统默认回弹行为（不改变任何既有观感）
            content
        }
    }
}

extension View {
    /// 在支持的系统上关闭「内容不足一屏时的回弹」；不支持的系统上原样返回。
    /// 调用方无需自己写 `#available`。
    func scrollBounceIfAvailable() -> some View {
        self.modifier(ScrollBounceModifier())
    }
}