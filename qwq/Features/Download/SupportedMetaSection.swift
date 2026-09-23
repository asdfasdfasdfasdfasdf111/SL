//
//  SupportedMetaSection.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 内「版本范围 + 加载器图标行」块）
//  纯视图组件：详情页「支持版本范围 + 加载器图标」元信息区——标题（支持的游戏版本）、
//  版本范围文本（空则不显示）、过滤后的加载器图标行（空则不显示），
//  加载器资源名解析走 LoaderNameResolver，纯展示无状态。
//

import SwiftUI

/// 详情页「支持版本范围 + 加载器图标」元信息区。
///
/// 三个入参都是**已经算好的结果**：本视图不做任何过滤或解析，
/// `filteredLoaders` 必须由调用方先过滤好（空数组 = 整行不渲染）。
/// 这样视图本身无状态、可直接预览，也不怕数据源变化。
struct SupportedMetaSection: View {
    let title: String
    /// 版本范围文案（如 `1.20.x - 1.21.x`）。**空串表示整块不显示**，而不是显示一个空标题。
    let rangeText: String
    /// 已过滤的加载器名列表（如 `["fabric", "forge"]`）。空数组时整行隐藏。
    let filteredLoaders: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 空文案整块不渲染 —— 避免留下一个「只有标题」的孤儿区块。
            if !rangeText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(rangeText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
            // 同理：没有任何加载器时不占位，下方内容自然上移，不留空档。
            if !filteredLoaders.isEmpty {
                // 横向滚动且不显示滚动条：加载器可能有七八个，超出宽度时靠拖动查看。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(filteredLoaders, id: \.self) { loader in
                            // 资源名解析统一走 LoaderNameResolver —— 视图层不自己拼资源名，
                            // 解析规则变化时只需改那一处。
                            Image(LoaderNameResolver.assetName(for: loader))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 28)
                                .cornerRadius(6)
                                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
