//
//  GameCategoryView.swift
//  模块化拆分：从 GameViews.swift 拆出「我的世界」分类页（版本选择卡片 + Java 选择），
//  原文件剩余 DownloadCategoryView（下载游戏页）。
//  第二十五批：版本卡片区块下沉 VersionPickerCard（qwq/VersionPickerCard.swift），
//  扫描逻辑提炼 GameScanService（qwq/GameScanService.swift），本文件退化为 UI 编排 + 状态持有。
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
                VersionPickerCard(
                    versions: versions,
                    hasVersions: hasVersions,
                    selectedVersion: settings.selectedMinecraftVersion,
                    javaPickerLabel: javaPickerLabel,
                    showBottomButtons: hasVersions || (versions.isEmpty && !isLoading),
                    selectedJavaPath: $settings.selectedJavaPath,
                    onSelect: { version in
                        withAnimation(.explosiveSpring) {
                            settings.selectedMinecraftVersion = version
                        }
                    },
                    onOpenFolderPicker: openFolderPicker,
                    onFullDiskScan: fullDiskScan
                )
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
            return await GameScanService.resolveGameRoot(savedRoot: savedRoot)
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

    private func fullDiskScan() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = await GameScanService.fullDiskScanGames()
            await MainActor.run {
                isLoading = false
                showCard = true
                settings.javaPopupMessage = "已找到 \(result.count) 个游戏"
                settings.showJavaPopup = true
                if let first = result.first {
                    versions = first.versions
                    settings.selectedGameRoot = first.root
                    settings.selectedMinecraftVersion = first.versions.first ?? ""
                    hasVersions = true
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
