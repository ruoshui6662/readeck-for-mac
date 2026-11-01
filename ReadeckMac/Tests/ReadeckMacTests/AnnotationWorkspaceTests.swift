import XCTest
@testable import ReadeckMac

@MainActor
final class AnnotationWorkspaceTests: XCTestCase {
    func testOutlineSwitchProtectsDirtyNoteAndNewAnnotationReturnsToNotes() {
        let workspace = AnnotationWorkspace()
        workspace.showOutline()
        XCTAssertTrue(workspace.isPresented)
        XCTAssertEqual(workspace.panel, .outline)
        workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        XCTAssertEqual(workspace.panel, .notes)
        workspace.note = "不能丢失的批注"
        workspace.showOutline()
        XCTAssertTrue(workspace.needsDiscardConfirmation)
        XCTAssertEqual(workspace.panel, .notes)
        XCTAssertEqual(workspace.note, "不能丢失的批注")
        workspace.keepEditing()
        workspace.showOutline()
        workspace.discardAndContinue()
        XCTAssertEqual(workspace.panel, .outline)
        XCTAssertNil(workspace.draft)
    }

    private var selection: AnnotationSelection { AnnotationSelection(startSelector: "p[1]", startOffset: 0, endSelector: "p[1]", endOffset: 2, text: "中文") }
    func testDirtyDraftBlocksCloseAndSwitchUntilExplicitDiscard() {
        let workspace = AnnotationWorkspace()
        let first = AnnotationDraft(selection: selection, annotation: nil)
        workspace.open(first)
        workspace.note = "草稿"
        workspace.close()
        XCTAssertTrue(workspace.isPresented)
        XCTAssertTrue(workspace.needsDiscardConfirmation)
        XCTAssertEqual(workspace.note, "草稿")
        workspace.keepEditing()
        let second = AnnotationDraft(selection: selection, annotation: nil)
        workspace.open(second)
        XCTAssertEqual(workspace.draft?.id, first.id)
        workspace.discardAndContinue()
        XCTAssertEqual(workspace.draft?.id, second.id)
        XCTAssertEqual(workspace.note, "")
    }
    func testInspectorPresentationEchoDoesNotReplaceNewEditorWithList() {
        let workspace = AnnotationWorkspace()
        let draft = AnnotationDraft(selection: selection, annotation: nil)
        workspace.open(draft)
        workspace.setPresented(true)
        XCTAssertEqual(workspace.draft?.id, draft.id)
        XCTAssertTrue(workspace.isPresented)
    }

    func testNavigationWaitsForDraftDecision() {
        let workspace = AnnotationWorkspace()
        workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        workspace.note = "unsaved"
        var navigated = false
        workspace.navigate { navigated = true }
        XCTAssertFalse(navigated)
        XCTAssertTrue(workspace.isPresented)
        workspace.discardAndContinue()
        XCTAssertTrue(navigated)
        XCTAssertNil(workspace.draft)
        XCTAssertFalse(workspace.isPresented)
    }

    func testUnexpectedArticleSwitchSeparatesDraftsAndLateSaveCannotClearAnotherArticle() {
        let workspace = AnnotationWorkspace()
        let first = AnnotationScope(bookmarkID: "A", connectionID: "one")
        let second = AnnotationScope(bookmarkID: "B", connectionID: "one")
        workspace.bind(to: first)
        workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        workspace.note = "draft A"
        let identity = workspace.draft!.id
        workspace.bind(to: second)
        XCTAssertNil(workspace.draft)
        workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        workspace.note = "draft B"
        workspace.finishSave(id: identity, succeeded: true)
        XCTAssertEqual(workspace.note, "draft B")
        workspace.bind(to: first)
        XCTAssertNil(workspace.draft, "A completed save must clear only the suspended A draft")
        workspace.bind(to: second)
        XCTAssertEqual(workspace.note, "draft B")
        workspace.bind(to: AnnotationScope(bookmarkID: "B", connectionID: "other-account"))
        XCTAssertNil(workspace.draft)
    }

    func testSaveSnapshotLocksDuplicateSaveAndNavigationUntilCompletion() {
        let workspace = AnnotationWorkspace()
        workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        workspace.note = "saved text"
        let snapshot = workspace.beginSave()
        XCTAssertEqual(snapshot?.note, "saved text")
        XCTAssertTrue(workspace.isSaving)
        XCTAssertNil(workspace.beginSave())
        var navigated = false
        workspace.navigate { navigated = true }
        XCTAssertFalse(navigated)
        workspace.finishSave(id: snapshot!.draft.id, succeeded: false)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertEqual(workspace.note, "saved text")
    }

    func testFailedSaveKeepsDraftAndSuccessfulSaveReturnsToList() {
        let workspace = AnnotationWorkspace()
        workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        workspace.note = "keep"
        let identity = workspace.draft!.id
        workspace.finishSave(id: identity, succeeded: false)
        XCTAssertEqual(workspace.note, "keep")
        XCTAssertNotNil(workspace.error)
        workspace.finishSave(id: UUID(), succeeded: true)
        XCTAssertNotNil(workspace.draft)
        workspace.finishSave(id: identity, succeeded: true)
        XCTAssertNil(workspace.draft)
        XCTAssertTrue(workspace.isPresented)
    }
}
