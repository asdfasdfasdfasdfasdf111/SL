//
//  AppDelegate.swift
//  应用级 AppKit 兜底 —— 只放 SwiftUI 场景表达不了的那几件事。
//
//  职责：① 把已有窗口改成透明标题栏 + 全尺寸内容区（配合 Scene 的 `.hiddenTitleBar`）；
//        ② 把应用图标缩放到 0.7 倍后设为 Dock 图标（纯外观）。
//  边界：**不声明窗口最小尺寸**。唯一来源是 qwqApp.swift 根视图的 `.frame(minWidth:minHeight:)`
//        （内容约束），理由见该处注释：`NSWindow.contentMinSize` 的优先级高于 `minSize`，
//        在 AppKit 侧写 minSize 度量的是含标题栏的 frame，与内容区口径不同，属冗余声明。
//  注意：`applicationDidFinishLaunching` 时窗口已存在，这里取 `NSApp.windows.first` 是按
//        「启动即单窗口」的现状写的；将来若出现第二个窗口或先弹设置窗，需要按内容视图反查
//        目标窗口，而不是取第一个。
//

import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let window = NSApp.windows.first else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // 此处不再声明 window.minSize：窗口最小尺寸的唯一来源是根视图 qwqApp.swift 的
        // .frame(minWidth: 680, minHeight: 500)（内容约束）。
        // 官方明文：NSWindow.contentMinSize「This method takes precedence over the minSize
        // property.」——https://developer.apple.com/documentation/appkit/nswindow/contentminsize
        // 故在 AppKit 侧写 minSize（度量对象是含标题栏的 frame，与内容区不同）不会改变
        // 内容区最小尺寸的实际效果，属冗余声明。此前本处写 800×590、LauncherWindowModifier
        // 写 800×550，两处数值不一致且均被内容约束压过，已一并删除；数值只在内容约束那一处声明
        // （该约束 2026-10-05 由 800×590 下调为 680×500）。
        // 应用图标缩放到 0.7 倍
        if let icon = NSImage(named: "AppIcon") {
            let scale: CGFloat = 0.7
            let newSize = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: newSize),
                      from: NSRect(origin: .zero, size: icon.size),
                      operation: .copy,
                      fraction: 1.0)
            resized.unlockFocus()
            NSApp.applicationIconImage = resized
        }
        // 开发期 UI 自拍（仅 SL_SNAPSHOT_DIR 环境变量存在时生效，产品运行不参与）。
        SnapshotHarness.runIfRequested()
        // 启动自动检查更新：延迟 5 秒（首帧 / 目录预热 / 快照优先）。
        // 5 秒的依据：快照 harness 首帧等待 3s，再晚用户已经开点了，再早抢首屏资源。
        //
        // 历史：本调用由 9d8c6cc 加上，随后被 3d03872（更新服务器那次）删掉，理由是
        // 「App 无需频繁轮询」；但那样一来 App 里就再没有任何**看得见**的更新入口
        //（只剩「帮助」菜单里一项），所以 2026-10-10 恢复 —— 现在有更新会主动弹窗。
        //
        // ⚠️ 这段注释原先写着「下载与换装只在用户点了『立即更新』后才发生」，那是**错的**：
        // 弹窗有 5 分钟兜底超时，而超时原先硬编码按下标 0 应答 = 自动开始换装。
        // 现已让更新提示显式把隐式应答指向「下次再说」（见 AppUpdateCoordinator 的
        // fallbackChoiceIndex），「用户不理」不再等于「自动替换 App」。
        // 手动入口仍在「帮助」菜单（force: true，会给「已是最新」反馈）。
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await AppUpdateCoordinator.checkOnLaunch()
        }
    }
}