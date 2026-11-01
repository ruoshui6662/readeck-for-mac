import Foundation

enum LibraryListDensity: String, CaseIterable, Identifiable {
    case standard, compact
    var id: String { rawValue }
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case recent, title
    var id: String { rawValue }
    var label: String { self == .recent ? "最近保存" : "标题 A–Z" }

    func sorted(_ bookmarks: [Bookmark]) -> [Bookmark] {
        bookmarks.enumerated().sorted { lhs, rhs in
            switch self {
            case .recent:
                let left = lhs.element.created ?? "", right = rhs.element.created ?? ""
                return left == right ? lhs.offset < rhs.offset : left > right
            case .title:
                let order = lhs.element.displayTitle.localizedStandardCompare(rhs.element.displayTitle)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }
        }.map(\.element)
    }
}

/// Width belongs to the collection pane, so sidebar resizing follows the same
/// breakpoints as window resizing. Optional details yield before the title does.
struct LibraryListMetrics {
    let rowWidth: CGFloat
    let density: LibraryListDensity
    private let thumbnails: Bool
    init(availableWidth: CGFloat, density: LibraryListDensity, thumbnails: Bool) {
        rowWidth = min(1040, max(0, availableWidth.isFinite ? availableWidth - 44 : 0))
        self.density = density
        self.thumbnails = thumbnails
    }
    var narrow: Bool { rowWidth < 660 }
    var small: Bool { rowWidth < 540 }
    var showsCover: Bool { thumbnails && !small }
    var showsSummary: Bool { density == .standard && !narrow }
    var showsTags: Bool { density == .standard && !narrow }
    var showsCategory: Bool { !small }
    var showsProgressBar: Bool { !small }
    var showsInlineActions: Bool { !narrow }
    var coverWidth: CGFloat { density == .compact ? 68 : narrow ? 82 : 100 }
    var coverHeight: CGFloat { density == .compact ? 58 : 78 }
    var minimumHeight: CGFloat { density == .compact ? 94 : narrow ? 120 : 134 }
    var rowSpacing: CGFloat { density == .compact ? 4 : 8 }
}
