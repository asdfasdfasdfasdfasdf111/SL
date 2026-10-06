//
//  HomeHeader.swift
//  主内容区顶部：应用大标题 + 分类 Tab，整体是**一块顶格的毛玻璃工具栏**。
//
//  设计目标（用户要求）：
//  ① 顶格 —— 面板贴到窗口最上沿、横跨整个窗口宽度，把**红绿灯（关闭/最小化/缩放）包在里面**
//     （macOS 系统工具栏就是这个形态；之前做成悬浮小卡片、红绿灯在面板外，用户评价「很丑、没顶格」）。
//  ② 毛玻璃要看得出来、且与内容区有层次（阴影 / 高光边），不能是一块黑条。
//  ③ 窗口被切到后台时不能发黑。
//
//  ⚠️ 走过的弯路与结论（勿重复）：
//  ① `BlurView(.contentBackground)` 贴底 → 观感是「不透明的条」。
//  ② SwiftUI `.regularMaterial` + 阴影 → 材质太浅；**且窗口失活时会切到「非活跃」外观而发黑**
//     （SwiftUI 材质默认 `followsWindowActiveState`，系统组件不这样）。
//  ③ 全透明 → 用户要求「要一整块圆角毛玻璃」。
//  ④ 悬浮小卡片（四周留边距）→ 红绿灯落在面板外，用户评价「很丑、没顶格」。
//  现在：顶格面板 + `NSVisualEffectView`（`state` 恒为 `.active`，失活不发黑）。
//
//  材质说明（HIG《Materials》）：`Choose materials and effects based on semantic meaning and
//  recommended usage.` —— 顶栏语义是窗口 header；本项目取 `.underWindowBackground`
//  （最透的一档），为的是让底下的暖色渐变透上来，形成「玻璃」而不是「黑条」的观感。
//  另注：本项目部署目标 macOS 13.0，**不能**使用 macOS 26 的 Liquid Glass API。
//
import SwiftUI

/// 主内容区头部：顶格毛玻璃工具栏，承载应用标题与分类导航。
struct HomeHeader: View {
    /// 当前选中的分类（点击导航项时由 AnimatedCategoryPicker 回写）
    @Binding var selectedCategory: Category
    /// 全部分类（顺序即导航项顺序，与画布横向顺序一致）
    let categories: [Category]

    /// 面板**下沿**圆角。上沿不设圆角：面板顶格，上缘就是窗口自己的圆角。
    private let bottomCornerRadius: CGFloat = 18

    /// 面板形状：上沿直角（与窗口顶边重合）、下沿连续圆角。
    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomCornerRadius,
            bottomTrailingRadius: bottomCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 第一行：应用大标题，左侧对齐
            // 顶部不额外让位：红绿灯由系统画在标题栏区（SwiftUI 安全区顶部内边距）内，
            // 内容天然落在红绿灯下方；玻璃背景则由下面的 `ignoresSafeArea(edges: .top)`
            // 顶到窗口最上沿，把红绿灯包进面板里。
            HStack {
                Text("SL启动器")
                    .font(.largeTitle.bold())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 第二行：分类导航靠左对齐
            AnimatedCategoryPicker(selectedCategory: $selectedCategory, categories: categories)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .zIndex(20)
        }
        // 玻璃面板：顶格、满宽。用工程自己的 BlurView（NSVisualEffectView）：
        // `state` 恒为 `.active`，因此窗口切到后台也不会发黑（SwiftUI 材质会）。
        // `ignoresSafeArea(edges: .top)` 是「顶格」的关键：背景向上扩到窗口上沿，
        // 而文本内容仍位于安全区内，于是红绿灯恰好落在玻璃上。
        .background(
            BlurView(material: .underWindowBackground, blendingMode: .withinWindow)
                .clipShape(panelShape)
                .ignoresSafeArea(edges: .top)
        )
        // 玻璃高光边：让它读起来是「一块玻璃」而不是一块色块（下沿与两侧可见）。
        .overlay(
            panelShape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                .ignoresSafeArea(edges: .top)
        )
        // 悬浮投影：与下方内容区拉开层次（面板外沿投影，顶部被窗口裁掉，只见下沿）。
        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
    }
}
