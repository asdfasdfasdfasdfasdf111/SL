//
//  ModInstallSelectionView.swift
//  模块化拆分：从 ModInstallViews.swift 拆出「模组安装目标选择」弹窗组件。
//  数据与回调全外部传入（modName/modVersion/instances + onConfirm/onCancel），
//  选中状态 selectedIds 为组件局部 @State（弹窗生命周期内有效）。
//

import SwiftUI

struct ModInstallSelectionView: View {
    let modName: String
    let modVersion: String
    let instances: [GameInstance]
    let onConfirm: ([GameInstance]) -> Void
    let onCancel: () -> Void

    @State private var selectedIds: Set<UUID> = []
    @State private var showContent: Bool = false
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)
                    Text("模组安装")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("模组「\(modName)」需要 Minecraft \(modVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text("已检测到多个同版本游戏，请选择要加入此 mod 的版本：")
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 20)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(instances) { instance in
                        Button(action: {
                            if selectedIds.contains(instance.id) {
                                selectedIds.remove(instance.id)
                            } else {
                                selectedIds.insert(instance.id)
                            }
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(selectedIds.contains(instance.id) ? theme.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                                        .frame(width: 18, height: 18)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(selectedIds.contains(instance.id) ? theme.accentColor.opacity(0.15) : Color.clear)
                                        )
                                    if selectedIds.contains(instance.id) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(theme.accentColor)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(instance.version)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text(instance.rootPath)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if instance.id != instances.last?.id {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(instances.count) * 50 + 20, 300))

            Divider().padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 80, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial)
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    let selected = instances.filter { selectedIds.contains($0.id) }
                    onConfirm(selected)
                }) {
                    Text("安装 (\(selectedIds.count))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 100, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedIds.isEmpty ? theme.accentColor.opacity(0.4) : theme.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(selectedIds.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        )
        .scaleEffect(showContent ? 1 : 0.85)
        .opacity(showContent ? 1 : 0)
        .onAppear {
            if instances.count == 1, let first = instances.first {
                selectedIds = [first.id]
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                showContent = true
            }
        }
    }
}
