import SwiftUI

struct AnnotationDraft: Identifiable {
    let id = UUID()
    let selection: AnnotationSelection?
    let annotation: BookmarkAnnotation?
}

struct AnnotationColorPicker: View {
    @Binding var selection: String
    static let colors: [(String, String, Color)] = [
        ("yellow", "黄色", .yellow), ("red", "红色", .red),
        ("green", "绿色", .green), ("blue", "蓝色", .blue)
    ]
    var body: some View {
        HStack(spacing: 10) {
            Text("颜色").font(.caption).foregroundStyle(.secondary)
            ForEach(Self.colors, id: \.0) { value in
                Button { selection = value.0 } label: {
                    Image(systemName: selection == value.0 ? "checkmark.circle.fill" : "circle.fill")
                        .font(.system(size: 20)).foregroundStyle(value.2)
                }.buttonStyle(.plain).help(value.1)
                    .accessibilityLabel(value.1).accessibilityAddTraits(selection == value.0 ? .isSelected : [])
            }
        }
    }
}

