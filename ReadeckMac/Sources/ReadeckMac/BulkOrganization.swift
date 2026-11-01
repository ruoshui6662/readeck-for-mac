import Foundation

enum BulkCategoryChange: Codable, Equatable, Hashable {
    case keep, clear, set(String)
}

enum BulkEditIntent: Codable, Equatable {
    case organize(category: BulkCategoryChange, adding: [String], removing: [String])
    case star(Bool), archive(Bool), delete

    var needsLabels: Bool { if case .organize = self { return true }; return false }
    var isDeletion: Bool { self == .delete }
    var title: String {
        switch self {
        case .organize: "分类与标签"
        case .star(true): "设为星标"
        case .star(false): "取消星标"
        case .archive(true): "归档"
        case .archive(false): "移回收件箱"
        case .delete: "永久删除"
        }
    }
    func patch(for item: Bookmark) throws -> BookmarkPatch {
        switch self {
        case .star(let value): return BookmarkPatch(isMarked: value)
        case .archive(let value): return BookmarkPatch(isArchived: value)
        case .delete: return BookmarkPatch()
        case let .organize(category, additions, removals):
            guard let original = item.labels else { throw BulkOrganizationError.invalid(BulkText.format("“%@”缺少完整标签资料，请联网刷新后重试。", item.displayTitle)) }
            let add = try additions.map { try ManagedLabelKind.tag.validatedName($0) }
            let remove = try removals.map { try ManagedLabelKind.tag.validatedName($0) }
            guard Set(add).isDisjoint(with: Set(remove)) else { throw BulkOrganizationError.invalid("同一标签不能同时添加和移除。") }
            var labels = original
            switch category {
            case .keep: break
            case .clear: labels = CategoryCodec.replacingCategory(in: labels, with: nil)
            case .set(let name): labels = CategoryCodec.replacingCategory(in: labels, with: try ManagedLabelKind.category.validatedName(name))
            }
            labels.removeAll { remove.contains($0) }
            labels = try CategoryCodec.labelsForWrite(labels + add)
            return BookmarkPatch(labels: labels)
        }
    }
}

enum BulkOrganizationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum BulkItemStatus: String, Codable { case queued, synced, conflict, failed, skipped, superseded
    var title: String {
        switch self {
        case .queued: "待同步"
        case .synced: "已确认"
        case .conflict: "存在冲突"
        case .failed: "未完成"
        case .skipped: "无需更改"
        case .superseded: "已被后续处理替代"
        }
    }
    var isUnfinished: Bool { self == .queued || self == .conflict || self == .failed }
}

enum BulkFailure: String, Codable { case transport, rejected, missing }

struct BulkReceiptItem: Codable, Equatable, Identifiable {
    var id: String { bookmarkID }
    let bookmarkID: String
    let title: String
    var patch: BookmarkPatch?
    var mutationRevision: String?
    var actionID: String?
    var status: BulkItemStatus
    var failure: BulkFailure?
    var message: String?
}

struct BulkOperationReceipt: Codable, Equatable, Identifiable {
    let id: String
    let intent: BulkEditIntent
    let created: Date
    var items: [BulkReceiptItem]
    var waitingCount: Int { items.filter { $0.status.isUnfinished }.count }
    var problemCount: Int { items.filter { $0.status == .conflict || $0.status == .failed }.count }
    var confirmedCount: Int { items.filter { $0.status == .synced }.count }
    var summary: String {
        if waitingCount == 0 { return BulkText.format("本批次已处理 · %lld 篇已确认", confirmedCount) }
        return BulkText.format("%lld 篇 · %lld 篇已确认 · %lld 篇待处理", items.count, confirmedCount, waitingCount)
    }
}

extension BookmarkPatch {
    /// Unrelated queued edits can share a mutation. Only overwritten fields
    /// supersede an earlier batch receipt; revision changes alone do not.
    func includes(_ other: BookmarkPatch) -> Bool {
        (other.title == nil || title == other.title) &&
        (other.labels == nil || Set(labels ?? []) == Set(other.labels!)) &&
        (other.isMarked == nil || isMarked == other.isMarked) &&
        (other.isArchived == nil || isArchived == other.isArchived) &&
        (other.readProgress == nil || (readProgress ?? -1) >= other.readProgress!)
    }
}

enum BulkText {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: AppLanguage.text(key), locale: Locale.current, arguments: arguments)
    }
}
