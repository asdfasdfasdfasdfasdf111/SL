//
//  SessionLogCardView.swift
//  模块化拆分：启动日志卡片视图（从 CategoryContentView.swift 拆出）
//  用 @ObservedObject 监听 session.logs 变化，确保日志实时刷新
//

import SwiftUI

struct SessionLogCardView: View {
    /// ⚠️ 必须是 `@ObservedObject`（不能是 `let`）：日志是**追加式**变化的，
    /// 视图要订阅 session 才能实时刷新；否则日志会停在卡片出现时的那一份快照。
    @ObservedObject var session: GameSession
    /// 日志区高度由调用方按窗口尺寸算好 —— 本视图不自己决定高度（避免把窗口顶开）。
    let logCardHeight: CGFloat

    // 结构：标题行（「启动日志N」+ 关闭按钮）→ 可滚动的等宽日志区。
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("启动日志\(session.index)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                // 关闭按钮只**发通知**、不直接改状态：真正「关进程还是只移除日志」的决策
                // 由 LaunchCoordinator 在通知处理里做（视图不该知道进程怎么终止）。
                Button(action: {
                    NotificationCenter.default.post(name: .closeGameSession, object: session)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(session.isProcessRunning ? "关闭此游戏进程" : "移除此日志")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // 用下标当 id，并给每行再挂 `.id(idx)`：后者是给 scrollTo 定位的锚点 ——
                        // identity 管复用、`.id` 管滚动定位，两者缺一不可。
                        ForEach(session.logs.indices, id: \.self) { idx in
                            Text(session.logs[idx])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(idx)
                        }
                    }
                    .padding(4)
                }
                // 高度由外部传入而非自适应：日志区不能把卡片越撑越高。
                .frame(height: logCardHeight)
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
                .onChange(of: session.logs.count) { _ in
                    // ⚠️ onChange 处于视图更新事务中，同步 scrollTo 会强制 layout，
                    // 触发 AppKit "It's not legal to call -layoutSubtreeIfNeeded..." 布局递归警告；
                    // 延迟到渲染事务外滚动（日志追加后晚一帧滚到底部无感知）
                    DispatchQueue.main.async {
                        withAnimation(.exaggeratedSpring) {
                            proxy.scrollTo(session.logs.count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial).shadow(radius: 4))
    }
}
