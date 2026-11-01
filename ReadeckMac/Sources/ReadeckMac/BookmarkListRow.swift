import AppKit
import SwiftUI

struct BookmarkListRow: View {
    let item: Bookmark
    let client: ReadeckClient?
    let metrics: LibraryListMetrics
    let selecting: Bool
    let selected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onOrganize: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void
    let onPatch: (Bookmark, BookmarkPatch) async -> Void
    var actionsDisabled = false
    @State private var hovered = false
    @State private var cover: NSImage?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var assignment: CategoryCodec.Assignment { CategoryCodec.assignment(in: item.labelValues) }
    private var progress: Int { min(100, max(0, item.readProgress ?? 0)) }
    private var identity: String {
        (client?.storageInstance ?? "") + "|" + item.id + "|" + (item.updated ?? "") + item.coverResources.map(\.src).joined(separator: "|")
    }
    private var fallback: NSImage? {
        guard !ArtCoverCatalog.shared.isEmpty,
              let url = ArtCoverCatalog.imageURL(for: ArtCoverCatalog.artwork(for: item.url, in: ArtCoverCatalog.shared)) else { return nil }
        return NSImage(contentsOf: url)
    }
    private var paper: Color {
        if selected { return .accentColor.opacity(scheme == .dark ? 0.16 : 0.065) }
        return scheme == .dark ? Color(white: hovered ? 0.15 : 0.135) : .white
    }

    var body: some View {
        HStack(spacing: metrics.narrow ? 12 : 16) {
            if selecting {
                Button(action: onSelect) {
                    Image(systemName: selected ? AppSymbol.selected.rawValue : AppSymbol.unselected.rawValue)
                        .font(.system(size: 18)).foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(AppLanguage.text("选择文章") + "：" + item.displayTitle)
                .accessibilityIdentifier("list.select." + item.id)
            }
            Button(action: onOpen) {
                HStack(spacing: metrics.narrow ? 12 : 16) {
                    if metrics.showsCover {
                        Group {
                            if let image = cover ?? fallback { Image(nsImage: image).resizable().scaledToFill() }
                            else { Rectangle().fill(.quaternary) }
                        }
                        .frame(width: metrics.coverWidth, height: metrics.coverHeight).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: metrics.density == .compact ? 6 : 7) {
                        Text(item.displayTitle).font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading).help(item.displayTitle)
                        sourceLine
                        if metrics.showsSummary, let description = item.description, !description.isEmpty {
                            Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        metadataLine
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !selecting { actionRail }
        }
        .padding(.horizontal, metrics.narrow ? 14 : 16)
        .padding(.vertical, metrics.density == .compact ? 12 : 16)
        .frame(minHeight: metrics.minimumHeight)
        .background(paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(contrast == .increased ? 0.3 : scheme == .dark ? 0.07 : hovered ? 0.09 : 0.035), lineWidth: selected ? 1 : 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: identity + (metrics.showsCover ? "|cover" : "|none")) {
            cover = nil
            guard metrics.showsCover, let client else { return }
            let image = await CoverImageStore.shared.image(for: item, client: client)
            guard !Task.isCancelled else { return }
            cover = image
        }
    }
    private var sourceLine: some View {
        HStack(spacing: 5) {
            let name = item.displaySite.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(name.isEmpty ? (URL(string: item.url)?.host ?? item.url) : name).lineLimit(1)
            if let minutes = item.readingTime, minutes > 0 { Text("·"); Text("\(minutes) 分钟").fixedSize() }
            if metrics.narrow && item.isMarked == true {
                Image(systemName: AppSymbol.starred.rawValue).foregroundStyle(.orange).font(.system(size: 9))
                    .accessibilityLabel("星标")
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }
    private var metadataLine: some View {
        HStack(spacing: 10) {
            if metrics.showsCategory {
                if assignment.hasConflict {
                    Label("分类待整理", systemImage: "exclamationmark.folder").foregroundStyle(.orange).lineLimit(1)
                } else if let name = assignment.category {
                    Label(name, systemImage: AppSymbol.category.rawValue).lineLimit(1)
                }
            }
            if metrics.showsTags {
                ForEach(Array(LabelCatalog.unique(item.labelValues.filter { !CategoryCodec.isCategoryLabel($0) }).prefix(2)), id: \.self) { tag in
                    Text(verbatim: "# " + tag).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let status = item.captureStatus {
                Label(AppLanguage.text(status), systemImage: item.isProcessing ? AppSymbol.waiting.rawValue : AppSymbol.warning.rawValue)
                    .lineLimit(1).help(AppLanguage.text(status))
            } else { readingProgress }
        }.font(.system(size: 10.5)).foregroundStyle(.secondary)
    }
    private var readingProgress: some View {
        HStack(spacing: 7) {
            if metrics.showsProgressBar {
                Capsule().fill(Color.primary.opacity(0.075))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor.opacity(0.52)).frame(width: 48 * CGFloat(progress) / 100)
                    }.frame(width: 48, height: 2)
            }
            Text(progress == 0 ? AppLanguage.text("未读") : progress == 100 ? AppLanguage.text("已读") : "\(progress)%")
                .monospacedDigit().fixedSize()
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(AppLanguage.text("阅读进度") + " \(progress)%")
    }
    private var actionRail: some View {
        BookmarkQuickActions(item: item, revealed: hovered, inline: metrics.showsInlineActions,
            idPrefix: "list", onOpen: onOpen, onOrganize: onOrganize,
            onRename: onRename, onDelete: onDelete, onPatch: onPatch, disabled: actionsDisabled)
    }
}
