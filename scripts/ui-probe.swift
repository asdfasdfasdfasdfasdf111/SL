//
//  ui-probe.swift
//  通过 macOS 辅助功能 API（AX）遍历目标应用的界面元素树
//
//  与「按坐标点击」的区别：
//  - 元素级操作：定位到 AXButton 元素后直接 PerformAction，不传坐标
//  - 不受屏幕坐标 / 窗口坐标系 / 多显示器 / 缩放差异影响
//  - 可读取元素真实语义（role / title / value / enabled），而不是靠像素猜
//
//  用法：
//    swiftc ui-probe.swift -o /tmp/ui-probe
//    /tmp/ui-probe <pid> [maxDepth]
//

import ApplicationServices
import Foundation

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as AnyObject?
}

func text(_ element: AXUIElement, _ name: String) -> String {
    if let s = attr(element, name) as? String { return s }
    return ""
}

func boolValue(_ element: AXUIElement, _ name: String) -> Bool? {
    if let n = attr(element, name) as? NSNumber { return n.boolValue }
    return nil
}

func frame(_ element: AXUIElement) -> (x: Double, y: Double, w: Double, h: Double)? {
    var posValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let p = posValue, let s = sizeValue, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return (Double(point.x), Double(point.y), Double(size.width), Double(size.height))
}

/// 可交互元素的判定：能接收点击或其他用户动作的 role
let interactiveRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
    "AXTextField", "AXTextArea", "AXSlider", "AXLink", "AXTab", "AXMenuItem",
    "AXDisclosureTriangle", "AXComboBox", "AXSegmentedControl", "AXToggle"
]

var interactiveCount = 0
var totalCount = 0

func dump(_ element: AXUIElement, depth: Int, maxDepth: Int) {
    let role = text(element, kAXRoleAttribute as String)
    var subrole = text(element, kAXSubroleAttribute as String)
    let title = text(element, kAXTitleAttribute as String)
    let description = text(element, kAXDescriptionAttribute as String)
    let value = text(element, kAXValueAttribute as String)
    let identifier = text(element, kAXIdentifierAttribute as String)
    let enabled = boolValue(element, kAXEnabledAttribute as String)

    let isWindow = (role == "AXWindow")
    if role.isEmpty && title.isEmpty && description.isEmpty { 
        // 无信息节点，只遍历子节点
        if depth < maxDepth, let children = attr(element, kAXChildrenAttribute as String) as? [AXUIElement] {
            for child in children { dump(child, depth: depth + 1, maxDepth: maxDepth) }
        }
        return
    }

    totalCount += 1
    let isInteractive = interactiveRoles.contains(role)
    if isInteractive { interactiveCount += 1 }

    let indent = String(repeating: "  ", count: depth)
    var line = "\(indent)[\(role)"
    if !subrole.isEmpty { line += "/\(subrole)" }
    line += "]"
    if !title.isEmpty { line += " title=\"\(title)\"" }
    if !description.isEmpty { line += " desc=\"\(description)\"" }
    if !value.isEmpty && value.count < 60 { line += " value=\"\(value)\"" }
    if !identifier.isEmpty { line += " id=\"\(identifier)\"" }
    if let enabled, !enabled { line += " [disabled]" }
    if let f = frame(element) {
        line += " @\(Int(f.x)),\(Int(f.y)) \(Int(f.w))x\(Int(f.h))"
    }
    if isInteractive { line += "  <== 可交互" }
    print(line)

    guard depth < maxDepth else { return }
    if let children = attr(element, kAXChildrenAttribute as String) as? [AXUIElement] {
        for child in children { dump(child, depth: depth + 1, maxDepth: maxDepth) }
    }
}

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    print("用法: ui-probe <pid> [maxDepth]")
    exit(1)
}
let maxDepth = args.count >= 3 ? (Int(args[2]) ?? 8) : 8

let app = AXUIElementCreateApplication(pid)
print("=== 界面元素树（PID \(pid)，最大深度 \(maxDepth)）===")
dump(app, depth: 0, maxDepth: maxDepth)
print("")
print("=== 汇总：共 \(totalCount) 个具名元素，其中 \(interactiveCount) 个可交互 ===")
