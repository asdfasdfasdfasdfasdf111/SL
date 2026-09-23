//
//  VersionPickerCard.swift
//  模块化拆分：从 GameCategoryView 拆出「版本选择卡片」组件，
//  含版本列表（或未找到提示）+ 右上角 Java 选择 popover + 底部「添加文件夹/全盘查找游戏」按钮。
//  纯展示组件：状态（selectedJavaPath）@Binding 外置，行为（onSelect/onOpenFolderPicker/onFullDiskScan）回调外置。
//

//
//  VersionPickerCard.swift
//  模块化拆分：从 GameCategoryView 拆出「版本选择卡片」组件，
//  含版本列表（或未找到提示）+ 右上角 Java 选择 popover + 底部「添加文件夹/全盘查找游戏」按钮。
//  纯展示组件：状态（selectedJavaPath）@Binding 外置，行为（onSelect/onOpenFolderPicker/onFullDiskScan）回调外置。
//
//  ⚠️ 两处按钮含义不同，别混淆：
//    右上角 popover 按钮 —— 选**用哪个 Java 跑游戏**（仅在有版本时出现）；
//    底部两个按钮       —— 找不到游戏时的手动补救（加目录 / 全盘扫），是否出现由 showBottomButtons 决定。
//

import SwiftUI

/// 版本选择卡片：居中的浮层面板，纵向排列所有版本号按钮。
struct VersionPickerCard: View {
    /// 主题来源由调用方注入；本视图读取 accentColor，故订阅其变化
    @ObservedObject var theme: ThemeManager
    /// 可选版本号列表（调用方已排好序）。本视图不排序、不去重。
    let versions: [String]
    /// ⚠️ 它与 `versions.isEmpty` 语义**不完全等价**：由调用方给，用来区分
    /// 「确实一个版本都没扫到」（走空态引导文案）与其它中间情形。
    let hasVersions: Bool
    /// 当前选中的版本号。
    let selectedVersion: String
    /// Java 选择按钮上的文案（如 `Java 17` / `未选择 Java`），由调用方算好。
    let javaPickerLabel: String
    /// 是否显示底部的「添加文件夹 / 全盘查找游戏」——由调用方按场景开关。
    let showBottomButtons: Bool
    @Binding var selectedJavaPath: String?
    let onSelect: (String) -> Void
    let onOpenFolderPicker: () -> Void
    let onFullDiskScan: () -> Void

    /// 设置注入给 popover 里的 JavaPickerView（它需要读写已添加的 Java 列表）。
    @EnvironmentObject var settings: LauncherSettings
    /// 控制右上角 Java 选择 popover 的展开，仅本视图内部使用。
    @State private var showJavaPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    // 两条互斥分支：有版本 → 列表；无版本 → 空态引导。
                    if hasVersions {
                        Text("选择游戏版本").font(.headline).foregroundColor(.secondary).padding(.bottom, 4)
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(versions, id: \.self) { version in
                                    VersionButton(title: version, isSelected: selectedVersion == version, theme: theme) {
                                        onSelect(version)
                                    }
                                }
                            }
                        }
                        // 版本多时列表内部滚动，高度封顶 420，避免面板长到超出屏高。
                        .frame(maxHeight: 420)
                    } else {
                        // 空态：一句「为什么找不到」+ 一句「怎么办」，再给一个按钮。
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
                // 右上角 Java 选择入口。没有版本时不出现 —— 没版本可跑，选 Java 没意义。
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
                        // arrowEdge: .trailing 让气泡箭头指向右侧按钮，视觉上说明「从哪弹出来的」。
                        .popover(isPresented: $showJavaPicker, arrowEdge: .trailing) {
                            JavaPickerView(selectedJavaPath: $selectedJavaPath)
                                .environmentObject(settings)
                        }
                        .padding([.top, .trailing], 10)
                    }
                }
                Spacer()
            }
            // 底部补救区：两个按钮都只调外部回调，本视图不自己做任何目录操作。
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
                    // 「全盘查找」做成下划线小字，是刻意的弱化 —— 它是重操作（真扫全盘），
                    // 不该被误当成主操作点。
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
