import Foundation

/// 详情页版本选中决策纯逻辑（ModDetailView 首次加载 / manifest 就绪后决议两处共享）。
/// 集中「默认选中哪个版本」的完整规则，注释随规则保留，调用点一行转发。
enum DetailVersionDecision {
    /// 首次加载默认选中（applyDefaultVersionSelection）：
    /// - 游戏版本页（loaderSelector）：必须选中用户点击的版本（itemName），
    ///   否则会出现「标题是 1.7.2、加载器却显示当前实例版本 26.2 的 4 张卡片」的错乱
    ///   （根因：26.2 缓存命中 Fabric/Forge/NeoForged/Quilt，而 1.7.2 只有 Forge）。
    /// - 其他页面：优先当前实例版本（instanceVersion），其次第一个可用版本。
    /// - itemName 不在列表（manifest 未就绪时列表只有本地版本）：返回 nil 不急着回退，
    ///   避免误选当前实例版本 26.2（sortVersionsForDisplay 会把它提到列表首位）
    ///   命中缓存显示 4 张卡，等 fetchManifestVersions 完成回调按 itemName 重新决议。
    static func initialSelection(
        pageType: DetailPageType,
        itemName: String,
        sortedVersions: [String],
        instanceVersion: String?
    ) -> String? {
        if pageType == .loaderSelector {
            return sortedVersions.contains(itemName) ? itemName : nil
        }
        if let instanceVersion, sortedVersions.contains(instanceVersion) {
            return instanceVersion
        }
        return sortedVersions.first
    }

    /// manifest 就绪后的决议（fetchManifestVersions 回调）：
    /// - 游戏版本页：先保留现有选择（含用户手动选择，此时返回 nil 不覆盖），
    ///   其次用户点击的 itemName，最后才回退列表首位。
    /// - 其他页面：仅当当前选择为空或不在列表时回退首位。
    static func resolveAfterManifest(
        pageType: DetailPageType,
        current: String,
        itemName: String,
        sortedVersions: [String]
    ) -> String? {
        if pageType == .loaderSelector {
            if !current.isEmpty, sortedVersions.contains(current) {
                return nil // 保留现有选择（onAppear 已按 itemName 设置，或用户手动选择）
            }
            if sortedVersions.contains(itemName) {
                return itemName
            }
            return sortedVersions.first
        }
        if current.isEmpty || !sortedVersions.contains(current) {
            return sortedVersions.first
        }
        return nil
    }
}
