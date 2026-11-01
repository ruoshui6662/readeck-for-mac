import SwiftUI

struct AnnotationSidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workspace: AnnotationWorkspace
    let bookmark: Bookmark
    let onReveal: (BookmarkAnnotation) -> Void
    let onSave: (AnnotationDraft, String, String) async -> Bool
    var showsHeader = true
    @FocusState private var noteFocused: Bool

    private var items: [BookmarkAnnotation] { model.annotationItems[bookmark.id, default: []] }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
            HStack {
                Text("划线与批注").font(.headline)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { workspace.close() } label: { Image(systemName: AppSymbol.close.rawValue) }
                    .buttonStyle(.plain).help("关闭批注栏").accessibilityLabel("关闭批注栏")
                    .disabled(workspace.isSaving)
            }.padding(16)
            Divider()
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let draft = workspace.draft { editor(draft).id("editor") }
                        if items.isEmpty && workspace.draft == nil {
                            ContentUnavailableView("还没有划线", systemImage: "highlighter",
                                description: Text("选中文字，在选区附近划线或写批注。"))
                                .padding(.top, 32)
                        }
                        ForEach(items) { item in annotationCard(item) }
                    }.padding(14)
                }
                .onChange(of: workspace.draft?.id) { _, value in
                    if value != nil { scroll.scrollTo("editor", anchor: .top); noteFocused = true }
                }
            }
            if let message = model.annotationMessages[bookmark.id] {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(.background)
        .alert("保留未保存的批注？", isPresented: $workspace.needsDiscardConfirmation) {
            Button("继续编辑", role: .cancel) { workspace.keepEditing() }
            Button("放弃更改", role: .destructive) { workspace.discardAndContinue() }
        } message: { Text("当前草稿尚未保存。可继续编辑并保存，或放弃草稿后继续。") }
        .alert("删除这条划线与批注？", isPresented: Binding(get: { workspace.annotationToDelete != nil }, set: { if !$0 { workspace.annotationToDelete = nil } })) {
            Button("取消", role: .cancel) { workspace.annotationToDelete = nil }
            Button("删除", role: .destructive) {
                if let item = workspace.annotationToDelete { Task { await model.deleteAnnotation(item, for: bookmark) } }
                workspace.annotationToDelete = nil
            }
        } message: { Text("同步后也会从 NAS 和其他客户端中删除。") }
    }

    private func editor(_ draft: AnnotationDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.annotation == nil ? "写批注" : "编辑批注").font(.subheadline.weight(.semibold))
            Text(draft.annotation?.text ?? draft.selection?.text ?? "")
                .font(.callout).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
                .padding(.leading, 10).overlay(alignment: .leading) { Capsule().fill(.tint).frame(width: 3) }
            AnnotationColorPicker(selection: $workspace.color).disabled(workspace.isSaving)
            TextEditor(text: $workspace.note).font(.body).frame(minHeight: 76, maxHeight: 140)
                .scrollContentBackground(.hidden).padding(8).focused($noteFocused)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("批注内容").disabled(workspace.isSaving)
            HStack {
                Text("\(workspace.note.unicodeScalars.count)/1024").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { workspace.showList() }.disabled(workspace.isSaving)
                Button(workspace.isSaving ? "正在保存…" : "保存") {
                    guard let snapshot = workspace.beginSave() else { return }
                    Task {
                        let saved = await onSave(snapshot.draft, snapshot.color, snapshot.note)
                        workspace.finishSave(id: snapshot.draft.id, succeeded: saved)
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(workspace.isSaving || workspace.note.unicodeScalars.count > 1024)
            }.controlSize(.small)
            if let error = workspace.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(12)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private func annotationCard(_ item: BookmarkAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { onReveal(item) } label: {
                Text(item.text).font(.callout).lineLimit(5).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(AnnotationColorPicker.colors.first { $0.0 == item.color }?.2 ?? .yellow).frame(width: 3)
                    }
            }.buttonStyle(.plain).help("定位到原文")
            if !item.note.isEmpty { Text(item.note).font(.body).textSelection(.enabled) }
            HStack {
                Button("定位原文") { onReveal(item) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button { workspace.open(AnnotationDraft(selection: nil, annotation: item)) } label: { Image(systemName: AppSymbol.edit.rawValue).frame(minWidth: 24, minHeight: 24) }
                    .help("编辑批注").accessibilityLabel("编辑批注")
                Button(role: .destructive) { workspace.annotationToDelete = item } label: { Image(systemName: AppSymbol.delete.rawValue).frame(minWidth: 24, minHeight: 24) }
                    .help("删除这条划线与批注").accessibilityLabel("删除这条划线与批注")
            }.font(.caption).buttonStyle(.borderless).disabled(workspace.isSaving)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
