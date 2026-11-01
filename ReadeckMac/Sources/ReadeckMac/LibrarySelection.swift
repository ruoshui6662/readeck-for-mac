import Foundation

struct LibrarySelection: Equatable {
    private(set) var isSelecting = false
    private(set) var ids: Set<String> = []
    private var anchorID: String?

    mutating func begin() { isSelecting = true }
    mutating func end() { isSelecting = false; ids = []; anchorID = nil }
    mutating func selectOnly(_ id: String) { isSelecting = true; ids = [id]; anchorID = id }
    mutating func selectAll(_ orderedIDs: [String]) { isSelecting = true; ids = Set(orderedIDs); anchorID = orderedIDs.first }
    mutating func replace(_ values: Set<String>, visibleIDs: [String]) {
        isSelecting = true; ids = values.intersection(visibleIDs)
        if anchorID == nil { anchorID = visibleIDs.first { ids.contains($0) } }
    }
    mutating func reconcile(visibleIDs: [String]) {
        ids.formIntersection(visibleIDs)
        if let anchorID, !visibleIDs.contains(anchorID) { self.anchorID = nil }
    }
    /// Returns true when the click is consumed as selection, false to read.
    @discardableResult
    mutating func click(_ id: String, orderedIDs: [String], command: Bool, shift: Bool) -> Bool {
        guard orderedIDs.contains(id), isSelecting || command || shift else { return false }
        isSelecting = true
        if shift, let anchorID, let start = orderedIDs.firstIndex(of: anchorID), let end = orderedIDs.firstIndex(of: id) {
            let range = Set(orderedIDs[min(start,end)...max(start,end)])
            ids = command ? ids.union(range) : range
        } else {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchorID = id
        }
        return true
    }
}
