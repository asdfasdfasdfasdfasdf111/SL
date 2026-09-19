//
//  DownloadMerger.swift
//  PCL.Mac
//
//  分片合并。旧实现在 `NetManager.merge` 里同时处理覆盖策略、拼接、
//  临时文件清理与校验；这里只保留「按序拼成目标文件」这一件事。
//

import Foundation

/// 把若干已完成分片按 offset 顺序拼接为目标文件。
///
/// 实现约定：
/// - 调用方传入的分片必须已按 offset 升序且彼此衔接；
/// - 目标文件所在目录由实现负责创建；
/// - 单个分片时允许直接移动临时文件，避免一次全量拷贝。
public protocol DownloadMerger: Sendable {
    func merge(slices: [DownloadSlice], to destination: URL) throws
}
