import SwiftUI

struct ColorPickerView: View {
    @ObservedObject var theme = ThemeManager.shared
    let colorOptions: [(name: String, color: Color)] = [
        ("蓝色", .blue), ("紫色", .purple), ("粉色", .pink), ("红色", .red),
        ("橙色", .orange), ("黄色", .yellow), ("绿色", .green), ("灰色", .gray)
    ]
    var body: some View {
        VStack(spacing: 32) {
            Text("选择强调色").font(.largeTitle.bold()).padding(.top, 40)
            Text("将用于分类高亮和按钮").font(.title3).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 32) {
                ForEach(colorOptions, id: \.name) { option in
                    ColorOptionButton(color: option.color, name: option.name)
                }
            }.padding(.horizontal, 60).padding(.vertical, 40)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.clear)
    }
}

struct ColorOptionButton: View {
    let color: Color; let name: String
    @ObservedObject var theme = ThemeManager.shared
    @State private var animationScale: CGFloat = 1.0
    private var isSelected: Bool { theme.accentColor == color }
    var body: some View {
        Button(action: { theme.accentColor = color }) {
            VStack(spacing: 12) {
                Circle().fill(color).frame(width: 60, height: 60)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: isSelected ? 4 : 0))
                    .shadow(color: color.opacity(0.5), radius: 8)
                    .scaleEffect(animationScale)
                    .animation(.exaggeratedSpring, value: animationScale)
                Text(name).font(.headline).foregroundColor(.primary)
            }
        }.buttonStyle(.plain)
        .onChange(of: isSelected) { newValue in
            if newValue {
                withAnimation(.punchySpring) { animationScale = 1.2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.punchySpring) { animationScale = 1.0 }
                }
            } else {
                withAnimation(.punchySpring) { animationScale = 0.8 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.punchySpring) { animationScale = 1.0 }
                }
            }
        }
    }
}

struct AnimatedCategoryPicker: View {
    @Binding var selectedCategory: Category
    let categories: [Category]
    @ObservedObject var theme = ThemeManager.shared
    @Environment(\.colorScheme) var colorScheme
    @Namespace private var namespace
    @State private var frames: [Category: CGRect] = [:]
    private var highlightColor: Color {
        colorScheme == .light ? theme.accentColor.opacity(0.2) : theme.accentColor.opacity(0.3)
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollViewReader { proxy in
                HStack(spacing: 24) {
                    ForEach(categories) { category in
                        Button(action: {
                            withAnimation(.spring(response: 0.52, dampingFraction: 0.58, blendDuration: 0.12)) {
                                selectedCategory = category
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: category.systemImage).font(.body)
                                Text(category.name).font(.title3).fontWeight(.medium)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .contentShape(Rectangle())
                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear { frames[category] = geo.frame(in: .global) }
                                    .onChange(of: geo.frame(in: .global)) { frames[category] = $0 }
                            })
                        }
                        .buttonStyle(.plain)
                        .id(category.id)
                        .foregroundColor(selectedCategory == category ? theme.accentColor : .secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(
                    GeometryReader { geo in
                        if let selectedFrame = frames[selectedCategory] {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(highlightColor)
                                .frame(width: selectedFrame.width, height: selectedFrame.height)
                                .position(x: selectedFrame.midX - geo.frame(in: .global).minX,
                                          y: selectedFrame.midY - geo.frame(in: .global).minY)
                                .animation(.spring(response: 0.52, dampingFraction: 0.58, blendDuration: 0.12), value: selectedCategory)
                        }
                    }
                )
            }
        }
    }
}