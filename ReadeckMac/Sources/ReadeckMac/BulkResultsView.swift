import SwiftUI

struct BulkResultsView: View {
    @ObservedObject var model: AppModel
    let connectionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []
    private var isCurrent: Bool { model.client?.storageInstance == connectionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("批量整理记录").font(.title3.weight(.semibold))
                Spacer()
                if model.isSyncing { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.top, 18)
            Text("仅 NAS 已确认的项目显示为已确认，问题项目会保留。").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            List(model.bulkOperations) { receipt in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(receipt.id) }, set: { value in
                    if value { expanded.insert(receipt.id) } else { expanded.remove(receipt.id) }
                })) {
                    ForEach(receipt.items) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                Image(systemName: icon(entry.status)).foregroundStyle(color(entry.status))
                                Text(entry.title).lineLimit(2)
                                Spacer()
                                Text(AppLanguage.text(entry.status.title)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let message = entry.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            if entry.status == .conflict {
                                HStack {
                                    Button("采用本机") { run { await model.resolveBulkConflict(id: entry.id, keepLocal: true) } }
                                    Button("采用 NAS") { run { await model.resolveBulkConflict(id: entry.id, keepLocal: false) } }
                                }.controlSize(.small)
                            } else if entry.failure == .missing, entry.status == .failed {
                                Button("移除本机更改") { run { await model.discardMissingBulk(id: entry.id) } }.controlSize(.small)
                            }
                        }.padding(.vertical, 6)
                    }
                    if receipt.items.contains(where: { $0.status == .failed && $0.failure != .missing }) {
                        Button("重试未完成项目") { run { await model.retryBulk(id: receipt.id) } }.disabled(model.isSyncing)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(AppLanguage.text(receipt.intent.title)).fontWeight(.medium)
                            Spacer()
                            Text(receipt.created, style: .time).font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(receipt.summary).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }.listStyle(.inset)
            if let message = model.bulkMessage { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
        }
        .padding(.bottom, 14).frame(width: 580, height: 500)
        .disabled(!isCurrent)
        .onAppear { if let latest = model.bulkOperations.first { expanded.insert(latest.id) } }
    }
    private func run(_ work: @escaping @MainActor () async -> Void) {
        guard isCurrent else { return }
        Task { @MainActor in guard isCurrent else { return };await work() }
    }
    private func icon(_ status: BulkItemStatus) -> String {
        switch status {
        case .synced: "checkmark.circle"
        case .queued: "clock"
        case .conflict, .failed: "exclamationmark.circle"
        case .skipped, .superseded: "minus.circle"
        }
    }
    private func color(_ status: BulkItemStatus) -> Color {
        switch status {
        case .synced: .green
        case .failed, .conflict: .orange
        default: .secondary
        }
    }
}
