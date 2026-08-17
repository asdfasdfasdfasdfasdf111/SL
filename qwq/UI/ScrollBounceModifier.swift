import SwiftUI

struct ScrollBounceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.3, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

extension View {
    func scrollBounceIfAvailable() -> some View {
        self.modifier(ScrollBounceModifier())
    }
}