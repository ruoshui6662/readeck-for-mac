import Foundation

struct CaptureRefreshSchedule {
    private struct Entry {
        let startedAt: Date
        var nextCheck: Date
        var attempt = 0
    }

    private var entries: [String: Entry] = [:]
    private let intervals: [TimeInterval] = [2, 4, 8, 15]
    private let budget: TimeInterval = 120

    mutating func reconcile(_ bookmarks: [Bookmark], now: Date = Date()) {
        let processing = Set(bookmarks.filter(\.isProcessing).map(\.id))
        entries = entries.filter { processing.contains($0.key) }
        for id in processing where entries[id] == nil {
            entries[id] = Entry(startedAt: now, nextCheck: now.addingTimeInterval(intervals[0]))
        }
    }

    func nextDelay(now: Date = Date()) -> TimeInterval? {
        entries.values.compactMap { entry -> TimeInterval? in
            let deadline = entry.startedAt.addingTimeInterval(budget)
            guard now < deadline, entry.nextCheck < deadline else { return nil }
            return max(0, entry.nextCheck.timeIntervalSince(now))
        }.min()
    }

    mutating func takeDueIDs(now: Date = Date()) -> [String] {
        let due = entries.filter { _, entry in
            now.timeIntervalSince(entry.startedAt) < budget && entry.nextCheck <= now
        }.sorted {
            if $0.value.nextCheck == $1.value.nextCheck { return $0.key < $1.key }
            return $0.value.nextCheck < $1.value.nextCheck
        }.prefix(10).map(\.key)

        for id in due {
            guard var entry = entries[id] else { continue }
            entry.attempt += 1
            entry.nextCheck = now.addingTimeInterval(intervals[min(entry.attempt, intervals.count - 1)])
            entries[id] = entry
        }
        // Keep expired entries until they finish so a normal sync cannot renew their budget.
        return due
    }
}
