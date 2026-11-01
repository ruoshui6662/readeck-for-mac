import AppKit
import SwiftUI

enum SidebarSelection: Hashable {
    case inbox, unread, reading, favorites, archive
    case category(String), tag(String), collection(String)
    case categoryConflicts
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let bookmarks: [Bookmark]
    let collections: [CollectionInfo]
    var catalog: LabelCatalog? = nil
    var onManage: () -> Void = {}

    private var categories: [String] {
        catalog?.categories ?? Set(bookmarks.flatMap(\.labelValues).compactMap(CategoryCodec.name(from:))).sorted()
    }

    private var tags: [String] {
        catalog?.tags ?? Set(bookmarks.flatMap(\.labelValues).filter { !CategoryCodec.isCategoryLabel($0) }).sorted()
    }

    var body: some View {
        List(selection: $selection) {
            Section("资料库") {
                sidebarRow("收件箱", symbol: AppSymbol.inbox.rawValue, value: .inbox)
                sidebarRow("未读", symbol: AppSymbol.unread.rawValue, value: .unread)
                sidebarRow("阅读中", symbol: AppSymbol.reading.rawValue, value: .reading)
                sidebarRow("星标", symbol: AppSymbol.star.rawValue, value: .favorites)
                sidebarRow("已归档", symbol: AppSymbol.archive.rawValue, value: .archive)
            }
            if !categories.isEmpty || bookmarks.contains(where: { CategoryCodec.assignment(in: $0.labelValues).hasConflict }) {
                Section("分类") {
                    if bookmarks.contains(where: { CategoryCodec.assignment(in: $0.labelValues).hasConflict }) {
                        sidebarRow("分类待整理", symbol: "exclamationmark.folder", value: .categoryConflicts)
                            .badge(bookmarks.filter { CategoryCodec.assignment(in: $0.labelValues).hasConflict }.count)

                    }
                    ForEach(categories, id: \.self) { category in
                        sidebarRow(category, symbol: AppSymbol.category.rawValue, value: .category(category))
                            .contextMenu { Button("分类与标签…", action: onManage) }
                    }
                }
            }
            if !tags.isEmpty {
                Section("标签") {
                    ForEach(tags, id: \.self) { tag in
                        sidebarRow(tag, symbol: AppSymbol.tag.rawValue, value: .tag(tag))
                            .contextMenu { Button("分类与标签…", action: onManage) }
                    }
                }
            }
            if !collections.isEmpty {
                Section("智能列表") {
                    ForEach(collections) { collection in
                        sidebarRow(collection.name, symbol: AppSymbol.collection.rawValue, value: .collection(collection.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background { LibrarySidebarSurface().ignoresSafeArea() }
        .navigationTitle("我的收藏")
    }
    private func sidebarRow(_ title: String, symbol: String, value: SidebarSelection) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.primary)
            .tag(value)
            .background(SidebarSelectionAppearance())
            .listRowBackground(RoundedRectangle(cornerRadius: 8)
                .fill(selection == value ? Color(red: 0.36, green: 0.66, blue: 0.98)
                    .opacity(colorScheme == .dark ? 0.20 : 0.13) : .clear)
                .overlay {
                    if selection == value && contrast == .increased {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.45), lineWidth: 1)
                    }
                }
                .padding(.horizontal, 10))
    }
}

// Keep AppKit's native row selection, keyboard navigation and accessibility.
// Suppress only its saturated selection paint; SwiftUI draws the subtle row tint.
struct SidebarSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarSelectionAnchor { SidebarSelectionAnchor() }
    func updateNSView(_ view: SidebarSelectionAnchor, context: Context) { view.applyAppearance() }
}

final class SidebarSelectionAnchor: NSView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyAppearance() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); applyAppearance() }
    func applyAppearance() {
        var parent = superview
        while let view = parent {
            if let table = view as? NSTableView {
                table.selectionHighlightStyle = .none
                return
            }
            parent = view.superview
        }
    }
}
