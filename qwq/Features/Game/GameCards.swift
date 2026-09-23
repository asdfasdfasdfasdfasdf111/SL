//
//  GameCards.swift
//  模块化拆分：从 GameViews.swift 拆出（原文件 2776 行，拆分后职责单一、可读性提升）
//

//
//  GameCards.swift
//  模块化拆分：从 GameViews.swift 拆出（原文件 2776 行，拆分后职责单一、可读性提升）
//
//  三个「卡片」共用同一套视觉语言（圆角 16 / secondary 6% 底 / 按下缩放动画），
//  差别只在内容与交互：
//    PrerequisiteModCard —— 前置依赖小卡（宽 130，点击跳转）
//    LoaderSelectorCard   —— 加载器选择卡（四态：可选中 / 检测中 / 不支持 / 未知可重试）
//    VersionLoaderCard    —— 版本 + 加载器图标卡（模组详情页与整合包网格共用）
//  三者都是**受控组件**：数据与回调全由外部传入，视图内部只持有动画用的临时 @State。
//

import SwiftUI
import AppKit

/// 前置依赖小卡片：宽 130 的紧凑条目，展示依赖名与副标题，点击即触发 `action`。
struct PrerequisiteModCard: View {
    /// 依赖条目（名字 + 副标题）。本视图只读这两个字段，不关心它来自哪次下载。
    let item: DownloadedItem
    /// 点击回调 —— 由宿主决定「点了依赖之后去哪」。
    let action: () -> Void
    /// 按下时临时放大到 1.06，松手（0.12s 后）复原；纯反馈，与选中状态无关。
    @State private var scale: CGFloat = 1.0
    /// 入场动画的两个中间量：起始全透明 + 下移 12pt，onAppear 后归位。
    @State private var appearOpacity: Double = 0
    @State private var appearOffset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(item.subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 130)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .scaleEffect(scale)
        .opacity(appearOpacity)
        .offset(y: appearOffset)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.punchySpring) { scale = 1.06 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { scale = 1.0 }
            }
        }
        .onAppear {
            // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，同步写 @State 会触发
            // "Modifying state during view update" → UAF 前兆）
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                    appearOpacity = 1
                    appearOffset = 0
                }
            }
        }
    }
}

/// 加载器选择卡（如 Fabric / Forge / NeoForge）。
/// ⚠️ 四个状态里只有 `.supported` 可选中；`.checking` 与 `.notSupported` 点击**无反应**，
/// `.unavailable`（结果未知，如网络失败）点击走 `onRetry` 整版重试 ——
/// 非正常态都刻意给出明确出路，避免用户以为界面卡死。
struct LoaderSelectorCard: View {
    let loader: String
    let isSelected: Bool
    /// 检测状态：supported 可选中 / checking 转圈 / notSupported 置灰不可点 / unavailable 点击重试
    var state: LoaderState = .supported
    /// 结果未知时点击卡片触发整版重试
    var onRetry: (() -> Void)? = nil
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值
    @ObservedObject var theme: ThemeManager
    /// 选中回调（仅 `.supported` 态会走到）。
    let action: () -> Void
    @State private var scale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 8) {
            // 图标是本地 asset，任何状态都直接显示；checking 仅降透明度表示未定论（不可点），不转圈
            Image(mapLoaderAsset(loader))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .cornerRadius(6)
                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                .opacity(state == .notSupported ? 0.25 : (state == .checking ? 0.7 : 1))
            Text(loader)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .opacity(state == .notSupported ? 0.4 : 1)
            if state == .unavailable {
                Text("重试")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? theme.accentColor : Color.clear, lineWidth: 2)
        )
        .scaleEffect(scale)
        .opacity(state == .notSupported ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            // 按状态分派点击行为：只有 supported 才真的「选中」，unavailable 转为重试。
            switch state {
            case .supported:
                withAnimation(.punchySpring) { scale = 1.08 }
                action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.punchySpring) { scale = 1.0 }
                }
            case .unavailable:
                onRetry?()
            case .checking, .notSupported:
                break
            }
        }
    }

    /// 加载器名 → 本地图片资源名。
    /// ⚠️ 大小写各列一份、且 `rift` 映射到 fabric 图标（Rift 已停维护，无独立图标）；
    /// 表外的名字一律回落 "fabric" —— 拼错的名字会安静地显示成 Fabric 图标，
    /// 既不报错也不留空。
    private func mapLoaderAsset(_ name: String) -> String {
        let m: [String: String] = [
            "fabric": "fabric", "Fabric": "fabric",
            "forge": "Forge", "Forge": "Forge",
            "neoforge": "NeoForged", "NeoForged": "NeoForged", "neoforged": "NeoForged",
            "quilt": "Quilt", "Quilt": "Quilt",
            "rift": "fabric"
        ]
        return m[name] ?? "fabric"
    }
}

/// 版本 + 图标卡：上方文字（版本号）、下方加载器图标。
/// 模组详情页的版本列表与整合包版本网格**共用**这一个视图，靠 `version` 的内容区分。
/// ⚠️ 图标直接 `Image(loader)` 取资源名 —— 调用方必须已过 `LoaderNameResolver` 转换，
/// 本视图不做任何名字解析。
struct VersionLoaderCard: View {
    let version: String
    let isSelected: Bool
    /// 加载器名（如 fabric）：既用于展示文本，也用于查图标资源。
    let loader: String
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值
    @ObservedObject var theme: ThemeManager
    /// 选中回调。
    let action: () -> Void
    @State private var scale: CGFloat = 1.0

    // 布局固定为「文字在上、图标在下」，与 LoaderSelectorCard 的「图标在上」相反 ——
    // 版本网格里用户扫的是文字，图标只起辅助识别作用。
    var body: some View {
        VStack(spacing: 8) {
            Text(version)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            Image(loader)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .cornerRadius(6)
                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? theme.accentColor : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 0.5)
        )
        .scaleEffect(scale)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.punchySpring) { scale = 1.08 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { scale = 1.0 }
            }
        }
    }
}


