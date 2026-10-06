//
//  ModpackFolderPickerView.swift
//  模块化拆分：从 ModInstallViews.swift 拆出「整合包安装位置选择」弹窗组件。
//  数据与回调全外部传入（packName + onConfirm/onCancel），
//  选中文件夹 selectedFolderURL 为组件局部 @State（弹窗生命周期内有效）。
//  2026-10-02：脚手架（标题行/卡片/入场动画/按钮行）收敛到共享骨架
//  `UI/Shell/PopupCardScaffold.swift`（审计判据 B #4），本文件只留差异部分。
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

    /// 主题色订阅：`accentColor` 随用户设置变化，视图会随之重绘。
    @ObservedObject var theme = ThemeManager.shared

    // 结构自上而下（标题区与按钮行由骨架提供）：副文案 + 选目录入口 →（选中后）路径预览。
    var body: some View {
        PopupCardScaffold(
            icon: "archivebox.fill",
            title: "整合包安装",
            cardWidth: 450,
            confirmTitle: "安装",
            confirmWidth: 80,
            isConfirmEnabled: selectedFolderURL != nil,
            onConfirm: {
                // 兜底再判一次 nil：按钮此时已被 disabled，正常点不到这里。
                if let url = selectedFolderURL {
                    onConfirm(url)
                }
            },
            onCancel: onCancel,
            header: {
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
                        // 统一按钮样式（用户要求）：**白框 + 毛玻璃 + 居中文字**。
                        // 此前用 theme.accentColor（已中性化为 primary）+ 8% 填充 + 左对齐，
                        // 既看不出"框"，文字也不居中，与其它按钮不是一套。
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)                     // 文字居中
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.10))        // 毛玻璃（统一淡白）
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)   // 白框
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .fixedSize(horizontal: false, vertical: true)
            },
            content: {
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
            }
        )
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