//
//  ModpackFolderPickerView.swift
//  模块化拆分：从 ModInstallViews.swift 拆出「整合包安装位置选择」弹窗组件。
//  数据与回调全外部传入（packName + onConfirm/onCancel），
//  选中文件夹 selectedFolderURL 为组件局部 @State（弹窗生命周期内有效）。
//

import SwiftUI
import AppKit

struct ModpackFolderPickerView: View {
    let packName: String
    let onConfirm: (URL) -> Void
    let onCancel: () -> Void

    @State private var selectedFolderURL: URL?
    @State private var showContent: Bool = false
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
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
                    Button(action: selectFolder) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 11))
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
                .disabled(selectedFolderURL == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 450)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        )
        .scaleEffect(showContent ? 1 : 0.85)
        .opacity(showContent ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                showContent = true
            }
        }
    }

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
