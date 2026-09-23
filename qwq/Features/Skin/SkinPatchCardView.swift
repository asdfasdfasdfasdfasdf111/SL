//
//  SkinPatchCardView.swift
//  高清皮肤补丁（CustomSkinLoader）询问卡片
//
//  出现时机：用户在启动页选了一张**原版不支持、但属于整倍数**的皮肤尺寸（如 128×128），
//  且 `SkinPatchCoordinator` 已向 Modrinth 查过适配当前「游戏版本 + 加载器」的补丁。
//
//  职责边界：本视图是**纯展示组件** —— 只订阅 `coordinator.state` 渲染，
//  不查网络、不读 `LauncherSettings`、不拼文案（文案在 `SkinPatchCopy`）。
//  状态迁移与副作用全在 `SkinPatchCoordinator`；本视图唯一的自身状态是入场动画与按下反馈。
//
//  视觉语言刻意**向加载器选择卡对齐**（见 GameCards.swift 的 `LoaderSelectorCard`）：
//  圆角 16 + `secondary 6%` 底 + 选中态 accent 描边高光。用户要求这张卡片"要有高光，
//  就是选择加载器点中之后那种高光" —— 于是高光不是装饰，而是复用同一套视觉词汇。
//

import SwiftUI

/// 高清皮肤补丁询问卡片。
///
/// 布局（用户逐条指定，勿擅自调整）：
/// 1. **圆角矩形、横长方形** —— 固定宽 460、高随内容自适应，即「左右两条边是短边」；
/// 2. 自上而下：**标题** → **正文段落** → **分隔线** → **右下角按钮**；
/// 3. 正文段落 **首行缩进两个全角空格、左对齐**（缩进已由 `SkinPatchCopy` 在字符串开头拼好，
///    本视图直接渲染字符串即可，**不要**再用 padding/offset 去模拟缩进）；
/// 4. 高光**只在真的能点（`state.canInstall`）时点亮** —— 否则满屏高光就退化成纯装饰了。
struct SkinPatchCardView: View {

    /// 状态机与副作用编排者。本视图**只读** `state`，改写一律经它的方法。
    @ObservedObject var coordinator: SkinPatchCoordinator
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值。
    @ObservedObject var theme: ThemeManager

    /// 入场动画开关：初值 false（缩放 0.85 + 全透明），`onAppear` 之后置 true 触发弹入。
    /// ⚠️ 初值必须为 false，否则没有可动画的起始态。
    @State private var showContent: Bool = false
    /// 右下角按钮的按下反馈缩放（1.0 ↔ 1.06），纯反馈、与状态无关。
    @State private var actionScale: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── 上半：图标 +（标题 / 正文）。`.top` 对齐让图标与标题首行齐平
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(iconColor)
                    // 固定宽度：各状态图标宽窄不一（系统图标画幅不同），不锁宽会让正文左右抖动
                    .frame(width: 34, height: 34, alignment: .center)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(SkinPatchCopy.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer(minLength: 8)
                        // 关闭按钮恒在（右上角）—— 任何状态都必须能退出这张卡片
                        Button(action: { coordinator.dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // 正文：缩进已在字符串里，这里只保证**左对齐 + 可换行 + 不被截断**。
                    // ⚠️ `multilineTextAlignment(.leading)` 是必需的：用户给的参考图里这段是居中的，
                    // 而他明确说"不是像我这样居中摆放的" —— 中文正文的常规写法就是顶格起、首行缩进两格。
                    Text(bodyText)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        // 不设行数上限 + fixedSize：长文案必须完整显示，宁可把卡片撑高也不截断
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            // ── 分隔线：贯穿整卡宽度（用户指定的「后面行分格线」），把正文与操作区分开
            Divider()

            // ── 下半：操作区。按钮推到**右下角**
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actionArea
            }
        }
        .padding(20)
        // 横长方形：宽度定死、高度随内容。460 与下载页弹窗（420）同量级，启动页放得下
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 16)
                // 用材质而非纯色：这张卡片浮在启动页任意内容之上，材质能保证任何底色下都可读
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        )
        // **高光**：与 `LoaderSelectorCard` 的选中态同一套写法（accent 描边 2pt）。
        // 只在 `canInstall` 时点亮；其余状态给一条极淡的中性描边，保证卡片边界在任何底色下都看得见。
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(coordinator.state.canInstall ? theme.accentColor : Color.white.opacity(0.08),
                        lineWidth: coordinator.state.canInstall ? 2 : 0.5)
        )
        .scaleEffect(showContent ? 1 : 0.85)
        .opacity(showContent ? 1 : 0)
        .onAppear {
            // ⚠️ onAppear 处于视图更新事务中，同步写 @State 会触发
            // "Modifying state during view update"（本工程历史上因此崩过，UAF 前兆）——
            // 一律 dispatch 到主队列下一个 tick 再写。
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    showContent = true
                }
            }
        }
    }

    // MARK: - 正文

    /// 当前状态对应的正文段落。
    ///
    /// ⚠️ 只有前三态（checking / available / noPatch / noLoader / noVersion / failed）走
    /// `SkinPatchCopy`；安装过程的三态（installing / installed / installFailed）是本视图的临时进度
    /// 反馈，没有独立的文案函数 —— 但仍然复用 `SkinPatchCopy.indent`，
    /// 免得这段文字与其它段落出现「有的缩进有的不缩进」的参差。
    private var bodyText: String {
        switch coordinator.state {
        case .hidden:
            return ""
        case .checking:
            return SkinPatchCopy.checkingBody()
        case .available(let patch, let pixelSize, let gameVersion, let loader):
            return SkinPatchCopy.availableBody(pixelSize: pixelSize, patch: patch,
                                               gameVersion: gameVersion, loader: loader)
        case .noPatch(let pixelSize, let gameVersion, let loader):
            return SkinPatchCopy.noPatchBody(pixelSize: pixelSize, gameVersion: gameVersion, loader: loader)
        case .noLoader(let pixelSize, let gameVersion):
            return SkinPatchCopy.noLoaderBody(pixelSize: pixelSize, gameVersion: gameVersion)
        case .noVersion:
            return SkinPatchCopy.noVersionBody()
        case .failed(let pixelSize, let reason):
            return SkinPatchCopy.queryFailedBody(pixelSize: pixelSize, reason: reason)
        case .installing(_, let versionNumber):
            return SkinPatchCopy.indent
                + "正在下载并安装补丁 \(versionNumber)…下载完成后会自动放入该版本的 mods 目录。"
        case .installed(_, let filename):
            return SkinPatchCopy.indent
                + "补丁已安装：\(filename)。重新启动游戏后即可加载 \(SkinPatchCopy.vanillaSizeHint) 以外的皮肤尺寸。"
        case .installFailed(_, let reason):
            return SkinPatchCopy.indent + "补丁安装失败：\(reason)"
        }
    }

    // MARK: - 图标

    /// 各状态的图标。
    /// ⚠️ 刻意**不**按状态换标题（标题恒为「检测到高清皮肤」）—— 标题回答的是「这张卡片为什么出现」，
    /// 而状态之间的差别由正文与图标承担；换标题会让用户以为遇到了另一种问题。
    private var iconName: String {
        switch coordinator.state {
        case .available:
            return "paintbrush.pointed.fill"
        case .checking, .installing:
            return "arrow.triangle.2.circlepath"
        case .installed:
            return "checkmark.seal.fill"
        case .failed, .installFailed:
            return "exclamationmark.triangle.fill"
        case .noPatch, .noLoader, .noVersion:
            return "info.circle.fill"
        case .hidden:
            return "paintbrush.pointed.fill"
        }
    }

    /// 图标颜色：可安装跟随主题色（与高光一致），成功绿、失败红、需知会橙、中性灰。
    private var iconColor: Color {
        switch coordinator.state {
        case .available:
            return theme.accentColor
        case .installed:
            return .green
        case .failed, .installFailed:
            return .red
        case .noPatch, .noLoader, .noVersion:
            return .orange
        case .checking, .installing, .hidden:
            return .secondary
        }
    }

    // MARK: - 操作区（右下角）

    /// 按状态分派右下角控件。
    ///
    /// ⚠️ `.available` 之外**不渲染**「下载」按钮：能装的只有那一种状态。
    /// `.installing` / `.checking` 用进度指示 + 禁用代替按钮，避免用户重复点。
    @ViewBuilder
    private var actionArea: some View {
        switch coordinator.state {
        case .available:
            Button(action: {
                // 按下反馈：先放大再复位。与其它卡片一致用 `.punchySpring`，不另创动画参数。
                withAnimation(.punchySpring) { actionScale = 1.06 }
                coordinator.install()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.punchySpring) { actionScale = 1.0 }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("下载")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(width: 96, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
            }
            .buttonStyle(.plain)
            .scaleEffect(actionScale)

        case .checking, .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(activityLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

        case .installed:
            // 完成态仍给一个按钮（而不是自动消失）：让用户自己确认这一步做完了，
            // 而不是卡片悄悄消失、用户没看清结果。
            Button(action: { coordinator.dismiss() }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                    Text("完成")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(width: 96, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
            }
            .buttonStyle(.plain)

        default:
            // 其余状态（noPatch / noLoader / noVersion / failed / installFailed / hidden）：
            // 无事可做，只给退出。用弱化样式，视觉上不与「下载」抢注意力。
            Button(action: { coordinator.dismiss() }) {
                Text("关闭")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 96, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
        }
    }

    /// 进度文案（查询中 / 安装中）。
    private var activityLabel: String {
        if case .installing = coordinator.state { return "安装中…" }
        return "正在查询…"
    }
}
