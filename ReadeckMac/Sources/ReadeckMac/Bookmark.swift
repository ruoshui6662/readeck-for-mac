import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    var title: String?
    var description: String?
    var siteName: String?
    var site: String?
    var labels: [String]?
    var readProgress: Int?
    var readAnchor: String?
    var loaded: Bool?
    var state: Int?
    var isMarked: Bool?
    var isArchived: Bool?
    var hasArticle: Bool?
    var updated: String?
    var created: String?
    var readingTime: Int?
    var resources: [String: BookmarkResource]?
    var errors: [String]?

    enum CodingKeys: String, CodingKey {
        case id, url, title, description, site, labels, loaded, state, updated, created, resources, errors
        case siteName = "site_name"
        case readProgress = "read_progress"
        case readAnchor = "read_anchor"
        case isMarked = "is_marked"
        case isArchived = "is_archived"
        case hasArticle = "has_article"
        case readingTime = "reading_time"
    }

    var displayTitle: String { title?.isEmpty == false ? title! : url }
    var displaySite: String { siteName ?? site ?? URL(string: url)?.host ?? "" }
    var labelValues: [String] { labels ?? [] }
    var isProcessing: Bool {
        if let state { return state == 2 }
        return loaded == false
    }
    var articleRequestKey: ArticleRequestKey {
        ArticleRequestKey(id: id, state: state, isProcessing: isProcessing, hasArticle: hasArticle)
    }
    var captureFailed: Bool {
        state == 1 || (!isProcessing && hasArticle == false && errors?.isEmpty == false)
    }
    var captureStatus: String? {
        if captureFailed { return "抓取失败" }
        if isProcessing { return "处理中" }
        if errors?.isEmpty == false { return "抓取有异常" }
        return nil
    }
}

struct ArticleRequestKey: Hashable {
    let id: String
    let state: Int?
    let isProcessing: Bool
    let hasArticle: Bool?
}

struct SyncEntry: Decodable {
    let id: String
    let time: String
    let type: String
}

struct PendingSave: Codable, Identifiable {
    var id = UUID().uuidString
    let url: String
    var title: String
    var labels: [String]
    var created = Date()
    var attemptedAt: Date?
}

struct CollectionInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let isPinned: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isPinned = "is_pinned"
    }
}

struct BookmarkResource: Codable, Hashable {
    let src: String
    var width: Int?
    var height: Int?
}

extension Bookmark {
    var coverResources: [BookmarkResource] {
        [resources?["thumbnail"], resources?["image"]].compactMap { $0 }
    }
}
