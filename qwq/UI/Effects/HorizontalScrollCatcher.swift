//
//  HorizontalScrollCatcher.swift
//  把滚轮 / 触控板的**横向**滚动转成分类页切换。
//
//  为什么需要 AppKit：macOS 13 的 SwiftUI 没有滚轮事件的钩子（既无 `onScroll`，
//  也没有可用的 `ScrollView` 横向联动 API）。分类画布目前只能靠**鼠标拖拽**
//  （`DragGesture`，见 ContentView.categoryCanvas）翻页，滚轮完全没接 ——
//  用户反馈「无法通过滚轮滑到下一个」。
//
//  行为约定（避免抢走列表的滚动）：
//  - 只接管**横向分量大于纵向**的滚动事件（触控板横扫 / 带横向滚轮的鼠标）；
//  - 纵向滚动一律 `super` 放行，版本列表等 `ScrollView` 照常滚动；
//  - 累计位移超过阈值才翻一页，且翻页后清零，防止一次惯性滚动连翻多页。
//

import AppKit
import SwiftUI

struct HorizontalScrollCatcher: NSViewRepresentable {
    /// 每次触发翻页时回调：`+1` = 下一页，`-1` = 上一页。
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onStep = onStep
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onStep = onStep
    }

    /// 只处理横向滚动的透明视图。
    final class CatcherView: NSView {
        var onStep: ((Int) -> Void)?
        /// 触发一页所需的累计横向位移（pt）。触控板惯性滚动增量很小，阈值不能太低。
        private let threshold: CGFloat = 80
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // 纵向为主的滚动交给下层（列表滚动不受影响）。
            guard abs(dx) > abs(dy), abs(dx) > 0.5 else {
                super.scrollWheel(with: event)
                return
            }
            accumulated += dx
            if abs(accumulated) >= threshold {
                // 触控板「向左扫」（内容右移）→ 看前一页，与画布 offset 方向一致。
                onStep?(accumulated > 0 ? -1 : 1)
                accumulated = 0
            }
        }
    }
}
