//
//  VersionPickerCard.swift
//  模块化拆分：从 GameCategoryView 拆出「版本选择卡片」组件，
//  含版本列表（或未找到提示）+ 右上角 Java 选择 popover + 底部「添加文件夹/全盘查找游戏」按钮。
//  纯展示组件：状态（selectedJavaPath）@Binding 外置，行为（onSelect/onOpenFolderPicker/onFullDiskScan）回调外置。
//

//
//  VersionPickerCard.swift
//  模块化拆分：从 GameCategoryView 拆出「版本选择卡片」组件，
//  含版本列表（或未找到提示）+ 右上角 Java 选择 popover + 底部「添加文件夹/全盘查找游戏」按钮。
//  纯展示组件：状态（selectedJavaPath）@Binding 外置，行为（onSelect/onOpenFolderPicker/onFullDiskScan）回调外置。
//
//  ⚠️ 两处按钮含义不同，别混淆：
//    右上角 popover 按钮 —— 选**用哪个 Java 跑游戏**（仅在有版本时出现）；
//    底部两个按钮       —— 找不到游戏时的手动补救（加目录 / 全盘扫），是否出现由 showBottomButtons 决定。
//

import SwiftUI

/// 版本选择卡片：居中的浮层面板，纵向排列所有版本号按钮。
struct VersionPickerCard: View {
    /// 主题来源由调用方注入；本视图读取 accentColor，故订阅其变化
    @ObservedObject var theme: ThemeManager
    /// 可选版本号列表（调用方已排好序）。本视图不排序、不去重。
    let versions: [String]
    /// ⚠️ 它与 `versions.isEmpty` 语义**不完全等价**：由调用方给，用来区分
    /// 「确实一个版本都没扫到」（走空态引导文案）与其它中间情形。
    let hasVersions: Bool
    /// 当前选中的版本号。
    let selectedVersion: String
    /// Java 选择按钮上的文案（如 `Java 17` / `未选择 Java`），由调用方算好。
    let javaPickerLabel: String
    /// 是否显示底部的「添加文件夹 / 全盘查找游戏」——由调用方按场景开关。
    let showBottomButtons: Bool
    @Binding var selectedJavaPath: String?
    let onSelect: (String) -> Void
    let onOpenFolderPicker: () -> Void
    let onFullDiskScan: () -> Void

    /// 设置注入给 popover 里的 JavaPickerView（它需要读写已添加的 Java 列表）。
    @EnvironmentObject var settings: LauncherSettings
    /// 控制右上角 Java 选择 popover 的展开，仅本视图内部使用。
    @State private var showJavaPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    // 两条互斥分支：有版本 → 列表；无版本 → 空态引导。
                    if hasVersions {
                        // 标题 = **游戏目录名**（用户要求：原来写死的「选择游戏版本」改成目录名），
                        // 双击可就地编辑，提交后**真实重命名磁盘上的目录**。
                        GameFolderTitle()
                            .padding(.bottom, 6)

                        ScrollView(.vertical, showsIndicators: false) {
                            // 每个版本一个**小方块**：上面名称、下面加载器图标（白色单色）。
                            // 列宽自适应：锁窗 800×560 下每行 5~6 个方块。
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 104, maximum: 124), spacing: 14)],
                                spacing: 14
                            ) {
                                ForEach(versions, id: \.self) { version in
                                    VersionTile(
                                        title: version,
                                        loaderIcon: Self.loaderIconName(for: version),
                                        isSelected: selectedVersion == version
                                    ) {
                                        onSelect(version)
                                    }
                                }
                            }
                            // 方块按下放大 8%，四周各溢出约 4pt；16pt 横向余量足够（不再出现被裁）。
                            .padding(.horizontal, 16)
                            // 纵向留白(12pt) > 过渡带宽度(约 10pt)：方块不落在淡出区里。
                            .padding(.vertical, 12)
                        }
                        // 上下渐变过渡：滚动边界不硬切方块（用户要求「过渡条」），
                        // 只作用于列表自身高度内，不会盖住下方按钮区。
                        .mask(
                            LinearGradient(
                                // ⚠️ 过渡必须**收得很窄**：此前 5%（约 21pt）会把第一排方块也淡掉，
                                // 用户反馈「过渡线直接影响了这个小方块」。现在只淡最边缘约 10pt，
                                // 方块再由下方 padding 让开这段区域，因此方块本身不被过渡影响。
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black, location: 0.022),
                                    .init(color: .black, location: 0.978),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(maxHeight: 420)
                    } else {
                        // 空态：一句「为什么找不到」+ 一句「怎么办」，再给一个按钮。
                        VStack(spacing: 20) {
                            Text("未找到游戏版本").font(.headline).foregroundColor(.secondary)
                            Text("请将 Minecraft 游戏文件夹（包含 versions 目录）放入常用目录（文稿、下载等），或手动选择")
                                .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                            Button(action: onOpenFolderPicker) {
                                Text("寻找版本")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                    .frame(width: 160, height: 40)
                                    .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.08)).shadow(radius: 2))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 12)
                    }
                }
                .padding(24)
                .frame(minWidth: 280)
                // 透明玻璃（此前 `.regularMaterial` 在深色模式下是暗灰，压在渐变上发黑）
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
                )
                // 右上角 Java 选择入口。没有版本时不出现 —— 没版本可跑，选 Java 没意义。
                .overlay(alignment: .topTrailing) {
                    if hasVersions {
                        Button(action: { showJavaPicker = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "cup.and.saucer.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.accentColor)
                                Text(javaPickerLabel)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        // arrowEdge: .trailing 让气泡箭头指向右侧按钮，视觉上说明「从哪弹出来的」。
                        .popover(isPresented: $showJavaPicker, arrowEdge: .trailing) {
                            JavaPickerView(selectedJavaPath: $selectedJavaPath)
                                .environmentObject(settings)
                        }
                        .padding([.top, .trailing], 10)
                    }
                }
                Spacer()
            }
            // 底部补救区：两个按钮都只调外部回调，本视图不自己做任何目录操作。
            if showBottomButtons {
                VStack(spacing: 8) {
                    Button(action: onOpenFolderPicker) {
                        Text("添加文件夹")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.accentColor, lineWidth: 1)
                                    .background(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)
                    // 「全盘查找」做成下划线小字，是刻意的弱化 —— 它是重操作（真扫全盘），
                    // 不该被误当成主操作点。
                    Button(action: onFullDiskScan) {
                        Text("全盘查找游戏")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }
}


// MARK: - 版本方块与目录名标题

extension VersionPickerCard {
    /// 由版本名推断加载器图标（版本名遵循「主版本-加载器」约定，见 VersionUtils 的重命名规则）。
    /// NeoForge 必须先判：它的名字里含 "forge"，否则会误判成 Forge。
    static func loaderIconName(for version: String) -> String? {
        let v = version.lowercased()
        if v.contains("neoforge") { return "LoaderNeoForge" }
        if v.contains("forge") { return "LoaderForge" }
        if v.contains("fabric") { return "LoaderFabric" }
        if v.contains("quilt") { return "LoaderQuilt" }
        return nil
    }
}

/// 单个版本方块：上方版本名、下方加载器图标（白色单色），玻璃底。
/// 图标资源见 Assets.xcassets/Loader*.imageset —— 已统一处理为「白 + alpha」，
/// Forge 额外抠掉了黑色底（原图无透明通道）。
private struct VersionTile: View {
    let title: String
    let loaderIcon: String?
    let isSelected: Bool
    let onTap: () -> Void

    @State private var animationScale: CGFloat = 1.0
    /// 计数变化才能让每次点击都重启回弹计时，且随视图销毁自动取消（无不可取消闭包）。
    @State private var clickCount = 0

    var body: some View {
        Button(action: {
            // 与旧 `VersionButton` 逐字一致的手感：先弹到 1.08 给即时反馈，再执行动作。
            withAnimation(.bouncySpring) { animationScale = 1.08 }
            onTap()
            clickCount += 1
        }) {
            VStack(spacing: 10) {
                // 上面：名称
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)

                // 下面：加载器图标（白色单色）。无加载器（原版）时给一个中性方块符号。
                if let loaderIcon {
                    Image(loaderIcon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        // 宽字标（FORGE 长宽比 5.9:1）需要**按宽度**给空间，只给高度会让它极小。
                        .frame(maxWidth: 84, maxHeight: 34)
                        .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.8))
                } else {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: 84, maxHeight: 34)
                }
            }
            .frame(width: 116, height: 106)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(animationScale)
        // 回弹：点击后 0.12s 复位到 1.0。`.task(id:)` 在计数变化时重启、视图销毁时取消。
        .task(id: clickCount) {
            guard clickCount > 0 else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.bouncySpring) { animationScale = 1.0 }
        }
    }
}

/// 游戏目录名标题：双击就地编辑，提交后真实重命名磁盘目录并更新设置里的路径。
private struct GameFolderTitle: View {
    @ObservedObject private var settings = LauncherSettings.shared
    @State private var isEditing = false
    @State private var draft = ""
    @State private var errorText: String?
    @FocusState private var focused: Bool

    /// 当前目录名（路径的最后一段）。
    private var folderName: String {
        let path = settings.selectedGameRoot
        guard !path.isEmpty else { return "未选择游戏目录" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                TextField("目录名", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(width: 220)
                    .focused($focused)
                    .onSubmit { commit() }
                Button("取消") { isEditing = false; errorText = nil }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(folderName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("双击可改名")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.red)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draft = folderName
            isEditing = true
            errorText = nil
            DispatchQueue.main.async { focused = true }
        }
    }

    /// 真实重命名：在同级目录下改名，成功后把设置里的路径指过去。
    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = URL(fileURLWithPath: settings.selectedGameRoot)
        guard !name.isEmpty, !name.contains("/"), name != folderName else {
            isEditing = false
            return
        }
        let new = old.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: new.path) else {
            errorText = "同名目录已存在"
            return
        }
        do {
            try FileManager.default.moveItem(at: old, to: new)
            settings.selectedGameRoot = new.path
            isEditing = false
            errorText = nil
        } catch {
            errorText = "改名失败：\(error.localizedDescription)"
        }
    }
}
