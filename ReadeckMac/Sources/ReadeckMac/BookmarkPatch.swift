import Foundation

struct BookmarkPatch: Codable, Equatable {
    var title: String?
    var labels: [String]?
    var isMarked: Bool?
    var isArchived: Bool?
    var readProgress: Int?

    var isEmpty: Bool {
        title == nil && labels == nil && isMarked == nil && isArchived == nil && readProgress == nil
    }

    mutating func merge(_ newer: BookmarkPatch) {
        if let title = newer.title { self.title = title }
        if let labels = newer.labels { self.labels = labels }
        if let isMarked = newer.isMarked { self.isMarked = isMarked }
        if let isArchived = newer.isArchived { self.isArchived = isArchived }
        if let readProgress = newer.readProgress {
            self.readProgress = max(self.readProgress ?? 0, readProgress)
        }
    }

    mutating func fillMissing(from other: BookmarkPatch) {
        if title == nil { title = other.title }
        if labels == nil { labels = other.labels }
        if isMarked == nil { isMarked = other.isMarked }
        if isArchived == nil { isArchived = other.isArchived }
        if readProgress == nil { readProgress = other.readProgress }
    }

    mutating func replaceFields(with other: BookmarkPatch) {
        if let title = other.title { self.title = title }
        if let labels = other.labels { self.labels = labels }
        if let isMarked = other.isMarked { self.isMarked = isMarked }
        if let isArchived = other.isArchived { self.isArchived = isArchived }
        if let readProgress = other.readProgress { self.readProgress = readProgress }
    }

    func baseline(from bookmark: Bookmark) -> BookmarkPatch {
        BookmarkPatch(
            title: title == nil ? nil : (bookmark.title ?? ""),
            labels: labels == nil ? nil : bookmark.labelValues,
            isMarked: isMarked == nil ? nil : (bookmark.isMarked ?? false),
            isArchived: isArchived == nil ? nil : (bookmark.isArchived ?? false),
            readProgress: readProgress == nil ? nil : (bookmark.readProgress ?? 0)
        )
    }

    func applying(to bookmark: Bookmark) -> Bookmark {
        var result = bookmark
        if let title { result.title = title }
        if let labels { result.labels = labels }
        if let isMarked { result.isMarked = isMarked }
        if let isArchived { result.isArchived = isArchived }
        if let readProgress { result.readProgress = max(result.readProgress ?? 0, readProgress) }
        return result
    }

    func isSatisfied(by bookmark: Bookmark) -> Bool {
        (title == nil || (bookmark.title ?? "") == title) &&
        (labels.map { Set($0) == Set(bookmark.labelValues) } ?? true) &&
        (isMarked == nil || isMarked == (bookmark.isMarked ?? false)) &&
        (isArchived == nil || isArchived == (bookmark.isArchived ?? false)) &&
        (readProgress.map { (bookmark.readProgress ?? 0) >= $0 } ?? true)
    }

    func conflicts(with bookmark: Bookmark, baseline: BookmarkPatch) -> Bool {
        if let title, let original = baseline.title,
           (bookmark.title ?? "") != original && (bookmark.title ?? "") != title { return true }
        if let labels, let original = baseline.labels,
           Set(bookmark.labelValues) != Set(original) && Set(bookmark.labelValues) != Set(labels) { return true }
        if let isMarked, let original = baseline.isMarked,
           (bookmark.isMarked ?? false) != original && (bookmark.isMarked ?? false) != isMarked { return true }
        if let isArchived, let original = baseline.isArchived,
           (bookmark.isArchived ?? false) != original && (bookmark.isArchived ?? false) != isArchived { return true }
        return false
    }

    var fields: [String: Any] {
        var result: [String: Any] = [:]
        if let title { result["title"] = title }
        if let labels { result["labels"] = labels }
        if let isMarked { result["is_marked"] = isMarked }
        if let isArchived { result["is_archived"] = isArchived }
        if let readProgress { result["read_progress"] = readProgress }
        return result
    }
}

struct PendingMutation: Codable, Equatable, Identifiable {
    let bookmarkID: String
    var desired: BookmarkPatch
    var baseline: BookmarkPatch
    var revision: String
    let created: Date

    var id: String { bookmarkID }

    init(bookmark: Bookmark, patch: BookmarkPatch) {
        bookmarkID = bookmark.id
        desired = patch
        baseline = patch.baseline(from: bookmark)
        revision = UUID().uuidString
        created = Date()
    }

    mutating func merge(_ patch: BookmarkPatch, baselineBookmark: Bookmark) {
        baseline.fillMissing(from: patch.baseline(from: baselineBookmark))
        desired.merge(patch)
        revision = UUID().uuidString
    }
}
