import SwiftUI

struct LabelManagementView: View {
    @ObservedObject var model: AppModel
    @State private var kind: ManagedLabelKind = .category
    @State private var newName = ""
    @State private var isAdding = false
    @State private var deleting: String?

    private var names: [String] { kind == .category ? model.labelCatalog.categories : model.labelCatalog.tags }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("分类与标签").font(.title3.weight(.semibold))
            Picker("管理类型", selection: $kind) {
                ForEach(ManagedLabelKind.allCases) { value in Text(value.title).tag(value) }
            }.pickerStyle(.segmented)
            HStack(spacing: 8) {
                TextField("新建\(kind.title)名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加", systemImage: "plus") { add() }
                    .disabled(isAdding || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text(kind == .category ? "每篇文章最多一个分类" : "每篇文章可选择多个标签")
                Spacer()
                Text("\(names.count) 个")
            }.font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(names, id: \.self) { name in row(name) }
            }
            .listStyle(.inset)
            .overlay {
                if names.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: kind.symbol).font(.title2)
                        Text("还没有\(kind.title)")
                        Text("在上方添加后，即可在文章中选择。 ").font(.caption)
                    }.foregroundStyle(.secondary)
                }
            }
            if let message = model.taxonomyMessage {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("未使用的分类与标签保存在本 Mac；关联文章后随文章同步到 NAS。删除会移除所有文章上的对应标记，文章仍保留。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(minWidth: 410, idealWidth: 460, minHeight: 380)
        .onChange(of: kind) { _, _ in newName = ""; model.taxonomyMessage = nil }
        .onChange(of: model.client?.storageInstance) { _, _ in
            newName = ""; deleting = nil; model.taxonomyMessage = nil
        }
        .alert(title, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let name = deleting { Task { await model.deleteLabel(name) } }
                deleting = nil
            }
        } message: {
            Text("将从所有文章移除这个标记，并清理常用与最近使用记录。文章及其他标签仍保留；同步后其他客户端也会更新。")
        }
    }

    private func add() {
        guard !isAdding, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAdding = true
        let value = newName
        let submittedKind = kind
        let instance = model.client?.storageInstance
        Task {
            defer { isAdding = false }
            if await model.addManagedLabel(value, kind: submittedKind),
               model.client?.storageInstance == instance, kind == submittedKind, newName == value {
                newName = ""
            }
        }
    }

    private var title: String {
        guard let deleting else { return "删除标记？" }
        let category = CategoryCodec.name(from: deleting)
        return "删除\(category == nil ? "标签" : "分类")“\(category ?? deleting)”？"
    }

    private func row(_ name: String) -> some View {
        let value = kind.serverLabel(name)
        return HStack(spacing: 12) {
            Label(name, systemImage: kind.symbol)
            Spacer()
            if kind == .tag {
                let pinned = model.labelPreferences.pinned.contains(value)
                Button { Task { await model.togglePinnedLabel(value) } } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(pinned ? "取消常用标签" : "固定为常用标签")
                .accessibilityLabel("\(pinned ? "取消常用标签" : "固定常用标签")“\(name)”")
            }
            Button(role: .destructive) { deleting = value } label: { Image(systemName: AppSymbol.delete.rawValue) }
                .buttonStyle(.borderless).help("删除“\(name)”")
                .accessibilityLabel("删除\(kind.title)“\(name)”")
        }.padding(.vertical, 4)
            .accessibilityElement(children: .contain)
    }
}
