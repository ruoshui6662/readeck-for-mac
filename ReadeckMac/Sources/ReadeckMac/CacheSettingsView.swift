import SwiftUI

struct CacheSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("正文缓存") {
                Picker("保留时间", selection: Binding(get: { model.cacheRetention }, set: { value in
                    Task { await model.setCacheRetention(value) }
                })) {
                    ForEach(CacheRetention.allCases) { value in Text("\(value.rawValue) 天").tag(value) }
                }
                .disabled(model.isCleaningCache)
                Text("从上次打开文章起计算。应用启动及运行期间每小时检查，自动清理到期正文。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("适用于本机所有 Readeck 连接。").font(.caption).foregroundStyle(.secondary)
            }
            Section("本机空间") {
                if let statistics = model.cacheStatistics {
                    LabeledContent("已缓存正文", value: "\(statistics.articleCount) 篇 · \(size(statistics.articleBytes))")
                    LabeledContent("资料库总占用", value: size(statistics.databaseBytes))
                    LabeledContent("待完成采集文件", value: size(model.captureStorageBytes))
                    Text("采集失败与待同步文件会保留；取消任务可释放对应空间。低空间时暂停新采集包写入。").font(.caption).foregroundStyle(.secondary)
                    Button("整理旧临时采集文件") { Task { await model.cleanCaptureScratch() } }
                        .disabled(model.captureJobs.contains { [.capturing, .importing, .needsInteraction, .uploading].contains($0.stage) })
                    if model.legacyWechatCacheBytes > 0 {
                        LabeledContent("旧版微信图片文件", value: size(model.legacyWechatCacheBytes))
                        Text("旧版文件暂时保留，不会在升级时自动删除。").font(.caption).foregroundStyle(.secondary)
                    }
                    if statistics.protectedArticleCount > 0 {
                        Text("\(statistics.protectedArticleCount) 篇正文含待同步更改，清理时暂时保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else { ProgressView("正在计算缓存占用…").controlSize(.small) }
                HStack {
                    Button(model.isCleaningCache ? "正在清理…" : "立即清理缓存") { Task { await model.clearArticleCache() } }
                        .disabled(model.isCleaningCache)
                    Spacer()
                    Button { Task { await model.refreshCacheStatistics() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("刷新缓存占用").disabled(model.isCleaningCache)
                }
                if let message = model.cacheCleanupMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("清理之后") {
                Text("重新打开文章时，自动从 NAS 下载正文。离线时，已清理的正文需等恢复连接后才能阅读。")
                Text("收藏目录、分类标签、批注和待同步操作会保留；不会删除 NAS 上的文章。")
                Text("阅读图片按需从 NAS 加载。网页采集文件在归档验证成功后移除；失败任务保留，可在采集任务中取消尚未上传的任务以释放空间。")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding()
        .task { await model.refreshCacheStatistics() }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
