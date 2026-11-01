import SwiftUI

struct BookmarkEditorView: View {
    @ObservedObject var model: AppModel
    let bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var tags: [String] = []
    @State private var isSaving = false
    @State private var categoryResolved = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("整理收藏").font(.title2.weight(.semibold))
            Text(bookmark.displayTitle).foregroundStyle(.secondary).lineLimit(2)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    CategorySelectionView(model: model, category: Binding(get: { category }, set: {
                        category = $0; categoryResolved = true
                    }), requiresSelection: !categoryResolved)
                    if !categoryResolved {
                        Text("服务端分类待整理：\(CategoryCodec.assignment(in: bookmark.labelValues).names.joined(separator: "、"))。请选择一个分类或“未分类”，保存后同步；普通标签会保留。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(8)
            }
            GroupBox {
                LabelSelectionView(model: model, selected: $tags).padding(8)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    guard !isSaving, categoryResolved else { return }
                    saveError = nil
                    isSaving = true
                    let labels = CategoryCodec.replacingCategory(in: tags, with: category)
                    Task {
                        defer { isSaving = false }
                        let saved = await model.updateBookmark(bookmark, patch: BookmarkPatch(labels: labels))
                        if saved { dismiss() }
                        else { saveError = model.syncMessage ?? "保存失败，请重试。" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !categoryResolved)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            let assignment = CategoryCodec.assignment(in: bookmark.labelValues)
            category = assignment.category ?? ""
            categoryResolved = !assignment.hasConflict
            tags = bookmark.labelValues.filter { !CategoryCodec.isCategoryLabel($0) }
        }
    }
}


struct BookmarkRenameView: View {
    @ObservedObject var model: AppModel
    let bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名文章").font(.title3.weight(.semibold))
            TextField("文章标题", text: $newTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            newTitle = bookmark.title ?? bookmark.displayTitle
        }
    }

    private func save() {
        let clean = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSaving, !clean.isEmpty else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            let saved = await model.updateBookmark(bookmark, patch: BookmarkPatch(title: clean))
            if saved { dismiss() }
            else { saveError = model.syncMessage ?? "保存失败，请重试。" }
        }
    }
}
