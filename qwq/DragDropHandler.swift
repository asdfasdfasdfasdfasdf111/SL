import Foundation

class DragDropHandler {
    var onJarDropped: ((URL) -> Void)?
    var onModpackDropped: ((URL) -> Void)?

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    let ext = url.pathExtension.lowercased()
                    DispatchQueue.main.async {
                        if ext == "jar" {
                            self.onJarDropped?(url)
                        } else if ext == "zip" || ext == "mrpack" {
                            self.onModpackDropped?(url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}
