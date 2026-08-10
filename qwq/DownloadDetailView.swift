//
//  DownloadDetailView.swift
//  下载详情页：照抄 PCL.Mac InstallingView 布局（左侧信息面板 + 右侧任务卡片），
//  全部换成启动器毛玻璃风格（RoundedRectangle(cornerRadius: 20).fill(.regularMaterial)）。
//

import SwiftUI

/// 下载详情页（对标 PCL.Mac InstallingView）
struct DownloadDetailView: View {
    @ObservedObject var manager = DownloadDetailManager.shared
    @ObservedObject private var speedMeter = SpeedMeter.shared

    var body: some View {
        HStack(spacing: 16) {
            // 左侧信息面板（对标 LeftTabView：总进度 / 下载速度 / 剩余文件）
            // 一张大的圆角矩形毛玻璃卡（用户要求：左侧栏变成圆角矩形）
            VStack(spacing: 14) {
                PanelView(
                    title: "总进度",
                    value: manager.tasks.totalFiles < 0 ? "未知" : String(format: "%.1f %%", manager.tasks.getProgress() * 100)
                )
                PanelView(
                    title: "下载速度",
                    value: "\(Self.formatSpeed(speedMeter.downloadSpeed))"
                )
                PanelView(
                    title: "剩余文件",
                    value: manager.tasks.remainingFiles < 0 ? "-" : String(describing: manager.tasks.remainingFiles)
                )
                Spacer()
            }
            .padding(.vertical, 10)
            .frame(width: 200)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            )

            // 右侧任务卡片（对标 StaticMyCard 列表）
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(manager.tasks.getTasks()) { task in
                        DownloadTaskCard(task: task) {
                            entries(for: task)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        // 无返回键：再次点击圆形下载按钮即可回到刚才的页面（由 GameViews toggle 控制）
    }

    /// 单个任务各阶段渲染（对标 InstallingView.getEntries）：
    /// inprogress → 实时百分比；finished → 勾选图标；waiting/failed → 对应图标 + 阶段名
    @ViewBuilder
    private func entries(for task: InstallTask) -> some View {
        let states = task.getInstallStates()
            .sorted { $0.key.rawValue < $1.key.rawValue }
        VStack(spacing: 0) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, pair in
                let (stage, state) = pair
                HStack(spacing: 10) {
                    if state == .inprogress {
                        Text(String(format: "%.0f%%", task.currentStagePercentage * 100))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ThemeManager.shared.accentColor)
                            .frame(minWidth: 44, alignment: .leading)
                    } else {
                        Image(systemName: Self.iconName(for: state))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Self.iconColor(for: state))
                            .frame(minWidth: 44, alignment: .leading)
                    }
                    Text(stage.getDisplayName())
                        .font(.system(size: 13))
                        .foregroundColor(state == .failed ? .red : .primary)
                    Spacer()
                }
                .frame(height: 28)
            }
        }
    }

    private static func iconName(for state: InstallState) -> String {
        switch state {
        case .finished: return "checkmark.circle.fill"
        case .waiting: return "circle"
        case .failed: return "xmark.circle.fill"
        case .inprogress: return "arrow.down.circle.fill"
        }
    }

    private static func iconColor(for state: InstallState) -> Color {
        switch state {
        case .finished: return .green
        case .waiting: return Color.secondary.opacity(0.5)
        case .failed: return .red
        case .inprogress: return ThemeManager.shared.accentColor
        }
    }

    /// 速度格式化（对标 PCL.Mac InstallingView.formatSpeed：B/s ~ TB/s）
    static func formatSpeed(_ speed: Int64) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value: Double = Double(speed)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        let formatted = String(format: value < 10 && unitIndex > 0 ? "%.1f" : "%.0f", value)
        return "\(formatted) \(units[unitIndex])"
    }
}

/// 左侧信息面板内容（对标 PCL.Mac PanelView：标题 + 2px 分割线 + 数值）。
/// 背景由外层大卡提供（圆角矩形毛玻璃），自身不画背景避免双重卡片。
private struct PanelView: View {
    let title: String
    let value: String
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Rectangle()
                .fill(theme.accentColor.opacity(0.5))
                .frame(width: 140, height: 2)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
}

/// 右侧任务卡片（对标 PCL.Mac StaticMyCard：标题 + 逐阶段内容，毛玻璃卡片）
private struct DownloadTaskCard<Content: View>: View {
    let task: InstallTask
    let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ThemeManager.shared.accentColor.opacity(0.15))
                    .frame(width: 8, height: 8)
                Text(task.getTitle())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        )
    }
}
