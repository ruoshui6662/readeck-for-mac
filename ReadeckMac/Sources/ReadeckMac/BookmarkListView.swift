import AppKit
import SwiftUI

struct BookmarkListView: View {
    @Binding var selectedID: String?
    let bookmarks: [Bookmark]
    let pending: [PendingSave]
    var onRename: (Bookmark) -> Void = { _ in }
    var onDelete: (Bookmark) -> Void = { _ in }
    var selection: Binding<LibrarySelection>? = nil
    var onContextOrganize: ((Bookmark) -> Void)? = nil
    var onContextAction: ((Bookmark, BulkEditIntent) -> Void)? = nil
    var onContextDelete: ((Bookmark) -> Void)? = nil

    var client: ReadeckClient? = nil
    var density = LibraryListDensity.standard
    var thumbnails = true
    var sortOrder: Binding<LibrarySortOrder>? = nil
    var onPatch: (Bookmark, BookmarkPatch) async -> Void = { _, _ in }
    var onOrganize: ((Bookmark) -> Void)? = nil
    var actionsDisabled = false
    @StateObject private var events = LibraryListEvents()
    @Environment(\.colorScheme) private var scheme

    private var normalSelection: Binding<String?> {
        Binding(get: { selectedID }, set: { id in
            if let id, let selection {
                var value = selection.wrappedValue
                let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                if value.click(id, orderedIDs: bookmarks.map(\.id), command: flags.contains(.command), shift: flags.contains(.shift)) {
                    selection.wrappedValue = value;return
                }
            }
            selectedID = id
        })
    }
    private var multipleSelection: Binding<Set<String>> {
        Binding(get: { selection?.wrappedValue.ids ?? [] }, set: { ids in
            guard let selection else { return };var value = selection.wrappedValue
            value.replace(ids, visibleIDs: bookmarks.map(\.id));selection.wrappedValue = value
        })
    }
    var body: some View {
        GeometryReader { geometry in
            let metrics = LibraryListMetrics(availableWidth: geometry.size.width, density: density, thumbnails: thumbnails)
            Group {
                if selection?.wrappedValue.isSelecting == true { List(selection: multipleSelection) { rows(metrics) } }
                else { List(selection: normalSelection) { rows(metrics) } }
            }
            .background(LibraryListEventCapture(events: events))
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(scheme == .dark ? Color(red: 0.105, green: 0.11, blue: 0.12) : Color(red: 0.985, green: 0.987, blue: 0.99))
            .overlay {
                if bookmarks.isEmpty && pending.isEmpty {
                    ContentUnavailableView("这里还没有收藏", systemImage: "bookmark", description: Text("按 ⌘N 保存一个网页。"))
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ metrics: LibraryListMetrics) -> some View {
            if !bookmarks.isEmpty {
                centered(metrics) {
                    HStack {
                        Text(BulkText.format("%lld 篇收藏", bookmarks.count))
                        Spacer()
                        if selection?.wrappedValue.isSelecting != true, let sortOrder {
                            Menu {
                                Picker("排序", selection: sortOrder) {
                                    ForEach(LibrarySortOrder.allCases) { Text(AppLanguage.text($0.label)).tag($0) }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(AppLanguage.text(sortOrder.wrappedValue.label))
                                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                                }
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("排序")
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2).padding(.top, 14).padding(.bottom, 8)
                }.selectionDisabled(true).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
            }
            if !pending.isEmpty {
                Section("待同步") {
                    ForEach(pending) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: AppSymbol.sync.rawValue)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.isEmpty ? item.url : item.title)
                                    .lineLimit(2)
                                Text(item.attemptedAt == nil ? "已保存到本机，等待发送到 NAS" : "正在确认服务端结果")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .selectionDisabled(true)
                    }
                }
            }
            Section {
                ForEach(bookmarks) { item in
                    centered(metrics) {
                        BookmarkListRow(item: item, client: client, metrics: metrics,
                            selecting: selection?.wrappedValue.isSelecting == true,
                            selected: selection?.wrappedValue.ids.contains(item.id) == true,
                            onSelect: {
                                guard let selection else { return }
                                var value = selection.wrappedValue
                                value.click(item.id, orderedIDs: bookmarks.map(\.id), command: true, shift: false)
                                selection.wrappedValue = value
                            }, onOpen: { activate(item.id) },
                            onOrganize: onOrganize.map { callback in { callback(item) } },
                            onRename: { onRename(item) }, onDelete: { onDelete(item) },
                            onPatch: onPatch, actionsDisabled: actionsDisabled)
                            .background(SidebarSelectionAppearance().allowsHitTesting(false))
                    }
                        .tag(item.id)
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: metrics.rowSpacing / 2, leading: 22, bottom: metrics.rowSpacing / 2, trailing: 22))
                        .contextMenu {
                            if selection?.wrappedValue.isSelecting == true, selection?.wrappedValue.ids.contains(item.id) == true {
                                BulkActionsMenu(count: selection?.wrappedValue.ids.count ?? 1,
                                    onOrganize: { onContextOrganize?(item) }, onAction: { onContextAction?(item, $0) },
                                    onDelete: { onContextDelete?(item) })
                            } else {
                                BookmarkActionsMenu(item: item, onOpen: { selectedID = item.id },
                                    onOrganize: onOrganize.map { callback in { callback(item) } },
                                    onRename: { onRename(item) }, onDelete: { onDelete(item) },
                                    onPatch: { patch in Task { await onPatch(item, patch) } })
                                    .disabled(actionsDisabled)
                            }
                        }
                }
            }
    }
    private func activate(_ id: String) {
        if let selection {
            var value = selection.wrappedValue
            if value.click(id, orderedIDs: bookmarks.map(\.id), command: events.modifiers.contains(.command), shift: events.modifiers.contains(.shift)) {
                selection.wrappedValue = value
                return
            }
        }
        selectedID = id
    }
    private func centered<Content: View>(_ metrics: LibraryListMetrics, @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: metrics.rowWidth).frame(maxWidth: .infinity)
    }
}
