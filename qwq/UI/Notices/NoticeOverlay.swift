import SwiftUI

/// 全局提示展示层。挂在根视图上，订阅 `NoticeCenter.shared.current`，
/// 以顶部横幅形式显示当前提示（不影响下层布局，仅顶部卡片区域接收点击）。
struct NoticeOverlay: View {
    @ObservedObject private var center = NoticeCenter.shared

    var body: some View {
        VStack {
            if let notice = center.current {
                NoticeCard(notice: notice)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
    @ObservedObject private var center = NoticeCenter.shared
    @State private var appeared = false

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
                    Text(notice.message)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                }

                if !notice.buttons.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(notice.buttons.enumerated()), id: \.element.id) { index, button in
                            NoticeButtonView(button: button) {
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
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

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
