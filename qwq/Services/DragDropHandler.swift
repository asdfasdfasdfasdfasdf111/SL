import Foundation

/// 拖拽数据加载器：只负责把 `NSItemProvider` 解成本地文件 URL，
/// 不做「什么文件该走哪条安装路径」的业务裁决（该决策在 `DropInstallCoordinator`）。
class DragDropHandler {

    /// 从拖拽 provider 中取出文件 URL。
    /// - Parameter completion: 主线程回调，参数为本批解析出的 URL。
    /// - Returns: 是否存在可接受的文件拖拽内容（沿用旧 `handleDrop` 的返回语义）。
    func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    DispatchQueue.main.async {
                        completion([url])
                    }
                }
                return true
            }
        }
        return false
    }
}
