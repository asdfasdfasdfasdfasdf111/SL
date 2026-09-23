//
//  ModpackFolderPickerView.swift
//  模块化拆分：从 ModInstallViews.swift 拆出「整合包安装位置选择」弹窗组件。
//  数据与回调全外部传入（packName + onConfirm/onCancel），
//  选中文件夹 selectedFolderURL 为组件局部 @State（弹窗生命周期内有效）。
//

import SwiftUI
import AppKit

/// 整合包安装位置选择弹窗。
///
/// **自包含**：数据与回调全部由外部传入，本视图不读任何全局状态（主题除外），
/// 因此可以独立预览与测试。
/// ⚠️ `selectedFolderURL` 是 `@State`，弹窗关闭即销毁 —— 再次打开时**不会记得**上次选的位置。
struct ModpackFolderPickerView: View {
    /// 要安装的整合包名，仅用于展示。
    let packName: String
    /// 用户点「安装」且已选中目录时回调，参数是选中的安装位置。
    let onConfirm: (URL) -> Void
    /// 取消回调 —— 右上角关闭按钮与底部「取消」按钮**共用同一个**，行为完全一致。
    let onCancel: () -> Void

    /// 用户选中的安装目录；nil 表示还没选，「安装」按钮据此置灰禁用。
    @State private var selectedFolderURL: URL?
    /// 入场动画开关：初值 false（缩放 0.85 + 全透明），onAppear 之后置 true 触发弹入。
    @State private var showContent: Bool = false
    /// 主题色订阅：`accentColor` 随用户设置变化，视图会随之重绘。
    @ObservedObject var theme = ThemeManager.shared

    // 结构自上而下：标题行 → 分隔线 →（选中后）路径预览 → 分隔线 → 按钮行。
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // 标题行：左图标 + 标题 + 右侧关闭按钮（Spacer 把关闭按钮推到最右）。
                HStack {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)
                    Text("整合包安装")
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

                Text("整合包「\(packName)」")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack(spacing: 0) {
                    Text("请选择整合包安装的地址：")
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                    // 选目录入口：按钮上直接显示已选目录名，避免再占一行。
                Button(action: selectFolder) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11))
                            // 未选时显示引导文案，已选则只显示末级目录名（完整路径在下方预览行）。
                            Text(selectedFolderURL?.lastPathComponent ?? "选择文件夹")
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.accentColor.opacity(0.4), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.accentColor.opacity(0.08))
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().padding(.horizontal, 20)

            // 选中之后才出现路径预览行；未选中时整块不占高度（不留空白）。
            if let url = selectedFolderURL {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.accentColor.opacity(0.6))
                        Text(url.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }

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
                    // 兜底再判一次 nil：按钮此时已被 disabled，正常点不到这里。
                    if let url = selectedFolderURL {
                        onConfirm(url)
                    }
                }) {
                    Text("安装")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 80, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedFolderURL != nil ? theme.accentColor : theme.accentColor.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                // 双重保护：没选目录时按钮置灰并禁用，同时点击回调里也再判一次 nil。
                .disabled(selectedFolderURL == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // 固定宽度 450、高度由内容决定 —— 弹窗尺寸不随整合包名的长短变化。
        .frame(width: 450)
        // 毛玻璃卡片 + 外阴影：本弹窗不是系统 sheet，背景需要自己画。
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        )
        // 入场动画的初始态由这两个修饰符表达（缩小一点 + 全透明），
        // onAppear 后动画到 1 —— 因此初值必须是 false。
        .scaleEffect(showContent ? 1 : 0.85)
                .opacity(showContent ? 1 : 0)
        .onAppear {
            // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，
            // 同步写 @State 会触发 "Modifying state during view update" → UAF 前兆）
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showContent = true
                }
            }
        }
    }

    /// 打开系统文件夹选择面板。
    ///
    /// ⚠️ `NSOpenPanel.begin` 的回调**不在主线程**，所以赋值 `selectedFolderURL` 之前
    /// 必须切回主线程（直接写会触发「非主线程修改 SwiftUI 状态」的问题）。
    ///
    /// ⚠️ 面板允许新建文件夹，但**不检查所选目录是否为空、是否已有游戏实例** ——
    /// 覆写既有文件的风险由后续安装流程承担。
    private func selectFolder() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择整合包安装位置"
        openPanel.message = "请选择一个空文件夹或新建文件夹来安装整合包"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                DispatchQueue.main.async {
                    self.selectedFolderURL = url
                }
            }
        }
    }
}
