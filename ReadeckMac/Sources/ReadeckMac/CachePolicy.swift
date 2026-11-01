import Foundation

enum CacheRetention: Int, CaseIterable, Identifiable {
    case days15 = 15, days30 = 30, days45 = 45, days60 = 60
    var id: Int { rawValue }
    static func stored(_ value: Int) -> CacheRetention { CacheRetention(rawValue: value) ?? .days30 }
    func cutoff(at now: Date) -> Date { now.addingTimeInterval(-Double(rawValue) * 86_400) }
}

struct CacheStatistics: Equatable {
    var articleCount: Int = 0
    var articleBytes: Int64 = 0
    var protectedArticleCount: Int = 0
    var databaseBytes: Int64 = 0
}

struct CacheCleanupResult: Equatable {
    let removedCount: Int
    let removedBytes: Int64
    let protectedCount: Int
}
