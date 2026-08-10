//
//  GameCategoryView.swift
//  模块化拆分：从 GameViews.swift 拆出「我的世界」分类页（版本选择卡片 + Java 选择），
//  原文件剩余 DownloadCategoryView（下载游戏页）。
//

import SwiftUI
import AppKit


struct GameCategoryView: View {
    @EnvironmentObject var settings: LauncherSettings
    @ObservedObject var theme = ThemeManager.shared
    @State private var isLoading = true
    @State private var showCard = false
    @State private var loadingText = "游戏检索中"
    @State private var dotCount = 1
    @State private var versions: [String] = []
    @State private var hasVersions = false
    @State private var scanTimedOut = false
    @State private var showJavaPicker = false
    @State private var loadingTimer: Timer?

    private var javaPickerLabel: String {
        if let path = settings.selectedJavaPath {
            let list = settings.availableJavaList
            if let info = list.first(where: { $0.path == path }) {
                return "Java \(info.majorVersion)"
            }
            return "Java 自定义"
        }
        if settings.isJavaScanning {
            return "扫描中..."
        }
        if settings.availableJavaList.isEmpty {
            return "自动选择 Java"
        }
        return "自动选择 Java"
    }

    var body: some View {
        ZStack {
            if isLoading {
                Text(loadingText + String(repeating: ".", count: dotCount))
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.primary)
                    .transition(.opacity)
            }
            if showCard {
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 16) {
                            if hasVersions {
                                Text("选择游戏版本").font(.headline).foregroundColor(.secondary).padding(.bottom, 4)
                                ForEach(versions, id: \.self) { version in
                                    VersionButton(title: version, isSelected: settings.selectedMinecraftVersion == version) {
                                        withAnimation(.explosiveSpring) {
                                            settings.selectedMinecraftVersion = version
                                        }
                                    }
                                }
                            } else {
                                VStack(spacing: 20) {
                                    Text("未找到游戏版本").font(.headline).foregroundColor(.secondary)
                                    Text("请将 Minecraft 游戏文件夹（包含 versions 目录）放入常用目录（文稿、下载等），或手动选择")
                                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                                    Button(action: openFolderPicker) {
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
                                    JavaPickerView(selectedJavaPath: $settings.selectedJavaPath)
                                        .environmentObject(settings)
                                }
                                .padding([.top, .trailing], 10)
                            }
                        }
                        Spacer()
                    }
                    if (hasVersions || (versions.isEmpty && !isLoading)) {
                        VStack(spacing: 8) {
                            Button(action: openFolderPicker) {
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
                            Button(action: {
                                isLoading = true
                                Task.detached(priority: .userInitiated) {
                                    let roots = await MinecraftVersionManager.asyncFullDiskScanForGames()
                                    let count = roots.count
                                    await MainActor.run {
                                        isLoading = false
                                        showCard = true
                                        settings.javaPopupMessage = "已找到 \(count) 个游戏"
                                        settings.showJavaPopup = true
                                        if let first = roots.first {
                                            let vlist = MinecraftVersionManager.getVersions(from: first)
                                            if !vlist.isEmpty {
                                                versions = vlist
                                                settings.selectedGameRoot = first
                                                settings.selectedMinecraftVersion = vlist.first ?? ""
                                                hasVersions = true
                                            }
                                        }
                                    }
                                }
                            }) {
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
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.4), value: showCard)
        .animation(.easeOut(duration: 0.4), value: isLoading)
        .onChange(of: isLoading) { newValue in
            if newValue { startLoadingAnimation() }
            else { stopLoadingAnimation() }
        }
        .onAppear {
            startScanning()
        }
        .onDisappear {
            loadingTimer?.invalidate()
            loadingTimer = nil
        }
    }

    private func startLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                self.dotCount = (self.dotCount % 4) + 1
            }
        }
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    private func startScanning() {
        isLoading = true; showCard = false; hasVersions = false; scanTimedOut = false
        let scanTask = Task.detached(priority: .userInitiated) { () -> (root: String, versions: [String])? in
            let savedRoot = await MainActor.run { settings.selectedGameRoot }
            if !savedRoot.isEmpty, FileManager.default.fileExists(atPath: savedRoot + "/versions") {
                let versions = MinecraftVersionManager.getVersions(from: savedRoot)
                if !versions.isEmpty { return (savedRoot, versions) }
            }
            if let result = await MinecraftVersionManager.asyncFindFirstValidGame() { return result }
            else { return nil }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if isLoading && !scanTimedOut {
                scanTimedOut = true
                withAnimation(.easeOut(duration: 0.8)) { showCard = true; hasVersions = false; isLoading = false }
            }
        }
        Task {
            let result = await scanTask.value
            await MainActor.run {
                if !scanTimedOut {
                    if let (root, versionList) = result, !versionList.isEmpty {
                        versions = versionList
                        if settings.selectedGameRoot.isEmpty || settings.selectedGameRoot != root { settings.selectedGameRoot = root }
                        if settings.selectedMinecraftVersion.isEmpty || !versionList.contains(settings.selectedMinecraftVersion) {
                            settings.selectedMinecraftVersion = versions.first ?? ""
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: NSNotification.Name("GameVersionSelected"), object: nil)
                            }
                        }
                        hasVersions = true
                    } else { hasVersions = false }
                    withAnimation(.easeOut(duration: 0.8)) { showCard = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.easeOut(duration: 0.4)) { isLoading = false }
                    }
                }
            }
        }
    }

    private func openFolderPicker() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择 Minecraft 游戏根目录（包含 versions 文件夹的目录）"
        openPanel.message = "请选择一个包含 versions 子目录的文件夹"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                let chosenPath = url.path
                let versionsPath = chosenPath + "/versions"
                if FileManager.default.fileExists(atPath: versionsPath) {
                    let versionList = MinecraftVersionManager.getVersions(from: chosenPath)
                    if !versionList.isEmpty {
                        versions = versionList
                        settings.selectedGameRoot = chosenPath
                        settings.selectedMinecraftVersion = versions.first ?? ""
                        hasVersions = true
                    } else {
                        settings.launchErrorMessage = "所选文件夹的 versions 目录下没有找到任何版本"
                        settings.showLaunchAlert = true
                    }
                } else {
                    settings.launchErrorMessage = "所选文件夹不包含 versions 子目录"
                    settings.showLaunchAlert = true
                }
            }
        }
    }
}
