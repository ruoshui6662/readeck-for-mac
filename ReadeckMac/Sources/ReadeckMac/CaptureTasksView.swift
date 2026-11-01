import SwiftUI

struct CaptureTasksView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var resending: CaptureJob?
    @State private var reimporting: CaptureJob?
    @State private var preview: CapturePackagePreview?
    @State private var previewMessage: String?
    @State private var previewJobID: String?
    @State private var loadingPreview = false
    private var jobs: [CaptureJob] { model.captureJobs.filter { $0.stage != .cancelled }.reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("网页采集任务").font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("正文和图片采集完成后上传到 NAS；需要验证时会打开采集窗口。")
                .font(.caption).foregroundStyle(.secondary)
            if jobs.isEmpty { ContentUnavailableView("暂无采集任务", systemImage: AppSymbol.capture.rawValue) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(jobs) { job in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(job.title.isEmpty ? ((try? CaptureSourceURL(job.url).site.title) ?? "网页文章") : job.title).font(.headline).lineLimit(2)
                                    Spacer()
                                    Text(job.stage.title).font(.caption).foregroundStyle(job.stage == .complete ? .green : .secondary)
                                }
                                if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let report = job.resourceReport {
                                    HStack {
                                        Text("图片 \(report.archivedImages)/\(max(0, report.discoveredImages - report.omittedImages))")
                                        if report.normalizedWidgets > 0 { Text("\(report.normalizedWidgets) 个交互组件已保留说明") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                    if !report.issues.isEmpty {
                                        DisclosureGroup("采集详情") {
                                            ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                                                Text(issue.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                            }
                                        }.font(.caption)
                                    }
                                }
                                HStack(spacing: 10) {
                                    Menu("更多") {
                                        Link("打开原文", destination: URL(string: job.url)!)
                                        if let client = model.client { Link("打开 NAS", destination: client.address.root) }
                                        if job.stage == .failed, job.attemptedAt == nil,
                                           (try? CaptureSourceURL(job.url).site) == .xiaohongshu {
                                            Button("导入已保存的网页…") { reimporting = job }
                                        }
                                    }.menuStyle(.borderlessButton).fixedSize()
                                    if [.failed, .ready, .uploading, .uncertain, .verifying].contains(job.stage) {
                                        Button("本机预览") {
                                            loadingPreview = true; previewMessage = nil
                                            Task {
                                                defer { loadingPreview = false }
                                                do { preview = try await model.capturePreview(id: job.id); previewJobID = job.id }
                                                catch is CancellationError { }
                                                catch { previewMessage = AppLanguage.text("本机采集文件暂不可用，请重新采集。") }
                                            }
                                        }.disabled(loadingPreview)
                                    }
                                    if (job.stage == .capturing || job.stage == .needsInteraction),
                                       (try? CaptureSourceURL(job.url).site) != .xiaohongshu {
                                        Button("显示采集窗口") { model.showCaptureWindow() }
                                    }
                                    if [.failed, .needsInteraction, .uncertain, .verifying].contains(job.stage),
                                       job.attemptedAt != nil || (try? CaptureSourceURL(job.url).site) != .xiaohongshu {
                                        Button(job.attemptedAt == nil ? "重新采集" : "核对结果") { Task { await model.retryCapture(job.id) } }
                                    }
                                    if job.stage == .uncertain {
                                        Button("手动重新上传…") { resending = job }
                                    }
                                    Spacer()
                                    if job.attemptedAt == nil && job.stage != .complete {
                                        Button("取消任务") { Task { await model.cancelCapture(job.id) } }
                                    }
                                }.font(.caption)
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
            }
            if let previewMessage { Text(previewMessage).font(.caption).foregroundStyle(.secondary) }
            Text("未验证成功的采集文件会保留，不受阅读缓存清理影响。上传结果不明确时不会自动重发。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(width: 580, height: 460)
        .sheet(item: $reimporting) { job in
            SaveBookmarkView(model: model, initialURL: job.url,
                             initialCategory: CategoryCodec.assignment(in: job.labels).category ?? "",
                             initialTags: job.labels.filter { !CategoryCodec.isCategoryLabel($0) },
                             initialTitle: job.title, replacingJobID: job.id)
        }
        .sheet(item: $preview) { CapturePackagePreviewView(preview: $0) }
        .onChange(of: model.client?.storageInstance) { _, _ in preview = nil; previewJobID = nil; previewMessage = nil; reimporting = nil }
        .onChange(of: model.captureJobs.map { $0.id + $0.stage.rawValue }) { _, _ in
            if let id = previewJobID, !model.captureJobs.contains(where: { $0.id == id && $0.stage != .cancelled && $0.stage != .complete }) { preview = nil; previewJobID = nil }
        }
        .alert("确认 NAS 中没有这篇文章？", isPresented: Binding(get: { resending != nil }, set: { if !$0 { resending = nil } })) {
            Button("取消", role: .cancel) { resending = nil }
            Button("我已核对，重新上传") {
                if let job = resending { Task { await model.resendUncertainCapture(job.id) } }
                resending = nil
            }
        } message: {
            Text("上次上传结果不明确。请先在 NAS 中核对；如果已经保存，重新上传可能产生重复文章。")
        }
    }
}
