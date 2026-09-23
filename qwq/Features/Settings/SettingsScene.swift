//
//  SettingsScene.swift
//  macOS 标准「设置…」(⌘,) 窗口的内容。
//
//  为什么现在才有：此前全库检索 `.commands { }` / `CommandGroup` / `keyboardShortcut` /
//  `Settings { }` 零命中（UI 评审第 10 条）—— 应用没有偏好设置入口、没有任何菜单栏命令，
//  全部操作只能靠鼠标点导航。本文件提供 `Settings { }` 场景的内容体。
//
//  实现方式：**镜像**「个性化」页已有的 `ColorPickerView`，不复制色板字面量、不新建状态源 ——
//  强调色的唯一真值仍是 `ThemeManager.shared.accentColor`，因此设置窗口与「个性化」页
//  永远一致（这正是评审建议的「做镜像入口」，而不是把状态搬一份出来）。
//

import SwiftUI

/// 偏好设置场景内容。
struct SettingsScene: View {
    var body: some View {
        // 不给 ColorPickerView 套 ScrollView：它自带 `.frame(maxWidth: .infinity, maxHeight: .infinity)`，
        // 放进垂直 ScrollView 会因为「无限高」导致布局异常。直接给固定尺寸即可。
        ColorPickerView()
            .frame(width: 560, height: 420)
    }
}
