//
//  JavaPickerView.swift
//  Java 环境选择下拉（`JavaPickerView` / `JavaPickerRow`）。
//
//  原先本文件顶部还有一个 `JavaSelectionPopup`（消息药丸）。它已上移到 `qwq/UI/TaskPill.swift`
//  并更名为 `TaskPill`：启动失败提示也要用同一个形状，把药丸做成唯一实现后，
//  「任务状态气泡」与「失败提示」渲染的是同一个类型，样式与动画由代码保证一致，不会各改一半。
//  调用点在 `qwq/UI/Shell/RootOverlays.swift`，位置与停留时长也在那里。
//

import SwiftUI

/// Java 环境选择下拉面板（从「选择版本」卡片右上角的按钮弹出）。
/// 第一项恒为「自动选择（推荐）」（id = "auto"，业务上等价于 nil），其后是本机已发现的 Java。
///
/// ⚠️ 本视图**不即时写回** `selectedJavaPath`：点选只改内部 `localSelection`，
/// 面板消失时（onDisappear）才把结果回写 → 中途反复点选不会污染调用方状态。
/// 代价是「面板没关就退出」时选择会丢，因此 onDisappear 的回写必须延迟到渲染事务外执行。
struct JavaPickerView: View {
    /// 调用方的选择（nil = 自动）。本视图只在消失时回写它，见类型文档。
    @Binding var selectedJavaPath: String?
    /// 已发现的 Java 列表来源（`availableJavaList`）。
    @EnvironmentObject var settings: LauncherSettings
    /// ⚠️ 这里是**默认值形式**的 @ObservedObject（单例直接取值），
    /// 与工程里其它视图「由调用方注入 theme」的写法不同 —— 本面板总是从同一个全局单例取。
    @ObservedObject var theme = ThemeManager.shared
    /// 刷新进行中：按钮置灰；列表为空时正文显示转圈。
    @State private var isRefreshing = false
    @State private var refreshRotation: Double = 0
    /// 面板内部的「临时选择」；关闭时才回写给 `selectedJavaPath`。
    @State private var localSelection: String? = nil
    /// 首次 onAppear 已完成初始化的标记 —— 防止面板反复出现时把用户已改的选择重置回外部值。
    @State private var hasInitialized = false
    /// 入场动画起始态（缩小 + 全透明），onAppear 后动画到 1。
    @State private var contentScale: CGFloat = 0.7
    @State private var contentOpacity: Double = 0
    /// 高亮块的滑动目标下标；选中项变化时更新它，动画交给 `.animation(value: highlightOffset)`。
    @State private var selectedIndex: Int = 0
    /// 高亮块的 y 偏移与高度（行高固定 45，+4 是顶部内边距）。
    @State private var highlightOffset: CGFloat = 0
    @State private var highlightHeight: CGFloat = 36
    /// 选项列表快照。
    /// ⚠️ 为什么要缓存而不是每次现算：`availableJavaList` 在刷新期间会**连续多次**变化，
    /// 现算会让列表在动画中抖动；缓存后只在 onAppear / 列表变化时重建一次。
    @State private var cachedOptions: [(id: String, label: String, detail: String)] = []
    
    /// 由设置里的 Java 列表拼出选项（第一项固定是「自动选择」）。
    /// `detail` 显示 Java 的完整路径，因此标签用 `Java <主版本>` 而不是完整版本号 ——
    /// 同主版本的多个发行版（17.0.9 / 17.0.11）标签会长得一样，靠下方的路径区分。
    private func buildOptions() -> [(id: String, label: String, detail: String)] {
        var options: [(id: String, label: String, detail: String)] = [
            (id: "auto", label: "自动选择（推荐）", detail: "启动器自动匹配")
        ]
        for java in settings.availableJavaList {
            options.append((id: java.path, label: "Java \(java.majorVersion)", detail: java.path))
        }
        return options
    }
    
    /// 取选项列表：优先用缓存；缓存为空（还没初始化过）时**当场算一份**，
    /// 保证首帧就有内容可渲染，不会出现「先空一帧再填上」的闪烁。
    private var allOptions: [(id: String, label: String, detail: String)] {
        cachedOptions.isEmpty ? buildOptions() : cachedOptions
    }
    
    // 结构：标题行（含刷新按钮）→ 分隔线 → 三态正文（转圈 / 空态 / 列表）。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Java 环境")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                // 刷新按钮：转圈动画挂在 refreshRotation 上（startRefresh 里 +720°）。
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // 三态正文。第一个分支要求**同时**满足「正在刷新」与「列表为空」——
            // 列表已有内容时刷新不遮挡列表（避免刷新把已经看到的东西藏起来）。
            if isRefreshing && settings.availableJavaList.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(height: 40)
                    Spacer()
                }
            // 非刷新中且确实没有 Java —— 明确写「未找到」，而不是留一个空框。
            } else if settings.availableJavaList.isEmpty && !isRefreshing {
                Text("未找到 Java 环境")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 用 `option.id` 而不是下标做 identity：刷新后 Java 列表可能增删、
                        // 顺序也会变，用下标当键会让 SwiftUI 复用错行。
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
                    // 高亮块画在 overlay 里、靠 offset 位移 —— 与侧边栏同一套做法：
                    // 切换选中项时连续滑动而不是跳变。两个 .animation 分别盯 offset 与 height。
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
    
    /// 手动刷新 Java 列表。
    /// ⚠️ 结束时机由扫描的 completion 驱动（不是动画播完）—— 转圈是 0.8 秒的 720° 双圈，
    /// 若扫描比它慢，图标会停在半路直到扫描结束；这是刻意的：宁可「转完但还在转」，
    /// 也不要在结果出来前就停下、让人误以为已经扫完了。
    private func startRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // 恢复原始非线性旋转（bca7f9e 曾改为 linear 匀速）：ease-out 贝塞尔 720° 双圈，
        // 转完即停在原朝向（720 mod 360 = 0），无需回正动画；结束时机由扫描 completion 驱动
        withAnimation(Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.8)) {
            refreshRotation += 720
        }
        JavaManager.shared.refreshAvailableJavaList {
            self.isRefreshing = false
        }
    }

    /// 「自动」这一项的 id 是字符串 "auto"，但在业务上等价于 `nil` ——
    /// 判等时要做这个转换，别直接拿 id 与 `localSelection` 比。
    private func isOptionSelected(_ id: String) -> Bool {
        if id == "auto" {
            return localSelection == nil
        }
        return localSelection == id
    }
    
    /// 选中某一项：只改内部状态（不写回 Binding），并驱动高亮块滑过去。
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
    
    /// 按当前选择反查下标，用于初始化、以及列表变化后把高亮块摆回正确位置。
    /// ⚠️ 找不到匹配项时**什么都不做** —— 高亮块会停在旧位置，而不是归零到第一项。
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

/// 下拉列表里的一行：两行文字（标签 + 等宽字体的路径），右侧选中打勾。
/// ⚠️ 打勾是「常驻视图 + 透明度切换」而非条件插入 —— 保留占位宽度，
/// 勾出现/消失时文字不会左右平移。
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
                    // 路径用等宽字体 + `.middle` 截断：路径中间才是区分度最高的部分
                    //（所有行的结尾都是 /bin/java），尾部截断会让每行看起来一模一样。
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
        // 分隔线缩进 14pt 对齐文字左边缘；最后一行也会画一条（列表底部因此有收尾线）。
        Divider()
            .padding(.leading, 14)
    }
}