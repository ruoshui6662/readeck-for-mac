import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            connectionSettings.tabItem { Label("连接与同步", systemImage: AppSymbol.connection.rawValue) }
            ReaderAppearanceView().tabItem { Label("阅读", systemImage: AppSymbol.reading.rawValue) }
            LabelManagementView(model: model).tabItem { Label("分类与标签", systemImage: AppSymbol.category.rawValue) }
            CacheSettingsView(model: model).tabItem { Label("缓存", systemImage: AppSymbol.cache.rawValue) }
        }
        .frame(width: 560, height: 650)
    }

    private var connectionSettings: some View {
        Form {
            Section("连接") {
                LabeledContent("服务端", value: model.client?.address.root.absoluteString ?? "未连接")
                if let version = model.serverVersion {
                    LabeledContent("Readeck 版本", value: version)
                }
                Button("断开连接") { model.disconnect() }
                    .disabled(!model.connected)
            }
            Section("同步") {
                LabeledContent("同步状态", value: model.isSyncing ? "正在同步" : model.nextRetryAt != nil ? "等待自动重试" : "空闲")
                if let lastSync = model.lastSyncAt {
                    LabeledContent("上次成功同步") { Text(lastSync, style: .relative) }
                }
                LabeledContent("待上传网页", value: String(model.pending.count))
                if model.isSyncing {
                    Button("取消同步") { model.cancelSync() }
                } else {
                    Button("立即同步") { Task { await model.sync() } }.disabled(!model.connected)
                }
            }
            Section("网络") {
                Text("支持 HTTP 和 HTTPS。HTTP 连接会以明文传输授权信息，仅建议在可信局域网或 VPN 中使用。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
