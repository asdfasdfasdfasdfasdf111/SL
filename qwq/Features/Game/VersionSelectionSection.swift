//
//  VersionSelectionSection.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 内联的「版本/加载器选择区块」）
//  纯视图组件：按详情页类型渲染版本卡片 / 加载器卡片 / 整合包版本分组网格，
//  选择状态 @Binding 外置（selectedVersion / selectedLoader / selectedModpackVersionId），
//  不含任何网络、缓存与磁盘副作用，加载器名解析走 LoaderNameResolver。
//

//
//  VersionSelectionSection.swift
//  模块化拆分：从 ModDetailView.swift 拆出（原 detailPageContent 内联的「版本/加载器选择区块」）
//  纯视图组件：按详情页类型渲染版本卡片 / 加载器卡片 / 整合包版本分组网格，
//  选择状态 @Binding 外置（selectedVersion / selectedLoader / selectedModpackVersionId），
//  不含任何网络、缓存与磁盘副作用，加载器名解析走 LoaderNameResolver。
//
//  三种形态由 `pageType` 一分为三（见 body）：
//    .modpack        → 整合包版本网格（每行 4 个）
//    .loaderSelector → 加载器卡片（游戏版本页专用，带逐加载器检测状态）
//    其余            → 普通版本卡片列表（模组 / 光影 / 资源包）
//
//  ⚠️ 本文件多处使用 `AnyView`，是为了让 `loaderCardArea` 的多个分支能统一成同一个返回类型。
//  代价是 SwiftUI 拿不到具体视图类型、无法做静态 diff，分支切换时会重建视图。
//  当前分支切换频率很低，可接受；若这里变成高频重绘点，应改用 @ViewBuilder 分支。
//

import SwiftUI

/// 详情页「选择版本/加载器」区块：渲染并交互三类选择器
struct VersionSelectionSection: View {
    /// 主题来源由调用方注入（全局单例外部持有），本视图不持有、不写默认值
    @ObservedObject var theme: ThemeManager

    /// 决定本区块渲染成哪一种形态（见文件头注释的三分支）。
    let pageType: DetailPageType
    /// 普通版本列表（模组 / 光影 / 资源包用），已由调用方排好序。
    let sortedVersions: [String]
    /// 候选加载器名列表（游戏版本页用）。
    let availableLoaders: [String]
    /// 整合包专用：按游戏版本去重后的 (游戏版本, 包版本) 二元组，顺序即展示顺序。
    let uniqueVersions: [(gameVersion: String, version: ModpackVersion)]
    /// 项目自身声明的加载器（可能为空），优先于本地推断。
    let projectLoaders: [String]
    /// 本地各版本已装的加载器（版本号 → 加载器），项目没声明时靠它推断图标。
    let localVersionLoaders: [String: ModLoader]
    /// 整合包版本列表是否仍在加载（true 时显示转圈而非网格）。
    let isLoadingModpackVersions: Bool
    /// 加载器检测是否仍在进行中。
    let isLoadingLoaders: Bool
    /// 逐加载器检测状态（流式渲染：checking 检测中 / supported 可选 / notSupported 置灰 / unavailable 可点重试）
    let loaderStates: [String: LoaderState]
    /// 检测完成顺序（先定论的在前；supported 卡片按此排序展示）
    let loaderCompletionOrder: [String]
    /// 加载器检测「结果未知」错误文案（网络失败/5xx/超时，区别于「明确不支持」）；
    /// 为 nil 时按正常分支渲染
    var loaderError: String? = nil
    /// 错误态下的重试回调（由宿主提供，通常是重新发起加载器检测）
    var onRetryLoaders: (() -> Void)? = nil

    @Binding var selectedVersion: String
    @Binding var selectedLoader: String
    @Binding var selectedModpackVersionId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pageType.titleText)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            // 三分支互斥：整合包网格 / 加载器列表 / 普通版本卡片列表。
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

    /// 整合包版本网格：把去重后的版本按**每行 4 个**切块，整体横向滚动。
    /// ⚠️ 行是先把数组 chunk 好再 ForEach 的（不是让 SwiftUI 自动换行），
    /// 所以每行数量固定、横向滚动而非上下换行。
    private var modpackGrid: some View {
        Group {
            // 加载中只放一个居中转圈，不做骨架屏（版本数量未知，骨架反而误导）。
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
                        // 每行 4 个。stride + min 切块，最后一行不足 4 个也不会越界。
                        let chunkSize = 4
                        let rows = stride(from: 0, to: uniqueVersions.count, by: chunkSize).map {
                            Array(uniqueVersions[$0..<min($0 + chunkSize, uniqueVersions.count)])
                        }
                        // 行身份改用「本行第一个版本的游戏版本号」，不再用行下标：
                        // 行内容会随 `uniqueVersions` 变化（筛选/排序后同一行会换成别的版本），
                        // 下标身份会把旧内容的视图状态（选中高亮等）错配到新内容上；
                        // 而游戏版本在 `uniqueVersions` 内唯一，故 `first?.gameVersion` 既稳定又唯一。
                        ForEach(rows, id: \.first?.gameVersion) { row in
                            HStack(spacing: 12) {
                                ForEach(row, id: \.gameVersion) { item in
                                    VersionLoaderCard(
                                        version: item.gameVersion,
                                        isSelected: selectedModpackVersionId == item.version.id,
                                        loader: LoaderNameResolver.assetName(for: item.version.loaders.first ?? "fabric"),
                                        theme: theme
                                    ) {
                                        // 两个 state 必须**同时**更新：id 决定下载哪个文件，
                                        // 游戏版本决定图标与筛选。只改一个会让网格高亮与详情页对不上。
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

    /// 加载器形态：上面是卡片区，下面（仅在「部分结果未知」时）补一行错误提示 + 重试。
    /// ⚠️ 这里刻意**不整块替换**成错误页 —— 已有可用卡片时把错误降级成一行附注，
    /// 用户仍能立刻选中可用加载器，不必等错误消失。
    private var loaderSelectorList: some View {
        VStack(alignment: .leading, spacing: 8) {
            loaderCardArea
            if let error = loaderError, !error.isEmpty, !availableLoaders.isEmpty || isLoadingLoaders {
                // 部分加载器结果未知：有可用卡片时在下方补一行错误提示 + 重试（不整块替换）
                HStack(spacing: 10) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if let onRetryLoaders {
                        Button(action: onRetryLoaders) {
                            Text("重试")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// 卡片区：只显示已定论 supported 的加载器卡片（按完成顺序）；检测中轻文字提示；全部无支持 → 空态文案
    /// 卡片区：只显示已定论 `.supported` 的加载器（按**检测完成顺序**排列，
    /// 先出结果的排在前面，用户不必等全部检测完才能动手）。
    /// 一个都没有时再分三种情形：仍在检测 / 结果未知（给重试）/ 确实不支持。
    /// ⚠️ 返回 `AnyView` 的原因见文件头注释。
    private var loaderCardArea: some View {
        // 顺序取自 loaderCompletionOrder（检测完成顺序），不是 availableLoaders 的原始顺序 ——
        // 后者是网络返回顺序，与「哪个先可用」无关。
        let supported = loaderCompletionOrder.filter { loaderStates[$0] == .supported }
        if supported.isEmpty {
            let hasChecking = loaderStates.values.contains { $0 == .checking }
            // 还有加载器在检测 → 只给文字（不转圈）：此时「没有卡片」是暂时的。
            if hasChecking {
                // 检测中：轻文字提示，不显示转圈
                return AnyView(
                    Text("正在检测可用加载器…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 16)
                )
            }
            // 全部加载器都没结果：再分「可重试的未知错误」与「真的都不支持」两种文案 ——
            // 前者绝不能显示成「没有加载器」，那是误判。
            return AnyView(
                Group {
                    if let error = loaderError, !error.isEmpty, loaderStates.values.contains(where: { $0 == .unavailable }) {
                        // 全部结果未知：明确提示可重试，绝不显示「没有加载器」误判
                        HStack(spacing: 10) {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            if let onRetryLoaders {
                                Button(action: onRetryLoaders) {
                                    Text("重试")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(theme.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 16)
                    } else {
                        Text("该版本暂无可用的加载器")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                    }
                }
            )
        }
        return AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(supported, id: \.self) { loader in
                        LoaderSelectorCard(
                            loader: loader,
                            isSelected: selectedLoader == loader,
                            state: .supported,
                            onRetry: onRetryLoaders,
                            theme: theme
                        ) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                                // 再点已选中的卡片 = 取消选中（不装加载器，下载纯原版）
                                selectedLoader = (selectedLoader == loader) ? "" : loader
                            }
                        }
                        // 新卡片以「从小放大 + 淡入」出现；配合外层 .animation(value: supported)，
                        // 每有一个加载器定论就弹出一张。
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                // 水平方向预留放大动画空间（scaleEffect 1.08 放大时最左/最右卡片不被裁剪）
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        // 只对 `supported` 数组的变化做动画 —— 其它状态（转圈 / 错误）不应引起卡片重排。
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: supported)
        )
    }

    // MARK: - 普通版本卡片列表（模组/光影/资源包）

    /// 普通版本卡片列表：横向滚动的一行卡片，点中即写回 `selectedVersion`。
    private var versionCardList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(sortedVersions, id: \.self) { version in
                    VersionLoaderCard(
                        version: version,
                        isSelected: selectedVersion == version,
                        loader: assetName(for: projectLoaderName(for: version)),
                        theme: theme
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
    /// 决定版本卡片上显示的加载器图标用哪个名字。
    /// 优先级：项目声明的加载器（`projectLoaders.first`）>
    /// 按该版本匹配本地已装加载器 > `selectedLoader` 兜底。
    /// ⚠️ 只取 `first`：项目声明多个加载器时卡片只反映其中一个（不影响实际下载内容）。
    private func projectLoaderName(for version: String) -> String {
        projectLoaders.first ?? LoaderNameResolver.name(
            forVersion: version,
            localLoaders: localVersionLoaders,
            fallback: selectedLoader
        )
    }

    /// 薄封装，纯粹让上面的调用点读起来短一些；解析规则仍在 LoaderNameResolver。
    private func assetName(for loader: String) -> String {
        LoaderNameResolver.assetName(for: loader)
    }
}
