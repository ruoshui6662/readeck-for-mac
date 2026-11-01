import AppKit
import SwiftUI

enum LibraryLayout: String, CaseIterable, Identifiable {
    case cards, list
    var id: String { rawValue }
}

struct BookmarkGridView: View {
    let bookmarks: [Bookmark]
    let pending: [PendingSave]
    let client: ReadeckClient?
    let onOpen: (Bookmark) -> Void
    let onRename: (Bookmark) -> Void
    let onDelete: (Bookmark) -> Void
    var selection: Binding<LibrarySelection>? = nil
    var onContextOrganize: ((Bookmark) -> Void)? = nil
    var onContextAction: ((Bookmark, BulkEditIntent) -> Void)? = nil
    var onContextDelete: ((Bookmark) -> Void)? = nil

    var onPatch: (Bookmark, BookmarkPatch) async -> Void = { _, _ in }
    var onOrganize: ((Bookmark) -> Void)? = nil
    var actionsDisabled = false
    @StateObject private var events = LibraryListEvents()

    var body: some View {
        GeometryReader { viewport in
            let metrics = LibraryCardGridMetrics(viewportWidth: viewport.size.width)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(metrics.cardWidth), spacing: LibraryCardGridMetrics.columnSpacing, alignment: .top), count: metrics.columns),
                          alignment: .leading, spacing: LibraryCardGridMetrics.rowSpacing) {
                    ForEach(pending) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Label("待同步", systemImage: AppSymbol.sync.rawValue).foregroundStyle(.orange)
                            Text(item.title.isEmpty ? item.url : item.title).font(.headline).lineLimit(3)
                            Text("已保存在本机，等待发送到 NAS。").font(.caption).foregroundStyle(.secondary)
                        }.padding(16).frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(bookmarks) { item in
                        BookmarkCardView(item: item, client: client, onOpen: {
                            if let selection {
                                var value = selection.wrappedValue
                                let flags = events.modifiers
                                if value.click(item.id, orderedIDs: bookmarks.map(\.id), command: flags.contains(.command), shift: flags.contains(.shift)) {
                                    selection.wrappedValue = value;return
                                }
                            }
                            onOpen(item)
                        }, isSelecting: selection?.wrappedValue.isSelecting == true, isSelected: selection?.wrappedValue.ids.contains(item.id) == true,
                           onRead: { onOpen(item) }, onOrganize: onOrganize.map { action in { action(item) } },
                           onRename: { onRename(item) }, onDelete: { onDelete(item) }, onPatch: onPatch,
                           actionsDisabled: actionsDisabled, cardWidth: metrics.cardWidth)
                            .contextMenu {
                                if selection?.wrappedValue.isSelecting == true, selection?.wrappedValue.ids.contains(item.id) == true {
                                    BulkActionsMenu(count: selection?.wrappedValue.ids.count ?? 1,
                                        onOrganize: { onContextOrganize?(item) }, onAction: { onContextAction?(item, $0) },
                                        onDelete: { onContextDelete?(item) })
                                } else {
                                    BookmarkActionsMenu(item: item, onOpen: { onOpen(item) },
                                        onOrganize: onOrganize.map { action in { action(item) } },
                                        onRename: { onRename(item) }, onDelete: { onDelete(item) },
                                        onPatch: { patch in Task { await onPatch(item, patch) } })
                                        .disabled(actionsDisabled)
                                }
                            }
                    }
                }
                .frame(width: metrics.gridWidth, alignment: .leading)
                .padding(.horizontal, metrics.horizontalInset)
                .padding(.top, 20).padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(LibraryListEventCapture(events: events))
        .background(.quaternary.opacity(0.12))
        .overlay {
            if bookmarks.isEmpty && pending.isEmpty {
                ContentUnavailableView("这里还没有收藏", systemImage: "bookmark", description: Text("按 ⌘N 保存一个网页。"))
            }
        }
    }
}

private struct BookmarkCardView: View {
    let item: Bookmark
    let client: ReadeckClient?
    let onOpen: () -> Void
    var isSelecting = false
    var isSelected = false
    let onRead: () -> Void
    let onOrganize: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void
    let onPatch: (Bookmark, BookmarkPatch) async -> Void
    var actionsDisabled = false
    var cardWidth: CGFloat = 252
    @State private var actionFocused = false
    @State private var cover: NSImage?
    @State private var hovered = false
    @FocusState private var keyboardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var artwork: ArtCover? {
        guard !ArtCoverCatalog.shared.isEmpty else { return nil }
        return ArtCoverCatalog.artwork(for: item.url, in: ArtCoverCatalog.shared)
    }
    private var identity: String {
        (client?.storageInstance ?? "") + "|" + item.id + "|" + (item.updated ?? "") + item.coverResources.map(\.src).joined()
    }
    private var fallbackImage: NSImage? {
        guard let artwork, let url = ArtCoverCatalog.imageURL(for: artwork) else { return nil }
        return NSImage(contentsOf: url)
    }

    private var showActions: Bool { hovered || keyboardFocused || actionFocused }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { size in
                        Group {
                            if let image = cover ?? fallbackImage { Image(nsImage: image).resizable().scaledToFill() }
                            else { Rectangle().fill(.quaternary) }
                        }.frame(width: size.size.width, height: size.size.height).clipped()
                    }.aspectRatio(16.0 / 9, contentMode: .fit)
                    .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.05)).frame(height: 0.5) }
                    .overlay(alignment: .topTrailing) {
                        if isSelecting {
                            Image(systemName: isSelected ? AppSymbol.selected.rawValue : AppSymbol.unselected.rawValue)
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5)).padding(10).accessibilityHidden(true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.displayTitle).font(.system(size: 13, weight: .semibold))
                            .lineLimit(3).multilineTextAlignment(.leading)
                            .frame(height: 49, alignment: .topLeading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            Text(item.displaySite).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 2)
                            if item.isMarked == true { Image(systemName: AppSymbol.starred.rawValue).foregroundStyle(Color.orange.opacity(0.85)).opacity(!isSelecting && showActions ? 0 : 1) }
                            if let time = item.readingTime, time > 0 { Text("\(time) 分钟").fixedSize() }
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                        Group {
                            if let status = item.captureStatus {
                                Text(AppLanguage.text(status)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                GeometryReader { size in
                                    Capsule().fill(.primary.opacity(0.08))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(Color.accentColor.opacity(0.7))
                                                .frame(width: size.size.width * CGFloat(min(max(item.readProgress ?? 0, 0), 100)) / 100)
                                        }
                                }.frame(height: 2.5)
                            }
                        }.frame(height: 12, alignment: .center)
                    }.padding(14)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(keyboardFocused ? Color.accentColor.opacity(0.8) : isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(contrast == .increased ? 0.3 : hovered ? 0.14 : 0.065),
                                      lineWidth: keyboardFocused ? 2 : isSelected ? 1.5 : 0.75)
                }
                .shadow(color: .black.opacity(hovered ? 0.08 : 0.035), radius: hovered ? 9 : 5, y: hovered ? 3 : 2)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($keyboardFocused)
            .focusEffectDisabled()
            .accessibilityLabel("\(item.displayTitle)，\(item.displaySite)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(item.displayTitle)
            if !isSelecting && cardWidth >= 60 {
                BookmarkQuickActions(item: item, revealed: showActions, inline: cardWidth >= 150,
                    persistentStar: false, idPrefix: "card", onOpen: onRead, onOrganize: onOrganize,
                    onRename: onRename, onDelete: onDelete, onPatch: onPatch,
                    disabled: actionsDisabled, onFocusChange: { actionFocused = $0 })
                    .padding(3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
                    .padding(10)
                    .opacity(showActions ? 1 : 0).allowsHitTesting(showActions)
            }
        }
        .accessibilityElement(children: .contain)
        .onHover { value in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { hovered = value }
        }
        .task(id: identity) {
            cover = nil
            guard let client else { return }
            let image = await CoverImageStore.shared.image(for: item, client: client)
            guard !Task.isCancelled else { return }
            cover = image
        }
    }
}
