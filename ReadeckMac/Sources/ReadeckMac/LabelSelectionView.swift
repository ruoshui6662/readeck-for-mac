import SwiftUI

struct LabelSelectionView: View {
    @ObservedObject var model: AppModel
    @Binding var selected: [String]
    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("标签 · 多选", systemImage: AppSymbol.tag.rawValue).foregroundStyle(.secondary)
                Spacer()
                Button("选择标签…") { isPresented.toggle() }
                    .popover(isPresented: $isPresented) { LabelPicker(model: model, selected: $selected) }
            }
            if !selected.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(selected, id: \.self) { name in
                        Button { selected.removeAll { $0 == name } } label: {
                            HStack(spacing: 5) {
                                Text(name).lineLimit(1)
                                Image(systemName: AppSymbol.close.rawValue).font(.system(size: 9, weight: .semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("从当前文章移除“\(name)”")
                    }
                }
            } else {
                Text("从已有标签中选择，可同时选多个。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct LabelPicker: View {
    @ObservedObject var model: AppModel
    @Binding var selected: [String]
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var name: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [String] {
        LabelCatalog.unique(model.labelCatalog.matchingTags(query) + selected.filter {
            name.isEmpty || $0.localizedCaseInsensitiveContains(name)
        })
    }
    private var pinned: [String] { model.labelPreferences.pinned.filter { matches.contains($0) } }
    private var recent: [String] { model.labelPreferences.recent.filter { matches.contains($0) && !pinned.contains($0) } }
    private var remaining: [String] { matches.filter { !pinned.contains($0) && !recent.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择标签").font(.headline)
                Spacer()
                Text("已选 \(selected.count) 个").font(.caption).foregroundStyle(.secondary)
            }
            TextField("搜索标签", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tagSection("常用", names: pinned)
                    tagSection("最近使用", names: recent)
                    tagSection("全部标签", names: remaining)
                    if matches.isEmpty {
                        Text(name.isEmpty ? "还没有标签，请先在管理页添加。" : "没有找到标签。")
                            .foregroundStyle(.secondary).padding(.vertical, 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            Divider()
            Text("新建、删除和固定常用标签请到“资料库 → 分类与标签…”。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 330)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func tagSection(_ title: String, names: [String]) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(names, id: \.self) { value in
                    HStack {
                        Toggle(value, isOn: Binding(get: { selected.contains(value) }, set: { enabled in
                            if enabled { selected = LabelCatalog.unique(selected + [value]) }
                            else { selected.removeAll { $0 == value } }
                        }))
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 8)
                    }
                }
            }
        }
    }

}

struct CategorySelectionView: View {
    @ObservedObject var model: AppModel
    @Binding var category: String
    var requiresSelection = false
    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        HStack {
            Label("分类 · 单选", systemImage: AppSymbol.category.rawValue).foregroundStyle(.secondary)
            Spacer()
            Button { query = ""; isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    Text(category.isEmpty ? (requiresSelection ? "请选择分类…" : "未分类") : category).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .popover(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("选择分类").font(.headline)
                    TextField("搜索分类", text: $query)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            categoryButton("", title: "未分类")
                            ForEach(model.labelCatalog.categories.filter {
                                query.isEmpty || $0.localizedCaseInsensitiveContains(query)
                            }, id: \.self) { value in categoryButton(value, title: value) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    Text("新建或删除分类请到“资料库 → 分类与标签…”。").font(.caption).foregroundStyle(.secondary)
                }
                .padding(18).frame(width: 290)
            }
        }
    }

    private func categoryButton(_ value: String, title: String) -> some View {
        Button { choose(value) } label: {
            HStack { Label(title, systemImage: AppSymbol.category.rawValue); Spacer()
                if category == value && !requiresSelection { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ value: String) { category = value; isPresented = false }
}
