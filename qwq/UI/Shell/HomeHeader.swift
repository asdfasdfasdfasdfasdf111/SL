//
//  HomeHeader.swift
//  主内容区顶部：应用大标题 + 分类 Tab，整体是**一块带间隙的玻璃面板**。
//
//  设计依据（用户要求 + 天气 App 现成配方）：
//  - 玻璃配方**直接抄天气 App 的侧栏**（BetterWeather/View/SideSettings/SideSettingsView.swift）：
//    `RoundedRectangle(cornerRadius:).fill(Color.white.opacity(0.08))` +
//    `.stroke(.white.opacity(0.08), lineWidth: 0.5)`；
//  - 面板四周**留间隙**（不贴窗口边），否则看不到玻璃的边与投影，会读成「一条深色横条」；
//  - 红绿灯要**落在玻璃上**，所以面板从窗口顶端向下留 8pt 开始、左右各留 10pt，
//    并在面板内部先让出 26pt 给红绿灯，标题不会被压住。
//
import SwiftUI

/// 主内容区头部：一块带间隙的玻璃面板，承载应用标题与分类导航。
struct HomeHeader: View {
    /// 当前选中的分类（点击导航项时由 AnimatedCategoryPicker 回写）
    @Binding var selectedCategory: Category
    /// 全部分类（顺序即导航项顺序，与画布横向顺序一致）
    let categories: [Category]

    /// 玻璃圆角（天气 App 侧栏行内小卡用 10，这块面板用 16）。
    private let cornerRadius: CGFloat = 16
    /// 面板内部为系统红绿灯让出的高度（红绿灯位于窗口顶栏约 13–27pt 处）。
    private let trafficLightInset: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 让开红绿灯：面板顶到窗口上沿附近后，标题从这里往下排。
            Color.clear.frame(height: trafficLightInset)

            // 第一行：应用大标题
            HStack {
                Text("SL启动器")
                    .font(.largeTitle.bold())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 14)

            // 第二行：分类导航
            AnimatedCategoryPicker(selectedCategory: $selectedCategory, categories: categories)
                .padding(.horizontal, 12)
                .padding(.bottom, 18)
                .zIndex(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 玻璃：观感照抄天气 App 侧栏（半透明 + 白 8% 细描边），但**基底换成 BlurView**：
        // SwiftUI 的 `.ultraThinMaterial` 默认 `followsWindowActiveState`，窗口被切到后台
        // 会切到「非活跃」外观 —— 用户多次反馈「前台调度收起时毛玻璃会变黑」。
        // `BlurView` 是 NSVisualEffectView 且 `state` 恒为 `.active`，因此前后台外观一致。
        // ⚠️ 用户定稿：毛玻璃**一律极淡**（「透明度调低，能看出来就行」）。
        // 不用任何深色材质 —— 深色模式下 NSVisualEffectView 会把面板压成暗块，
        // 且 SwiftUI 材质还有「失活变黑」的问题。这里只留一层很淡的白 + 细边 + 阴影：
        // 背景渐变能直接透上来，但仍看得出边界与层次。
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        // 浮起投影：与下方内容拉开层次。
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        // 间隙：面板不贴窗口边缘，四边都露出玻璃的边与阴影。
        // ⚠️ 间隙上限受红绿灯位置约束：红绿灯左缘约在 x=15、上缘约 y=11，
        // 面板再往里收就会把它们挤出玻璃外（此前用户要求红绿灯必须落在玻璃上）。
        // 因此左右最多 13pt、顶部最多 10pt；想加强「玻璃感」靠内部留白与投影，而不是继续收边。
        .padding(.horizontal, 13)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}
