import SwiftUI

struct VersionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var animationScale: CGFloat = 1.0
    @ObservedObject var theme = ThemeManager.shared
    var body: some View {
        Button(action: {
            withAnimation(.punchySpring) { animationScale = 1.08 }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.punchySpring) { animationScale = 1.0 }
            }
        }) {
            Text(title)
                .font(.body)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).shadow(radius: 1))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? theme.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .scaleEffect(animationScale)
    }
}