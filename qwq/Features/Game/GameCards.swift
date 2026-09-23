//
//  GameCards.swift
//  模块化拆分：从 GameViews.swift 拆出（原文件 2776 行，拆分后职责单一、可读性提升）
//

import SwiftUI
import AppKit

struct PrerequisiteModCard: View {
    let item: DownloadedItem
    let action: () -> Void
    @State private var scale: CGFloat = 1.0
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

struct LoaderSelectorCard: View {
    let loader: String
    let isSelected: Bool
    /// 检测状态：supported 可选中 / checking 转圈 / notSupported 置灰不可点 / unavailable 点击重试
    var state: LoaderState = .supported
    /// 结果未知时点击卡片触发整版重试
    var onRetry: (() -> Void)? = nil
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值
    @ObservedObject var theme: ThemeManager
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

struct VersionLoaderCard: View {
    let version: String
    let isSelected: Bool
    let loader: String
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值
    @ObservedObject var theme: ThemeManager
    let action: () -> Void
    @State private var scale: CGFloat = 1.0

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


