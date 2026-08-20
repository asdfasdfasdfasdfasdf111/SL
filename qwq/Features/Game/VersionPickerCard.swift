//
//  VersionPickerCard.swift
//  模块化拆分：从 GameCategoryView 拆出「版本选择卡片」组件，
//  含版本列表（或未找到提示）+ 右上角 Java 选择 popover + 底部「添加文件夹/全盘查找游戏」按钮。
//  纯展示组件：状态（selectedJavaPath）@Binding 外置，行为（onSelect/onOpenFolderPicker/onFullDiskScan）回调外置。
//

import SwiftUI

struct VersionPickerCard: View {
    let versions: [String]
    let hasVersions: Bool
    let selectedVersion: String
    let javaPickerLabel: String
    let showBottomButtons: Bool
    @Binding var selectedJavaPath: String?
    let onSelect: (String) -> Void
    let onOpenFolderPicker: () -> Void
    let onFullDiskScan: () -> Void

    @EnvironmentObject var settings: LauncherSettings
    @ObservedObject var theme = ThemeManager.shared
    @State private var showJavaPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    if hasVersions {
                        Text("选择游戏版本").font(.headline).foregroundColor(.secondary).padding(.bottom, 4)
                        // 版本横向滑动（版本多时左右拖动查看，避免超出卡片高度被裁）
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(versions, id: \.self) { version in
                                    VersionButton(title: version, isSelected: selectedVersion == version) {
                                        onSelect(version)
                                    }
                                    .frame(width: 170)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        VStack(spacing: 20) {
                            Text("未找到游戏版本").font(.headline).foregroundColor(.secondary)
                            Text("请将 Minecraft 游戏文件夹（包含 versions 目录）放入常用目录（文稿、下载等），或手动选择")
                                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                            Button(action: onOpenFolderPicker) {
                                Text("寻找版本")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 160, height: 40)
                                    .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial).shadow(radius: 2))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 12)
                    }
                }
                .padding(24)
                .frame(minWidth: 280)
                .background(RoundedRectangle(cornerRadius: 24).fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 5))
                .overlay(alignment: .topTrailing) {
                    if hasVersions {
                        Button(action: { showJavaPicker = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "cup.and.saucer.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.accentColor)
                                Text(javaPickerLabel)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showJavaPicker, arrowEdge: .trailing) {
                            JavaPickerView(selectedJavaPath: $selectedJavaPath)
                                .environmentObject(settings)
                        }
                        .padding([.top, .trailing], 10)
                    }
                }
                Spacer()
            }
            if showBottomButtons {
                VStack(spacing: 8) {
                    Button(action: onOpenFolderPicker) {
                        Text("添加文件夹")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.accentColor, lineWidth: 1)
                                    .background(.ultraThinMaterial)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                    Button(action: onFullDiskScan) {
                        Text("全盘查找游戏")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }
}
