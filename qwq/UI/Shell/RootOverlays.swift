//
//  RootOverlays.swift
//  模块化收口：把根视图 ZStack 里的顶层叠加层（任务气泡与失败气泡、两个安装弹窗、
//  拖拽高亮、全局圆形下载按钮）合成到一处，ContentView 只保留「主内容 + 叠加层」两级结构。
//
//  叠加约束：
//  1. 本视图必须作为 ContentView 根 ZStack 中 mainContent 之后的兄弟节点使用。
//     两者 zIndex 均为默认 0，靠声明顺序决定上下关系；若调换位置，全部叠加层会落到
//     主内容之下，等同于界面失效。
//  2. 各叠加层之间的 zIndex 取值（40 / 100 / 150 / 200 / 300）与声明顺序按原实现逐字保留，
//     层级关系为：主内容 < 圆形按钮(40) < 任务/失败气泡(100 / 300) < 拖拽高亮(150)
//     < 安装弹窗(200)。改动数值或顺序即改变遮挡关系，属于视觉变更。
//     （两颗气泡共用同一锚点，正常情况下不会同时出现；万一同时出现，失败提示在上。）
//  3. 气泡锚点 `pillAnchor`（450, 200）以本视图左上角为坐标原点。本视图尺寸与
//     原根 ZStack 一致（各叠加层中自带铺满容器者），故坐标语义不变。
//

import SwiftUI

/// 根视图顶层叠加层。
///
/// 状态来源全部由外部注入：气泡与启动提示取 LaunchPanelState，安装弹窗取
/// DropInstallCoordinator，拖入高亮取 HomeInteractionState，圆按钮与详情页开关取
/// NavigationState。本视图不持有状态、不复制状态，仅按各状态渲染并转发事件。
struct RootOverlays: View {

    /// 启动相关界面状态（任务气泡与失败气泡的文案与开关）
    @ObservedObject var launchPanel: LaunchPanelState
    /// 拖拽安装协调器（两个安装弹窗的开关与数据）
    @ObservedObject var dropInstall: DropInstallCoordinator
    /// 根视图交互状态（文件拖入高亮）
    @ObservedObject var interaction: HomeInteractionState
    /// 导航状态（圆形下载按钮的可见性与弹入动画）
    @ObservedObject var navigation: NavigationState

    var body: some View {
        ZStack {
            // 任务状态气泡（下载开始 / 安装中 / 下载完成 / Java 选择）：
            // 固定出现在窗口左上区域，位置为绝对值，不随页面切换变化
            TaskPill(message: launchPanel.javaPopupMessage, isPresented: $launchPanel.showJavaPopup)
                .position(x: Self.pillAnchor.x, y: Self.pillAnchor.y)
                .zIndex(100)

            // 模组安装目标选择弹窗
            if dropInstall.showModInstallSheet {
                ModInstallSelectionView(
                    modName: dropInstall.pendingModName,
                    modVersion: dropInstall.pendingModVersion,
                    instances: dropInstall.modInstallInstances,
                    onConfirm: { selected in
                        dropInstall.confirmModInstall(instances: selected)
                    },
                    onCancel: {
                        dropInstall.cancelModInstall()
                    }
                )
                .zIndex(200)
            }

            // 整合包安装位置选择弹窗
            if dropInstall.showModpackInstallSheet {
                ModpackFolderPickerView(
                    packName: dropInstall.pendingModpackName,
                    onConfirm: { folderURL in
                        dropInstall.confirmModpackInstall(folderURL: folderURL)
                    },
                    onCancel: {
                        dropInstall.cancelModpackInstall()
                    }
                )
                .zIndex(200)
            }

            // 文件拖入窗口时的整窗高亮边框；不参与命中测试，避免拦截拖拽落点
            if interaction.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(ThemeManager.shared.accentColor, lineWidth: 3)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(ThemeManager.shared.accentColor.opacity(0.08))
                    )
                    .padding(8)
                    .allowsHitTesting(false)
                    .zIndex(150)
            }

            // 圆形毛玻璃下载按钮：全局顶层（对标 PCL.Mac installTaskButtonOverlay），
            // 任何页面可见可点；点击 toggle 进/出详情页（无返回键，再次点击回到刚才的页面）。
            // zIndex(40) 高于详情页(30)：详情页打开时按钮仍可见可点。
            if navigation.isDownloadCircleVisible {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 15, y: 6)

                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                }
                .scaleEffect(navigation.downloadCircleScale)
                .opacity(navigation.downloadCircleOpacity)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(40)
                .onTapGesture {
                    // 动画由 DownloadDetailManager.toggle 内部统一触发（弹簧曲线）
                    navigation.toggleDownloadDetail()
                }
            }
            // 启动 / 下载失败提示：与上面那颗任务气泡**同一个类型、同一个锚点、同一套入场退场动画**，
            // 唯一的差异是停留时长（1.5s → 6s，见下方 mistakePillDuration）。
            //
            // 为什么不再用系统 `.alert`：那是 macOS 原生模态，与界面整体的毛玻璃语言不搭；
            // 且用户对「发生了一件事」已经有一个熟悉的形状，界面里只该有一种。
            //
            // zIndex(300) 高于既有全部叠加层（安装弹窗 200）：失败提示不能被子层盖住。
            // 正文非空是硬条件——`showLaunchAlert` 与 `launchErrorMessage` 由两个入口分别写，
            // 只开开关而没正文时画出来会是一颗空药丸。
            TaskPill(
                message: launchPanel.launchErrorMessage ?? "",
                isPresented: Binding(
                    get: { launchPanel.showLaunchAlert && launchPanel.launchErrorMessage != nil },
                    set: { if !$0 { launchPanel.dismissError() } }
                ),
                duration: Self.mistakePillDuration
            )
            .position(x: Self.pillAnchor.x, y: Self.pillAnchor.y)
            .zIndex(300)
        }
    }

    /// 药丸锚点（以本视图左上角为坐标原点）。
    /// 两个入口共用：同一件事发生时，它出现在屏幕上的同一个地方，用户不需要重新找。
    private static let pillAnchor: CGPoint = .init(x: 450, y: 200)

    /// 失败提示的停留时长。与 `TaskPill` 的默认值（1.5s，任务状态气泡的历史行为）不同：
    /// 失败提示通常是用户能看到的**唯一**失败原因，1.5s 一闪而过等于没提示。
    /// 这是两个入口之间唯一的差异，样式与动画完全共用。
    private static let mistakePillDuration: TimeInterval = 6
}
