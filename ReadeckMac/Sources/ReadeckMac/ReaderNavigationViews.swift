import SwiftUI

struct ReaderNavigationRequest: Equatable {
    enum Action: Equatable {
        case find(String, Int)
        case heading(Int)
    }
    let id = UUID()
    let action: Action
}

struct ReaderFindBar: View {
    @Binding var query: String
    let result: ReaderFindState
    let onStep: (Int) -> Void
    let onClose: () -> Void
    var focusRequest = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("在文章中查找", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { onStep(1) }
                .onExitCommand(perform: onClose)
                .accessibilityLabel("在文章中查找")
            if !query.isEmpty {
                Text(result.count == 0 ? AppLanguage.text("无匹配") : "\(result.current) / \(result.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize().accessibilityLabel("查找结果")
                    .accessibilityValue(result.count == 0 ? AppLanguage.text("无匹配") : "\(result.current) / \(result.count)")
            }
            Button { onStep(-1) } label: { Image(systemName: "chevron.up") }
                .help("上一处（⇧⌘G）").accessibilityLabel("上一处").disabled(result.count == 0)
            Button { onStep(1) } label: { Image(systemName: "chevron.down") }
                .help("下一处（⌘G）").accessibilityLabel("下一处").disabled(result.count == 0)
            Button("完成", action: onClose)
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.bar)
        .task(id: focusRequest) { focused = true }
    }
}

/// Temporary reading state; independent of the saved directory style.
struct ReaderOutlineVisibility {
    private(set) var isCollapsed = false
    mutating func toggle() { isCollapsed.toggle() }
    mutating func open() { isCollapsed = false }
}

struct ReaderOutlineToggle: View {
    let collapsed: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(hovered ? 0.06 : 0.025), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(collapsed ? "展开目录" : "收起目录")
        .accessibilityLabel(AppLanguage.text(collapsed ? "展开目录" : "收起目录"))
    }
}

/// One hierarchy treatment for the immersive rail, popover and classic panel.
struct ReaderOutlineView: View {
    let headings: [ReaderHeading]
    let isReady: Bool
    var current: Int? = nil
    var immersive = false
    var focusRequest = UUID()
    let onSelect: (ReaderHeading) -> Void

    private var baseLevel: Int { headings.map(\.level).min() ?? 1 }

    var body: some View {
        Group {
            if !isReady {
                ProgressView("正在读取目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if headings.isEmpty {
                ContentUnavailableView("这篇文章没有目录", systemImage: "list.bullet.indent",
                    description: Text("文章没有可用的章节标题，仍可使用文内查找。"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(headings) { heading in
                                let depth = min(max(heading.level - baseLevel, 0), 4)
                                ReaderOutlineRow(heading: heading, depth: depth, selected: current == heading.index) {
                                    onSelect(heading)
                                }
                                .padding(.top, depth == 0 && heading.id != headings.first?.id ? 15 : 0)
                                .id(heading.index)
                            }
                        }.padding(.horizontal, immersive ? 0 : 14).padding(.vertical, immersive ? 0 : 16)
                            .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: current) { _, value in
                        if headings.count > 18, let value { proxy.scrollTo(value, anchor: .center) }
                    }
                    .onChange(of: focusRequest) { _, _ in
                        if let current { proxy.scrollTo(current, anchor: .center) }
                    }
                    .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                }
            }
        }
    }
}

private struct ReaderOutlineRow: View {
    let heading: ReaderHeading
    let depth: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                ZStack {
                    if selected { Capsule().fill(.primary.opacity(0.8)).frame(width: 2, height: 13) }
                    else if depth == 0 { Circle().fill(.secondary.opacity(0.42)).frame(width: 3, height: 3) }
                    else if depth == 1 { Capsule().fill(.secondary.opacity(0.3)).frame(width: 5, height: 1) }
                    else { Circle().fill(.secondary.opacity(0.3)).frame(width: 2, height: 2) }
                }.frame(width: 5, height: 13)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }.accessibilityHidden(true)
                Text(verbatim: heading.title)
                    .font(.system(size: depth == 0 ? 12.5 : 11.5, weight: selected ? .semibold : depth == 0 ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineSpacing(3).multilineTextAlignment(.leading).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth * 12) + 7).padding(.trailing, 6)
            .padding(.vertical, depth == 0 ? 8 : 6)
            .background(hovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help(heading.title)
        .accessibilityLabel(heading.title)
        .accessibilityValue(AppLanguage.text(selected ? "当前章节" : ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
