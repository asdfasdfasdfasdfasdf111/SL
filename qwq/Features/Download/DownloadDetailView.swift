//
//  DownloadDetailView.swift
//  下载详情页：照抄 PCL.Mac InstallingView 布局（左侧信息面板 + 右侧任务卡片），
//  全部换成启动器毛玻璃风格（RoundedRectangle(cornerRadius: 20).fill(.regularMaterial)）。
//

import SwiftUI

/// 下载详情页（对标 PCL.Mac InstallingView）。
///
/// 左侧三块统计（总进度 / 下载速度 / 剩余文件）分别来自 DownloadDetailManager 与 SpeedMeter；
/// 右侧是可滚动的任务卡列表，列表为空时显示引导空态。
/// 本视图**只读状态、不发起任何下载** —— 取消/重试等动作都在别处。
struct DownloadDetailView: View {
    /// 下载任务总控（单例）。订阅它即可在任务增删、阶段变化时自动重绘。
    @ObservedObject var manager = DownloadDetailManager.shared
    /// 下载速度来自全局计量器（约每秒推送一次），是本页唯一「不属于任务表」的数据源。
    @ObservedObject private var speedMeter = SpeedMeter.shared

    var body: some View {
        HStack(spacing: 12) {
            // 左侧信息面板（对标 LeftTabView：总进度 / 下载速度 / 剩余文件）
            // 一张大的圆角矩形毛玻璃卡（用户要求：左侧栏变成圆角矩形）
            // 左侧面板：三块统计纵向排列，宽度固定 176（与下方 .frame(width:) 对应）。
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
            }
            .padding(.vertical, 10)
            .frame(width: 176)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            )
            // 卡片高度由三组数据决定并贴顶。
            // 原先 VStack 末尾有一个 Spacer() 把卡片撑满整个 HStack 高度，而三组数据只占其中
            // 一部分 —— 卡下部留出一大片空白（评审第 3 条；
            // 截图 docs/ui-review-round5/02-window-download-detail.png）。
            // 顺序关键：本修饰符必须在 .background(...) **之后**，撑满高度的只是外层容器；
            // 若加在 .background 之前，毛玻璃卡本身仍会被撑满，问题不解决。
            .frame(maxHeight: .infinity, alignment: .top)

            // 右侧任务卡片（对标 StaticMyCard 列表）
            // 本帧取一次快照：渲染过程中不再读任务表，避免列表在中途被改写导致跳动。
            let taskList = manager.tasks.getTasks()
            if taskList.isEmpty {
                // 空态：在其所在区域内居中（原先 `padding(.top, 40)` 贴在内容区顶部），
                // 并补一行「怎么让内容出现」的说明（评审第 3 条）。
                // 文案只写事实：下载页确实列出可下载版本。
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(Color.secondary.opacity(0.7))
                    Text("没有进行中的下载")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("到「下载」页选择一个版本即可开始")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(taskList) { task in
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
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 整页毛玻璃背景，且与窗口背景融合（behindWindow）—— 所以这里不需要再铺底色。
        .background(BlurView(material: .fullScreenUI, blendingMode: .behindWindow))
        // 顶部导航由 ContentView 保持；再次点击右下角按钮可返回分类内容。
    }

    /// 单个任务各阶段渲染（对标 InstallingView.getEntries）：
    /// inprogress → 实时百分比；finished → 勾选图标；waiting/failed → 对应图标 + 阶段名
    /// 单个任务的各阶段行。
    /// ⚠️ 用 `.enumerated()` + `id: \.offset` 而非用 stage 本身当 id：
    /// 同一任务内 stage 唯一，用下标作 identity 可行；但若阶段列表顺序发生变化，
    /// SwiftUI 会按位置复用视图（当前阶段集合固定，暂无此问题）。
    @ViewBuilder
    private func entries(for task: InstallTask) -> some View {
        // 按 InstallStage 的 rawValue 排序 —— rawValue 本身就是展示顺序（安装流程 0..7）。
        let states = task.getInstallStates()
            .sorted { $0.key.rawValue < $1.key.rawValue }
        VStack(spacing: 0) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, pair in
                let (stage, state) = pair
                HStack(spacing: 10) {
                    if state == .inprogress {
                        Text(String(format: "%.0f%%", task.progressForStage(stage) * 100))
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

    /// 状态 → SF Symbol 名。
    /// ⚠️ 与 SLCore 里 `InstallState.getImageName()` 那套**不是同一套**：
    /// 界面实际用的是这里；旧方法返回占位串且已无调用方（见 InstallProgress.swift 的注释）。
    private static func iconName(for state: InstallState) -> String {
        switch state {
        case .finished: return "checkmark.circle.fill"
        case .waiting: return "circle"
        case .failed: return "xmark.circle.fill"
        case .inprogress: return "arrow.down.circle.fill"
        }
    }

    /// 状态 → 颜色。进行中取主题色（跟随用户设置），完成/失败用语义色（绿/红）。
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
        // 逐级除以 1024，直到数值小于 1024 或已经用到最大单位（TB/s）为止。
        var value: Double = Double(speed)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        // 数值小于 10 且已换过单位时保留一位小数（1.5 MB/s 比 2 MB/s 有信息量）；
        // 小于 1 KB/s 时保留整数，避免出现 0.3 B/s 这种没意义的精度。
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
            // 2pt 的主题色分隔线；宽度写死 140，与外层面板的可用宽度对齐。
            Rectangle()
                .fill(theme.accentColor.opacity(0.5))
                .frame(width: 140, height: 2)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                // 等宽数字：0.0% / 0 B/s / 0 在刷新时宽度不跳动
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
}

/// 右侧任务卡片（对标 PCL.Mac StaticMyCard：标题 + 逐阶段内容，毛玻璃卡片）
/// 泛型内容视图：卡片外壳只负责「标题圆点 + 毛玻璃底」，
/// 内部那几行阶段状态由调用方（`entries(for:)`）以闭包传入 ——
/// 因此同一张卡片可以装任意内容，无需为此再抽一层协议。
private struct DownloadTaskCard<Content: View>: View {
    let task: InstallTask
    let content: () -> Content
    // 入场动画：任务卡片出现时缩放+淡入弹入（对齐分类网格卡片，消除「卡片无动画」）
    /// 入场动画初值：略小 + 全透明；onAppear 里动画到 1。
    @State private var appearScale: CGFloat = 0.94
    @State private var appearOpacity: Double = 0

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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        )
        .scaleEffect(appearScale)
        .opacity(appearOpacity)
        .onAppear {
            // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，同步写 @State 会触发
            // "Modifying state during view update" → UAF 前兆）
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    appearScale = 1.0
                    appearOpacity = 1.0
                }
            }
        }
    }
}
