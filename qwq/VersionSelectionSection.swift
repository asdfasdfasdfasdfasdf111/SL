//
//  VersionSelectionSection.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 内联的「版本/加载器选择区块」）
//  纯视图组件：按详情页类型渲染版本卡片 / 加载器卡片 / 整合包版本分组网格，
//  选择状态 @Binding 外置（selectedVersion / selectedLoader / selectedModpackVersionId），
//  不含任何网络、缓存与磁盘副作用，加载器名解析走 LoaderNameResolver。
//

import SwiftUI

/// 详情页「选择版本/加载器」区块：渲染并交互三类选择器
struct VersionSelectionSection: View {
    @ObservedObject var theme = ThemeManager.shared

    let pageType: DetailPageType
    let sortedVersions: [String]
    let availableLoaders: [String]
    let uniqueVersions: [(gameVersion: String, version: ModpackVersion)]
    let projectLoaders: [String]
    let localVersionLoaders: [String: ModLoader]
    let isLoadingModpackVersions: Bool
    let isLoadingLoaders: Bool

    @Binding var selectedVersion: String
    @Binding var selectedLoader: String
    @Binding var selectedModpackVersionId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pageType.titleText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            if pageType == .modpack {
                modpackGrid
            } else if pageType == .loaderSelector {
                loaderSelectorList
            } else {
                versionCardList
            }
        }
    }

    // MARK: - 整合包版本分组网格（每 4 个一行）

    private var modpackGrid: some View {
        Group {
            if isLoadingModpackVersions {
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 12) {
                        let chunkSize = 4
                        let rows = stride(from: 0, to: uniqueVersions.count, by: chunkSize).map {
                            Array(uniqueVersions[$0..<min($0 + chunkSize, uniqueVersions.count)])
                        }
                        ForEach(rows.indices, id: \.self) { rowIdx in
                            HStack(spacing: 12) {
                                ForEach(rows[rowIdx], id: \.gameVersion) { item in
                                    VersionLoaderCard(
                                        version: item.gameVersion,
                                        isSelected: selectedModpackVersionId == item.version.id,
                                        loader: LoaderNameResolver.assetName(for: item.version.loaders.first ?? "fabric")
                                    ) {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                            selectedModpackVersionId = item.version.id
                                            selectedVersion = item.gameVersion
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .scrollBounceIfAvailable()
            }
        }
    }

    // MARK: - 加载器选择卡片（游戏版本页）

    private var loaderSelectorList: some View {
        Group {
            if isLoadingLoaders {
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if availableLoaders.isEmpty {
                Text("该版本暂无可用的加载器")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(availableLoaders, id: \.self) { loader in
                            LoaderSelectorCard(
                                loader: loader,
                                isSelected: selectedLoader == loader
                            ) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                    // 再点已选中的卡片 = 取消选中（不装加载器，下载纯原版）
                                    selectedLoader = (selectedLoader == loader) ? "" : loader
                                }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - 普通版本卡片列表（模组/光影/资源包）

    private var versionCardList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(sortedVersions, id: \.self) { version in
                    VersionLoaderCard(
                        version: version,
                        isSelected: selectedVersion == version,
                        loader: assetName(for: projectLoaderName(for: version))
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                            selectedVersion = version
                        }
                    }
                }
            }
            // 水平方向预留放大动画空间（scaleEffect 1.08 放大时最左/最右卡片不被裁剪）
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    /// 版本卡片加载器名：项目声明的加载器优先，其次按版本匹配本地已装加载器
    private func projectLoaderName(for version: String) -> String {
        projectLoaders.first ?? LoaderNameResolver.name(
            forVersion: version,
            localLoaders: localVersionLoaders,
            fallback: selectedLoader
        )
    }

    private func assetName(for loader: String) -> String {
        LoaderNameResolver.assetName(for: loader)
    }
}
