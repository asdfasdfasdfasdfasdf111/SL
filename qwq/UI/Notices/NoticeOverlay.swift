import SwiftUI

/// 全局提示展示层。挂在根视图上，订阅 `NoticeCenter.shared.current`，
/// 以顶部横幅形式显示当前提示（不影响下层布局，仅顶部卡片区域接收点击）。
struct NoticeOverlay: View {
    @ObservedObject var center: NoticeCenter
    /// 按钮强调色来源：本视图不读取，仅向下透传，故不订阅
    let theme: ThemeManager

    var body: some View {
        VStack {
            if let notice = center.current {
                NoticeCard(notice: notice, center: center, theme: theme)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // ⚠️ 必须以 `notice.id` 作为身份。`NoticeCenter.current` 是单槽，`deliver()` 里
                    // 是 `current = notice` **直接顶替**（不经过 nil）；若不给卡片绑定 id，
                    // 新提示与旧提示落在视图树的同一位置、同一个类型 → 被判定为**同一个视图在更新**，
                    // 于是 `.transition` 不触发、`NoticeCard.onAppear` 也不再执行
                    // → 卡片的 `appeared` 一直是上次留下的 `true`。
                    // 后果：一个会话里**只有第一条提示**有弹入动画（透明度 0→1 + 缩放 0.97→1 + 从顶部滑入），
                    // 之后所有提示（连点下载失败的连续报错就是这样）都是「啪」地直接出现，动画全部失效。
                    // 绑定 id 后每次换提示都是「旧视图移除 + 新视图插入」，transition 与 onAppear 均恢复。
                    .id(notice.id)
            }
            Spacer(minLength: 0)
        }
        .animation(.exaggeratedSpring, value: center.current?.id)
        // 瞬态提示（info / success）自动消失；warning / error 需用户处理，不自动关闭。
        .task(id: center.current?.id) {
            guard let notice = center.current,
                  notice.level == .info || notice.level == .success else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if center.current?.id == notice.id { center.dismiss() }
        }
        .onAppear {
            // 延迟到渲染事务外，避免在视图更新期间改 @Published 触发状态改写告警。
            DispatchQueue.main.async { center.setPresenter(true) }
        }
        .onDisappear {
            DispatchQueue.main.async { center.setPresenter(false) }
        }
    }
}

private struct NoticeCard: View {
    let notice: Notice
    @ObservedObject var center: NoticeCenter
    /// 按钮强调色来源：本视图不读取，仅向下透传，故不订阅
    let theme: ThemeManager
    @State private var appeared = false
    /// 错误原因做两级展示：第一段（一句话结论）常显，其余（失败原因清单）默认收起。
    /// 展开状态只属于这一张卡片；卡片以 `notice.id` 作身份（见 NoticeOverlay 的 `.id(notice.id)`），
    /// 换提示即换视图，状态不会串到下一张。
    @State private var showDetail = false

    /// 是否渲染按钮行。
    ///
    /// 唯一一个按钮若是「知道了」类（`isAcknowledge`），就不渲染它 —— 右上角的 `×` 与它是
    /// 同一个动作（见 `NoticeCenter.dismiss()` 的实现：`choose(notice, index: 0)`）。
    /// 同一结果给两个语义重复的控件会让用户以为它们不同（评审第 8 条）。
    /// ⚠️ 只影响「渲染与否」，`notice.buttons` 的内容与顺序一字未动：
    /// `choose(index:)` 与 `presentAndWait` 都依赖下标语义。
    private var showsButtonRow: Bool {
        guard !notice.buttons.isEmpty else { return false }
        if notice.buttons.count == 1, notice.buttons[0].isAcknowledge { return false }
        return true
    }

    /// 正文按第一个换行切分：前段作结论，余下作可展开的详情。
    /// 只有「结论 + 换行 + 详情」这种两段式才拆；单行正文原样渲染。
    private static func splitMessage(_ message: String) -> (summary: String, detail: String) {
        guard let newline = message.firstIndex(of: "\n") else { return (message, "") }
        let summary = String(message[message.startIndex..<newline])
        let detail = String(message[message.index(after: newline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary, detail)
    }

    private var accent: Color {
        switch notice.level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var iconName: String {
        switch notice.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(accent)

            VStack(alignment: .leading, spacing: 6) {
                Text(notice.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                if !notice.message.isEmpty {
                    let parts = Self.splitMessage(notice.message)
                    // 第一段：一句话结论，常显
                    Text(parts.summary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)

                    if !parts.detail.isEmpty {
                        // 详情：失败原因清单通常有若干行，直接铺开会把提示卡撑得很长，
                        // 因此默认收起（评审第 8 条：错误原因做两级）
                        if showDetail {
                            Text(parts.detail)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 420, alignment: .leading)
                        }
                        Button {
                            withAnimation(.punchySpring) { showDetail.toggle() }
                        } label: {
                            Text(showDetail ? "收起详情" : "查看详情")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showsButtonRow {
                    HStack(spacing: 8) {
                        ForEach(Array(notice.buttons.enumerated()), id: \.element.id) { index, button in
                            NoticeButtonView(button: button, theme: theme) {
                                center.choose(notice, index: index)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            Button {
                center.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(accent.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        )
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.punchySpring) { appeared = true }
            }
        }
    }
}

private struct NoticeButtonView: View {
    let button: NoticeButton
    let theme: ThemeManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(button.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(background)
                )
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch button.style {
        case .accent: return theme.accentColor
        case .danger: return .red.opacity(0.85)
        case .normal: return Color.secondary.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch button.style {
        case .accent, .danger: return .white
        case .normal: return .primary
        }
    }
}
