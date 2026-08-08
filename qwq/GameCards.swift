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
    @ObservedObject var theme = ThemeManager.shared

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
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                appearOpacity = 1
                appearOffset = 0
            }
        }
    }
}

struct LoaderSelectorCard: View {
    let loader: String
    let isSelected: Bool
    let action: () -> Void
    @State private var scale: CGFloat = 1.0
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 8) {
            Text(loader)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            Image(mapLoaderAsset(loader))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
                .cornerRadius(6)
                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
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
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.punchySpring) { scale = 1.08 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { scale = 1.0 }
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
    let action: () -> Void
    @State private var scale: CGFloat = 1.0
    @ObservedObject var theme = ThemeManager.shared

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

struct GameGridCard: View {
    let title: String?
    let subtitle: String?
    let isSelected: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let scale: CGFloat
    let brightnessVal: Double
    let action: () -> Void

    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            ZStack {
                if title == nil && subtitle == nil {
                    emptyCardBase
                } else if title == "下载" {
                    emptyCardBase
                    VStack(spacing: 4) {
                        Text(title ?? "")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary)
                        Text(subtitle ?? "")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.12),
                                    theme.accentColor.opacity(0.03),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.06),
                                    Color.clear,
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer()
                        Text(title ?? "")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary)
                        Text(subtitle ?? "")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(theme.accentColor.opacity(0.9))
                        Spacer()
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer()
                        Text(title ?? "")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary.opacity(0.6))
                        Text(subtitle ?? "")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.6))
                        Spacer()
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .brightness(brightnessVal - 1.0)
        .frame(width: cardWidth, height: cardHeight)
        .animation(.spring(response: 0.55, dampingFraction: 0.45), value: scale)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: brightnessVal)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: isSelected)
    }

    private var emptyCardBase: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            )
    }
}

