//
//  SupportedMetaSection.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 内「版本范围 + 加载器图标行」块）
//  纯视图组件：详情页「支持版本范围 + 加载器图标」元信息区——标题（支持的游戏版本）、
//  版本范围文本（空则不显示）、过滤后的加载器图标行（空则不显示），
//  加载器资源名解析走 LoaderNameResolver，纯展示无状态。
//

import SwiftUI

/// 详情页「支持版本范围 + 加载器图标」元信息区
struct SupportedMetaSection: View {
    let title: String
    let rangeText: String
    let filteredLoaders: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            if !filteredLoaders.isEmpty {
                HStack(spacing: 16) {
                    ForEach(filteredLoaders, id: \.self) { loader in
                        Image(LoaderNameResolver.assetName(for: loader))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 28)
                            .cornerRadius(6)
                            .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
