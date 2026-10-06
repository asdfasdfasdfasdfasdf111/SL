//
//  FlowLayout.swift
//  标签/胶囊的自动换行布局（替代横向 ScrollView —— 标签多时横向滚动在 macOS 上
//  需要触控板/Shift+滚轮才能看全，日常鼠标用户"看不到后面的"，故改为自动换行）。
//  纯布局视图：不持有状态，按子视图实际尺寸逐行排布，行末放不下的换到下一行。
//  依据条目：SwiftUI《Layout》协议（macOS 13.0+，本工程部署 13.0，可用）。
//  官方链接：https://developer.apple.com/documentation/swiftui/layout
//

import SwiftUI

/// 自动换行布局：子视图按宽度逐个排在同一行，放不下则换行。
/// 行高取本行子视图的最大高度；垂直方向行间距 `verticalSpacing`。
struct FlowLayout: Layout {
    /// 同一行内相邻子视图的水平间距。
    var horizontalSpacing: CGFloat = 6
    /// 相邻两行的垂直间距。
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                width = max(width, rowWidth)
                height += rowHeight + verticalSpacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += rowWidth > 0 ? horizontalSpacing + size.width : size.width
            rowHeight = max(rowHeight, size.height)
        }
        width = max(width, rowWidth)
        height += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            sub.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}