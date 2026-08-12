//
//  SessionLogCardView.swift
//  模块化拆分：启动日志卡片视图（从 CategoryContentView.swift 拆出）
//  用 @ObservedObject 监听 session.logs 变化，确保日志实时刷新
//

import SwiftUI

struct SessionLogCardView: View {
    @ObservedObject var session: GameSession
    let logCardHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("启动日志\(session.index)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
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
                        ForEach(session.logs.indices, id: \.self) { idx in
                            Text(session.logs[idx])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(idx)
                        }
                    }
                    .padding(4)
                }
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
