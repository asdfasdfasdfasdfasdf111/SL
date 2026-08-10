//
//  ShaderPrerequisiteSection.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 shaderPrerequisiteSection 计算属性）
//  纯视图组件：光影详情页的「必要光影加载器」固定提示卡（Sodium / Iris 两张前置模组卡），
//  点击回调由外部注入（跳转前置模组详情），不持有任何导航/状态逻辑。
//

import SwiftUI

/// 光影详情页前置加载器提示区块（Sodium / Iris 两张固定卡）
struct ShaderPrerequisiteSection: View {
    let onSelect: (DownloadedItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("光影必要的光影加载器（启动运行后起效）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    PrerequisiteModCard(
                        item: DownloadedItem(id: "AANobbMI", name: "Sodium", subtitle: "性能优化模组", iconURL: nil, tags: [])
                    ) {
                        onSelect(DownloadedItem(id: "AANobbMI", name: "Sodium", subtitle: "现代渲染引擎优化模组", iconURL: nil, tags: []))
                    }
                    PrerequisiteModCard(
                        item: DownloadedItem(id: "YL57xq9U", name: "Iris", subtitle: "光影加载器", iconURL: nil, tags: [])
                    ) {
                        onSelect(DownloadedItem(id: "YL57xq9U", name: "Iris", subtitle: "兼容Sodium的光影加载器", iconURL: nil, tags: []))
                    }
                }
            }
        }
    }
}
