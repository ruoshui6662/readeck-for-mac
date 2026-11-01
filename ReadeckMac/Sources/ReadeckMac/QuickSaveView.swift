import SwiftUI

struct QuickSaveView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var url = ""
    @State private var isSaving = false
    @State private var category = ""
    @State private var tags: [String] = []
    @State private var showCaptureTasks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
                Text("Readeck").font(.headline)
                Spacer()
                if model.isSyncing { ProgressView().controlSize(.small) }
            }
            if model.connected {
                TextField("粘贴网页地址", text: $url)
                    .textContentType(.URL)
                    .onSubmit { save() }
                DisclosureGroup("分类与标签") {
                    VStack(spacing: 12) {
                        GroupBox { CategorySelectionView(model: model, category: $category).padding(4) }
                        GroupBox { LabelSelectionView(model: model, selected: $tags).padding(4) }
                    }.padding(.top, 8)
                }
                HStack {
                    Text("待同步 \(model.pending.count + model.pendingMutations.count) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let message = model.syncMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text("请先连接 Readeck 服务端。")
                    .foregroundStyle(.secondary)
            }
            Button("网页采集任务") { showCaptureTasks = true }
            Divider()
            Button("打开资料库") { openWindow(id: "library") }
            if model.isSyncing {
                Button("取消同步") { model.cancelSync() }
            } else {
                Button("立即同步") { Task { await model.sync() } }.disabled(!model.connected)
            }
        }
        .sheet(isPresented: $showCaptureTasks) { CaptureTasksView(model: model) }
        .padding(16)
        .frame(width: 330)
    }

    private func save() {
        guard !isSaving, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        let value = url
        Task {
            defer { isSaving = false }
            let saved = await model.saveURL(value, category: category.isEmpty ? nil : category, tags: tags)
            if saved && url == value { url = ""; category = ""; tags = [] }
        }
    }
}
