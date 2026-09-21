//
//  ui-click.swift
//  通过辅助功能 API（AX）按元素名称执行点击，并报告元素位置
//
//  为什么不按坐标点：
//  目标应用会把部分元素布局到窗口边界之外（实测窗口 x 范围 644~1444，
//  但元素报出 @2133 / @2857 / @3044 等坐标）。按坐标点击会落到窗口外，
//  而按元素执行动作不受坐标系影响。
//
//  用法：
//    swiftc -O ui-click.swift -o /tmp/ui-click
//    /tmp/ui-click <pid> <元素名> [depth]
//      元素名按 desc / title / value 依次匹配，取先序遍历的第一个命中项
//

import ApplicationServices
import Foundation

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as AnyObject?
}

func text(_ element: AXUIElement, _ name: String) -> String {
    (attr(element, name) as? String) ?? ""
}

func frame(_ element: AXUIElement) -> String {
    var posValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let p = posValue, let s = sizeValue,
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
    else { return "(无位置信息)" }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return "@\(Int(point.x)),\(Int(point.y)) \(Int(size.width))x\(Int(size.height))"
}

var matched: AXUIElement?
var depthOfMatch = 0
var visited = 0

func search(_ element: AXUIElement, target: String, depth: Int, maxDepth: Int) {
    if matched != nil || depth > maxDepth { return }
    visited += 1

    let role = text(element, kAXRoleAttribute as String)
    let title = text(element, kAXTitleAttribute as String)
    let desc = text(element, kAXDescriptionAttribute as String)
    let value = text(element, kAXValueAttribute as String)

    if desc == target || title == target || value == target {
        matched = element
        depthOfMatch = depth
        return
    }

    if let children = attr(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children {
            search(child, target: target, depth: depth + 1, maxDepth: maxDepth)
            if matched != nil { return }
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    print("用法: ui-click <pid> <元素名> [depth]")
    exit(1)
}
let target = args[2]
let maxDepth = args.count >= 4 ? (Int(args[3]) ?? 12) : 12

let app = AXUIElementCreateApplication(pid)
search(app, target: target, depth: 0, maxDepth: maxDepth)

guard let element = matched else {
    print("未找到元素：\"\(target)\"（已遍历 \(visited) 个节点）")
    exit(2)
}

let role = text(element, kAXRoleAttribute as String)
print("命中元素: role=\(role) desc=\"\(text(element, kAXDescriptionAttribute as String))\" title=\"\(text(element, kAXTitleAttribute as String))\" \(frame(element)) (深度 \(depthOfMatch)，共遍历 \(visited) 个节点)")

// 可滚动区域外的元素先滚入可见区，否则按下动作可能无效
// 注意：kAXScrollToVisibleAction 在新版 SDK 中不再导出，使用其字符串名
let scrollResult = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
if scrollResult == .success {
    print("已执行 ScrollToVisible")
}

let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
if pressResult == .success {
    print("按下成功（AXPress）")
    print("按下后位置: \(frame(element))")
} else {
    print("按下失败，错误码: \(pressResult.rawValue)")
    exit(3)
}
