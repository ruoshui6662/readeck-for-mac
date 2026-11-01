import SwiftUI

enum BulkEditorFocus: Hashable { case category, tags }

struct BulkEditorRequest: Identifiable {
    let id = UUID().uuidString
    let connectionID: String
    let bookmarks: [Bookmark]
    var focus: BulkEditorFocus? = nil
}

struct BulkOrganizationView: View {
    @ObservedObject var model: AppModel
    let request: BulkEditorRequest
    var onComplete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var category = BulkCategoryChange.keep
    @State private var additions: Set<String> = []
    @State private var removals: Set<String> = []
    @State private var query = ""
    @State private var removing = false
    @FocusState private var focusedSection: BulkEditorFocus?

    private var hasChanges: Bool { category != .keep || !additions.isEmpty || !removals.isEmpty }
    private var matchingTags: [String] {
        LabelCatalog.unique(model.labelPreferences.pinned + model.labelPreferences.recent + model.labelCatalog.tags)
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
    private var known: [Bookmark] { request.bookmarks.filter { $0.labels != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("批量整理").font(.title3.weight(.semibold))
                    Text("已选 \(request.bookmarks.count) 篇文章").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isApplyingBulk)
                Button("应用更改") {
                    Task {
                        guard model.client?.storageInstance == request.connectionID else { dismiss();return }
                        if await model.applyBulk(id: request.id, bookmarks: request.bookmarks,
                            intent: .organize(category: category, adding: additions.sorted(), removing: removals.sorted())) {
                            onComplete();dismiss()
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || model.isApplyingBulk || model.client?.storageInstance != request.connectionID)
            }
            Divider()
            HStack {
                Label("分类", systemImage: AppSymbol.category.rawValue).frame(width: 72, alignment: .leading)
                Picker("批量分类", selection: $category) {
                    Text("保持原分类").tag(BulkCategoryChange.keep)
                    Text("未分类").tag(BulkCategoryChange.clear)
                    Divider()
                    ForEach(model.labelCatalog.categories, id: \.self) { name in Text(name).tag(BulkCategoryChange.set(name)) }
                }.labelsHidden().focused($focusedSection, equals: .category)
            }
            Text("仅替换分类，每篇文章的其他标签会保留。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Label("标签", systemImage: AppSymbol.tag.rawValue)
                Spacer()
                Picker("标签操作", selection: $removing) {
                    Text("添加标签").tag(false)
                    Text("移除标签").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
            TextField("搜索已有标签", text: $query).textFieldStyle(.roundedBorder).focused($focusedSection, equals: .tags)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(matchingTags, id: \.self) { tag in
                        Button {
                            if removing {
                                if removals.contains(tag) { removals.remove(tag) } else { removals.insert(tag);additions.remove(tag) }
                            } else {
                                if additions.contains(tag) { additions.remove(tag) } else { additions.insert(tag);removals.remove(tag) }
                            }
                        } label: {
                            HStack {
                                let active = removing ? removals.contains(tag) : additions.contains(tag)
                                Image(systemName: active ? "checkmark.square.fill" : "square").foregroundStyle(active ? Color.accentColor : .secondary)
                                Text(tag).lineLimit(1)
                                Spacer()
                                let count = known.filter { $0.labelValues.contains(tag) }.count
                                Text("\(count)/\(known.count) 篇使用").font(.caption).foregroundStyle(.secondary)
                                if additions.contains(tag) { Image(systemName: "plus.circle").foregroundStyle(.secondary) }
                                if removals.contains(tag) { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                            }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if matchingTags.isEmpty { Text("没有找到标签。").foregroundStyle(.secondary).padding(.vertical, 16) }
                }
            }.frame(minHeight: 130, maxHeight: 230)
            HStack {
                Text("添加 \(additions.count) 个 · 移除 \(removals.count) 个").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isApplyingBulk { ProgressView().controlSize(.small) }
            }
            if known.count != request.bookmarks.count {
                Text("部分文章的标签资料将在应用前从 NAS 补齐。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.bulkError { Text(message).font(.caption).foregroundStyle(.red).lineLimit(3) }
            Text("先保存到本机，联网后同步到 NAS。创建分类或标签请到管理窗口。").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20).frame(width: 460)
        .interactiveDismissDisabled(model.isApplyingBulk)
        .onAppear { focusedSection = request.focus }
    }
}

struct BulkActionsMenu: View {
    let count: Int
    let onOrganize: () -> Void
    let onAction: (BulkEditIntent) -> Void
    let onDelete: () -> Void
    var body: some View {
        Text("已选 \(count) 篇文章")
        Button("分类与标签…", action: onOrganize)
        Divider()
        BulkStarActions(onAction: onAction)
        BulkArchiveActions(onAction: onAction)
        Divider()
        Button("永久删除所选文章…", role: .destructive, action: onDelete)
    }
}

struct BulkStarActions: View {
    let onAction: (BulkEditIntent) -> Void
    var body: some View {
        Button("设为星标") { onAction(.star(true)) }
        Button("取消星标") { onAction(.star(false)) }
    }
}

struct BulkArchiveActions: View {
    let onAction: (BulkEditIntent) -> Void
    var body: some View {
        Button("归档") { onAction(.archive(true)) }
        Button("移回收件箱") { onAction(.archive(false)) }
    }
}
