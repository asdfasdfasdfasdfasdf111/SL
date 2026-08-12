import SwiftUI

struct JavaSelectionPopup: View {
    let message: String
    @Binding var isPresented: Bool
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.5
    
    var body: some View {
        if isPresented {
            Text(message)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                )
                .scaleEffect(scale)
                .opacity(opacity)
                .onAppear {
                    // 入场弹入：延迟到渲染事务外（onAppear 处于视图更新事务中，
                    // 同步写 @State 会触发 "Modifying state during view update" → UAF 前兆）
                    DispatchQueue.main.async {
                        withAnimation(.exaggeratedSpring) {
                            opacity = 1
                            scale = 1
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.explosiveSpring) {
                            opacity = 0
                            scale = 0.5
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            isPresented = false
                        }
                    }
                }
        }
    }
}

struct JavaPickerView: View {
    @Binding var selectedJavaPath: String?
    @EnvironmentObject var settings: LauncherSettings
    @ObservedObject var theme = ThemeManager.shared
    @State private var isRefreshing = false
    @State private var refreshRotation: Double = 0
    @State private var localSelection: String? = nil
    @State private var hasInitialized = false
    @State private var contentScale: CGFloat = 0.7
    @State private var contentOpacity: Double = 0
    @State private var selectedIndex: Int = 0
    @State private var highlightOffset: CGFloat = 0
    @State private var highlightHeight: CGFloat = 36
    @State private var cachedOptions: [(id: String, label: String, detail: String)] = []
    
    private func buildOptions() -> [(id: String, label: String, detail: String)] {
        var options: [(id: String, label: String, detail: String)] = [
            (id: "auto", label: "自动选择（推荐）", detail: "启动器自动匹配")
        ]
        for java in settings.availableJavaList {
            options.append((id: java.path, label: "Java \(java.majorVersion)", detail: java.path))
        }
        return options
    }
    
    private var allOptions: [(id: String, label: String, detail: String)] {
        cachedOptions.isEmpty ? buildOptions() : cachedOptions
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Java 环境")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button(action: startRefresh) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                            .rotationEffect(.degrees(refreshRotation))
                        Text("刷新")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .onChange(of: isRefreshing) { newValue in
                    // ⚠️ onChange 处于视图更新事务中，withAnimation 内同步写 @State 会触发
                    // "Modifying state during view update"（UAF 前兆），延迟到渲染事务外
                    DispatchQueue.main.async {
                        if newValue {
                            // 点击后持续旋转直到刷新完成（repeatForever 非线性平滑旋转）
                            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                                refreshRotation += 360
                            }
                        } else {
                            // 刷新完成：平滑回正停止
                            withAnimation(.easeOut(duration: 0.35)) {
                                refreshRotation = 0
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if isRefreshing && settings.availableJavaList.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(height: 40)
                    Spacer()
                }
            } else if settings.availableJavaList.isEmpty && !isRefreshing {
                Text("未找到 Java 环境")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(allOptions.enumerated()), id: \.element.id) { index, option in
                            JavaPickerRow(
                                label: option.label,
                                detail: option.detail,
                                isSelected: isOptionSelected(option.id),
                                index: index,
                                action: { selectOption(option.id, index: index) }
                            )
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    // ⚠️ onAppear 处于视图更新事务中，updateSelectedIndex 写
                                    // selectedIndex/highlightOffset @State，延迟到渲染事务外
                                    DispatchQueue.main.async {
                                        updateSelectedIndex()
                                    }
                                }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(0.08))
                            .padding(.horizontal, 6)
                            .frame(height: highlightHeight)
                            .offset(y: highlightOffset)
                            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: highlightOffset)
                            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: highlightHeight),
                        alignment: .topLeading
                    )
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 320)
        .scaleEffect(contentScale)
        .opacity(contentOpacity)
        .onAppear {
            // ⚠️ 首次初始化写 localSelection/hasInitialized/cachedOptions/selectedIndex 等 @State，
            // onAppear 处于视图更新事务中，同步写会触发 "Modifying state during view update"（UAF 前兆），
            // 延迟到渲染事务外执行；Java 列表刷新本身异步，晚一帧无感知
            DispatchQueue.main.async {
                if !hasInitialized {
                    localSelection = selectedJavaPath
                    hasInitialized = true
                    cachedOptions = buildOptions()
                    updateSelectedIndex()
                }
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                contentScale = 1.0
                contentOpacity = 1.0
            }
            if settings.availableJavaList.isEmpty {
                JavaManager.shared.refreshAvailableJavaList()
            }
        }
        .onDisappear {
            // ⚠️ onDisappear 处于视图更新事务中，同步写 @Binding 会触发
            // "Modifying state during view update"（UAF 前兆），延迟到渲染事务外
            let finalSelection = localSelection
            DispatchQueue.main.async {
                selectedJavaPath = finalSelection
            }
        }
        .onChange(of: settings.availableJavaList) { _ in
            // onChange 处于视图更新事务中，同步写 @State 会触发 "Modifying state during view update"（UAF 前兆）
            DispatchQueue.main.async {
                cachedOptions = buildOptions()
                updateSelectedIndex()
            }
        }
    }
    
    private func startRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        JavaManager.shared.refreshAvailableJavaList {
            self.isRefreshing = false
        }
    }

    private func isOptionSelected(_ id: String) -> Bool {
        if id == "auto" {
            return localSelection == nil
        }
        return localSelection == id
    }
    
    private func selectOption(_ id: String, index: Int) {
        if id == "auto" {
            localSelection = nil
        } else {
            localSelection = id
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
            selectedIndex = index
            highlightOffset = CGFloat(index) * 45 + 4
        }
    }
    
    private func updateSelectedIndex() {
        let options = allOptions
        for (index, option) in options.enumerated() {
            if isOptionSelected(option.id) {
                selectedIndex = index
                highlightOffset = CGFloat(index) * 45 + 4
                break
            }
        }
    }
}

struct JavaPickerRow: View {
    let label: String
    let detail: String
    let isSelected: Bool
    let index: Int
    let action: () -> Void
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.trailing, 28)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.accentColor)
                    .padding(.trailing, 14)
                    .opacity(isSelected ? 1 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isSelected)
            }
        }
        .buttonStyle(.plain)
        Divider()
            .padding(.leading, 14)
    }
}