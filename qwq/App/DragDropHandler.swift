import Foundation
import os

/// 拖拽数据加载器：只负责把 `NSItemProvider` 解成本地文件 URL，
/// 不做「什么文件该走哪条安装路径」的业务裁决（该决策在 `DropInstallCoordinator`）。
class DragDropHandler {

    /// 从拖拽 provider 中取出**全部**文件 URL。
    ///
    /// 行为要点：
    /// - 只处理含 `public.file-url` 的 provider，其余一律忽略（与旧实现一致）；
    /// - 一次拖入多个文件时**全部**解析并交付，顺序与 `providers` 中的顺序一致
    ///   （`DropInstallCoordinator.handle(urls:)` 逐个分流，且以最后一个整合包为暂存目标，
    ///   故顺序必须稳定，不能按回调到达先后排列）；
    /// - 载荷形态随来源变化：既有 `Data`（URL 的字节表示），也有 `NSURL`。
    ///   只认 `Data` 会让 `NSURL` 形态被静默丢弃，因此两种都要接受。
    ///
    /// - Parameter completion: 主线程回调，参数为**本批全部**解析出的 URL（按 provider 顺序，失败项略过）。
    /// - Returns: 是否存在可接受的文件拖拽内容（沿用旧 `handleDrop` 的返回语义）。
    func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }

        // 保序收集：按 provider 下标写入，全部回调到齐后再统一按原顺序交付。
        // 用 `OSAllocatedUnfairLock` 而非裸 `var`：完成回调是 `@Sendable` 且可能在后台线程执行，
        // 共享可变状态必须由锁提供 happens-before（与 `JavaResolverBridge` 的既有用法一致）。
        let collected = OSAllocatedUnfairLock(initialState: [URL?](repeating: nil, count: fileProviders.count))
        let remaining = OSAllocatedUnfairLock(initialState: fileProviders.count)

        for (index, provider) in fileProviders.enumerated() {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url = Self.fileURL(from: item)
                let left = remaining.withLock { count -> Int in
                    collected.withLock { $0[index] = url }
                    count -= 1
                    return count
                }
                guard left == 0 else { return }
                let urls = collected.withLock { $0.compactMap { $0 } }
                // 沿用旧实现：回主线程交付（`loadItem` 的回调不保证在主线程）
                DispatchQueue.main.async { completion(urls) }
            }
        }
        return true
    }

    /// 把 provider 回调交回的 item 归一化成文件 URL。
    /// 纯函数、无状态，显式 `nonisolated`：本方法由 `@Sendable` 的完成回调调用，
    /// 而工程开启了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不标注就会被推断为
    /// 主 actor 隔离，从后台回调同步调用即报「跨 actor 同步访问」。
    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        return nil
    }
}
