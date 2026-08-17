import SwiftUI

/// 分类画布切换时的中间页占位视图。
/// 从分类 1 切到 5 时，动画会真实经过 2、3、4 的位置——这些中间页只渲染
/// 「图标 + 名称」的轻量占位（纯静态视图，零数据加载、零网络请求），
/// 保证「整页滑过的动画感」与「后台不同时实例化 5 个完整页面」两者兼得。
struct CategoryCanvasPlaceholder: View {
    let category: Category
    @ObservedObject var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(theme.accentColor.opacity(0.35))
                Text(category.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .background(
            BlurView(material: .fullScreenUI, blendingMode: .behindWindow)
                .opacity(0.35)
        )
        .allowsHitTesting(false)
    }
}
