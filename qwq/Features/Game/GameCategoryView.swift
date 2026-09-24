//
//  GameCategoryView.swift
//  模块化拆分：从 GameViews.swift 拆出「我的世界」分类页（版本选择卡片 + Java 选择），
//  原文件剩余 DownloadCategoryView（下载游戏页）。
//  第二十五批：版本卡片区块下沉 VersionPickerCard（qwq/VersionPickerCard.swift），
//  扫描逻辑提炼 GameScanService（qwq/GameScanService.swift），本文件退化为 UI 编排 + 状态持有。
//  第二十六批（本次）：扫描状态与业务决策整体下沉
//  ViewModels/GameCategoryViewModel.swift（超时判定、结果决议、全盘查找、目录校验、Java 标签派生），
//  本文件只保留布局、AppKit 面板呈现、省略号计时器与全部 withAnimation 时序。
//

import SwiftUI
import AppKit


struct GameCategoryView: View {
    @EnvironmentObject var settings: LauncherSettings
    /// 主题来源由调用方注入（全局单例外部持有），本视图透传给版本卡片
    let theme: ThemeManager

    // 扫描状态（检索中 / 卡片显隐 / 版本清单 / 超时标记）与全部业务决策（超时判定、
    // 结果决议、全盘查找、目录校验、Java 标签派生）归 ViewModels/GameCategoryViewModel.swift，
    // 本视图只订阅展示状态，并在既有动画事务内驱动其展示状态写入。
    @StateObject private var viewModel = GameCategoryViewModel()

    // 以下为纯视图状态：「游戏检索中...」省略号逐帧计数（文案常量与计数均不参与业务决策）
    @State private var loadingText = "游戏检索中"
    @State private var dotCount = 1
    @State private var loadingTimer: Timer?

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                Text(loadingText + String(repeating: ".", count: dotCount))
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.primary)
                    .transition(.opacity)
            }
            if viewModel.showCard {
                VersionPickerCard(
                    theme: theme,
                    versions: viewModel.versions,
                    hasVersions: viewModel.hasVersions,
                    selectedVersion: settings.selectedMinecraftVersion,
                    javaPickerLabel: viewModel.javaPickerLabel,
                    showBottomButtons: viewModel.showBottomButtons,
                    selectedJavaPath: $settings.selectedJavaPath,
                    onSelect: { version in
                        withAnimation(.explosiveSpring) {
                            settings.selectedMinecraftVersion = version
                        }
                    },
                    onOpenFolderPicker: openFolderPicker,
                    onFullDiskScan: { viewModel.fullDiskScan() }
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.4), value: viewModel.showCard)
        .animation(.easeOut(duration: 0.4), value: viewModel.isLoading)
        // 本工程部署目标为 macOS 13.0：onChange(of:initial:_:) 需 macOS 14.0+，不可用，
        // 沿用旧签名 onChange(of: perform:)（省略号计时器只读取新值，不依赖闭包捕获语义）
        .onChange(of: viewModel.isLoading) { newValue in
            if newValue { startLoadingAnimation() }
            else { stopLoadingAnimation() }
        }
        .onAppear {
            // ⚠️ startScanning 经 ViewModel 同步重置四个展示状态，onAppear 处于视图更新事务中，
            // 同步写会触发 "Modifying state during view update"（UAF 前兆），
            // 整体延迟到渲染事务外执行（扫描逻辑本身异步，晚一帧启动无感知）
            DispatchQueue.main.async {
                startScanning()
            }
        }
        .onDisappear {
            loadingTimer?.invalidate()
            loadingTimer = nil
        }
    }

    // MARK: - 省略号计时器（纯展示动画）

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

    // MARK: - 扫描时序

    /// 扫描编排：重置、超时判定、结果决议与全部业务规则在 ViewModel；
    /// 本函数只保留既有动画事务（0.8s 超时退化 / 0.8s 卡片出现 / 0.4s 载入结束）与时序，
    /// 语句顺序与收口前逐字一致（重置 → 发起扫描 → 挂超时 → 等结果）。
    /// 两处回调都先核代际号：定时器与 `Task` 续体都可能跨代触发（旧扫描的回调落在新扫描头上）。
    private func startScanning() {
        let scanGeneration = viewModel.resetScanState()
        let scanTask = viewModel.beginScan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            guard viewModel.isCurrentScan(scanGeneration), viewModel.shouldApplyScanTimeout() else { return }
            withAnimation(.easeOut(duration: 0.8)) {
                viewModel.applyScanTimeoutPresentation()
            }
        }
        Task {
            let result = await scanTask.value
            await MainActor.run {
                // 迟到的结果照常应用，只丢「已被新一代扫描取代」的回调：
                // 超时只是提前把界面从「检索中」放出来，不代表这次扫描作废 ——
                // 丢掉它，界面就永久停在「未找到游戏版本」，必须手动点一次全盘查找才恢复。
                guard viewModel.isCurrentScan(scanGeneration) else { return }
                viewModel.applyScanResult(result)
                withAnimation(.easeOut(duration: 0.8)) {
                    viewModel.presentScanCard()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        viewModel.finishScanLoading()
                    }
                }
            }
        }
    }

    // MARK: - 手动选择游戏目录

    /// 仅负责 AppKit 面板的呈现与回调接线；目录校验与落库决策在
    /// `GameCategoryViewModel.applyChosenGameRoot(path:)`。
    private func openFolderPicker() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择 Minecraft 游戏根目录（包含 versions 文件夹的目录）"
        openPanel.message = "请选择一个包含 versions 子目录的文件夹"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                viewModel.applyChosenGameRoot(path: url.path)
            }
        }
    }
}
