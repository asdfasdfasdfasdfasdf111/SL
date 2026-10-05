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
//  版本目录页（2026-10-02 收尾轮新增）：`VersionFolderMigrationView`，
//  承载「读取时自动规范化」迁移期开关与手动扫描/确认执行入口（详见该文件头注释）。
//

import SwiftUI

/// 偏好设置场景内容。
struct SettingsScene: View {
    var body: some View {
        // TabView 三页：个性化（原有镜像入口）+ 账号（微软登录 client id）+ 版本目录
        //（规范化迁移期入口）。
        // 固定宽度取三页内容的最大自然宽（560），高度给版本目录页留够计划列表展示空间。
        TabView {
            ColorPickerView()
                .tabItem { Label("个性化", systemImage: "paintpalette") }

            AccountSettingsView()
                .tabItem { Label("账号", systemImage: "person.crop.circle") }

            VersionFolderMigrationView()
                .tabItem { Label("版本目录", systemImage: "folder.badge.gearshape") }
        }
        .frame(width: 560, height: 480)
    }
}