import Foundation

/// 卡片副标题翻译结果的内存存储助手（GameViews 列表页 / ModDetailView 详情页共享）。
///
/// 统一「写回 + 上限裁剪」规则：超过 2000 条时保留「正在翻译」的活跃条目，其余淘汰
/// （滚动回看时由磁盘缓存瞬时恢复，功能不受影响）。
///
/// - 活跃集为空（ModDetailView 无 pending 概念，传 `[]`）时裁剪结果为空字典，
///   与原「整体清空」语义完全等价。
struct CardTranslationStore {
    /// 翻译结果内存上限
    static let maxEntries = 2000

    /// 单条写回：超限先裁剪（只保留 active ids），再写入
    static func set(_ dict: inout [String: String], id: String, value: String, active: Set<String>) {
        if dict[id] == nil, dict.count >= Self.maxEntries {
            dict = dict.filter { active.contains($0.key) }
        }
        dict[id] = value
    }

    /// 批量合并（预取结果写回）：超限先裁剪（只保留 active ids），再合并
    static func merge(_ dict: inout [String: String], batch: [String: String], active: Set<String>) {
        if dict.count + batch.count > Self.maxEntries {
            dict = dict.filter { active.contains($0.key) }
        }
        dict.merge(batch) { _, new in new }
    }
}
