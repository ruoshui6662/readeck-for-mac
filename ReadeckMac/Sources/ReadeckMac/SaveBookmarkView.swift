import SwiftUI
import UniformTypeIdentifiers

struct SaveBookmarkView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var title = ""
    @State private var category = ""
    @State private var tags: [String] = []
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var importing = false
    private let replacingJobID: String?
    init(model: AppModel, initialURL: String = "", initialCategory: String = "", initialTags: [String] = [], initialTitle: String = "", replacingJobID: String? = nil) {
        self.model = model; self.replacingJobID = replacingJobID
        _title = State(initialValue: initialTitle)
        _url = State(initialValue: initialURL); _category = State(initialValue: initialCategory); _tags = State(initialValue: initialTags)
    }
    private var isXiaohongshu: Bool {
        guard let input = CaptureInput.url(in: url) else { return false }
        return (try? CaptureSourceURL(input).site) == .xiaohongshu
    }
    private var importTypes: [UTType] {
        if isXiaohongshu { return [UTType(filenameExtension: "mhtml") ?? .data, UTType(filenameExtension: "mht") ?? .data] }
        return [.html, UTType(filenameExtension: "webarchive")!]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保存网页").font(.title2.weight(.semibold))
            TextField("网页地址", text: $url, prompt: Text("https://example.com/article"))
                .textContentType(.URL)
            TextField("标题（可选）", text: $title)
            GroupBox {
                CategorySelectionView(model: model, category: $category).padding(8)
            }
            GroupBox {
                LabelSelectionView(model: model, selected: $tags).padding(8)
            }
            if WechatArticleParser.isWechatArticleURL(url) {
                Button("导入已保存的网页…") { importing = true }
                    .disabled(isSaving)
                Text("可导入同一篇文章的 WebArchive 或含嵌入图片的 HTML；不会读取相邻文件或自动抓取外链图片。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if isXiaohongshu {
                Text("小红书链接自动采集已暂停。如需保存，可导入浏览器已保存的单文件网页。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("选择已保存的网页文件…") { importing = true }
                    .disabled(isSaving)
            }
            if let input = CaptureInput.url(in: url), (try? CaptureSourceURL(input).site) == .baike {
                Text("由 Mac 采集百科正文与图片，完成后自动上传到 NAS。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let saveError {
                Label(saveError, systemImage: AppSymbol.warning.rawValue)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                if replacingJobID == nil && !isXiaohongshu {
                Button("保存") {
                    guard !isSaving else { return }
                    isSaving = true
                    saveError = nil
                    Task {
                        defer { isSaving = false }
                        let saved = await model.saveURL(url, title: title,
                                                        category: category.isEmpty ? nil : category, tags: tags)
                        if saved { dismiss() }
                        else { saveError = model.syncMessage ?? "保存失败，请重试。" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: importTypes) { result in
            switch result {
            case let .success(file):
                isSaving = true
                Task {
                    defer { isSaving = false }
                    let input = CaptureInput.url(in: url) ?? url
                    if await model.importCaptureFile(file, sourceURL: input, title: title, category: category.isEmpty ? nil : category, tags: tags, replacingJobID: replacingJobID) { dismiss() }
                    else { saveError = model.syncMessage ?? "导入失败，请检查网页文件。" }
                }
            case let .failure(error): saveError = error.localizedDescription
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
