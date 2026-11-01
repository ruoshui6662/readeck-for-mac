import Foundation

struct LibraryAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case deleteBookmark, deleteLabel, renameLabel, createAnnotation, updateAnnotation, deleteAnnotation
    }
    var id = UUID().uuidString
    let kind: Kind
    var bookmarkID: String? = nil
    var targetID: String? = nil
    var label: String? = nil
    var selection: AnnotationSelection? = nil
    var color: String = "yellow"
    var note: String = ""
    var created = Date()
    var attemptedAt: Date? = nil

    var localAnnotationID: String { "pending:\(id)" }
    var optimisticAnnotation: BookmarkAnnotation? {
        guard let selection else { return nil }
        return BookmarkAnnotation(id: localAnnotationID, startSelector: selection.startSelector,
                                  startOffset: selection.startOffset, endSelector: selection.endSelector,
                                  endOffset: selection.endOffset, color: color, note: note, text: selection.text)
    }
}
