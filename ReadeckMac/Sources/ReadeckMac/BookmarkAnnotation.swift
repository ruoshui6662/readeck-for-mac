import Foundation

struct AnnotationSelection: Codable, Equatable, Hashable {
    let startSelector: String
    let startOffset: Int
    let endSelector: String
    let endOffset: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case text
        case startSelector = "start_selector"
        case startOffset = "start_offset"
        case endSelector = "end_selector"
        case endOffset = "end_offset"
    }
}

struct BookmarkAnnotation: Codable, Identifiable, Hashable {
    let id: String
    let startSelector: String
    let startOffset: Int
    let endSelector: String
    let endOffset: Int
    var color: String
    var note: String
    let text: String
    var created: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, color, note, text, created
        case startSelector = "start_selector"
        case startOffset = "start_offset"
        case endSelector = "end_selector"
        case endOffset = "end_offset"
    }

    var selection: AnnotationSelection {
        AnnotationSelection(startSelector: startSelector, startOffset: startOffset,
                            endSelector: endSelector, endOffset: endOffset, text: text)
    }

    func matches(selection: AnnotationSelection, color: String, note: String) -> Bool {
        startSelector == selection.startSelector && startOffset == selection.startOffset &&
        endSelector == selection.endSelector && endOffset == selection.endOffset &&
        self.color == color && self.note == note
    }
}
