import Foundation
import Combine

struct AnnotationScope: Hashable {
    let bookmarkID: String
    let connectionID: String
}

struct AnnotationSaveSnapshot {
    let draft: AnnotationDraft
    let color: String
    let note: String
}

/// Keeps a note in the reader, including when navigation or closing is requested.
@MainActor
final class AnnotationWorkspace: ObservableObject {
    enum Panel: String { case outline, notes }
    @Published private(set) var panel: Panel = .notes
    @Published private(set) var isPresented = false
    @Published var annotationToDelete: BookmarkAnnotation?
    var hasPresentedAlert: Bool { needsDiscardConfirmation || annotationToDelete != nil }
    @Published private(set) var draft: AnnotationDraft?
    @Published var note = ""
    @Published var color = "yellow"
    @Published var needsDiscardConfirmation = false
    @Published private(set) var isSaving = false
    @Published private(set) var scope: AnnotationScope?
    @Published private(set) var error: String?
    private enum Destination { case closed, list, outline, editor(AnnotationDraft), navigation(() -> Void) }
    private var pending: Destination?
    private struct SuspendedDraft {
        let draft: AnnotationDraft
        let note: String
        let color: String
    }
    private var suspended: [AnnotationScope: SuspendedDraft] = [:]

    func bind(to next: AnnotationScope) {
        guard scope != next else { return }
        if let scope, let draft, hasChanges || isSaving {
            suspended[scope] = SuspendedDraft(draft: draft, note: note, color: color)
        }
        pending = nil; needsDiscardConfirmation = false; isSaving = false
        apply(.closed)
        scope = next
        if let previous = suspended.removeValue(forKey: next) {
            apply(.editor(previous.draft))
            note = previous.note; color = previous.color
        }
    }

    func beginSave() -> AnnotationSaveSnapshot? {
        guard !isSaving, let draft, note.unicodeScalars.count <= 1024 else { return nil }
        isSaving = true
        return AnnotationSaveSnapshot(draft: draft, color: color, note: note)
    }

    var hasChanges: Bool {
        guard let draft else { return false }
        return note != (draft.annotation?.note ?? "") || color != (draft.annotation?.color ?? "yellow")
    }
    func open(_ draft: AnnotationDraft) { request(.editor(draft)) }
    func showList() { request(.list) }
    func showOutline() { request(.outline) }
    func close() { request(.closed) }
    func setPresented(_ value: Bool) {
        if value {
            if !isPresented { panel == .outline ? showOutline() : showList() }
        } else { close() }
    }
    func navigate(_ action: @escaping () -> Void) { request(.navigation(action)) }
    func keepEditing() { pending = nil; needsDiscardConfirmation = false }
    func discardAndContinue() {
        let next = pending ?? .list
        pending = nil; needsDiscardConfirmation = false
        apply(next)
    }
    func finishSave(id: UUID, succeeded: Bool) {
        guard draft?.id == id else {
            if succeeded, let key = suspended.first(where: { $0.value.draft.id == id })?.key { suspended[key] = nil }
            return
        }
        isSaving = false
        if succeeded { apply(.list) }
        else { error = "未能保存到本机，草稿仍保留，请重试。" }
    }
    private func request(_ destination: Destination) {
        guard !isSaving else { return }
        if hasChanges {
            pending = destination; needsDiscardConfirmation = true
        } else { apply(destination) }
    }
    private func apply(_ destination: Destination) {
        error = nil; note = ""; color = "yellow"; draft = nil; annotationToDelete = nil
        switch destination {
        case .closed: isPresented = false
        case let .navigation(action): isPresented = false; action()
        case .list: panel = .notes; isPresented = true
        case .outline: panel = .outline; isPresented = true
        case let .editor(value):
            panel = .notes
            isPresented = true; draft = value
            note = value.annotation?.note ?? ""; color = value.annotation?.color ?? "yellow"
        }
    }
}
