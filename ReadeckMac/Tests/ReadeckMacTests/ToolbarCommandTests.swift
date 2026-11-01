import AppKit
import XCTest
@testable import ReadeckMac

@MainActor
final class ToolbarCommandTests: XCTestCase {
    func testSelectionModeBlocksBrowsingLayoutAndManagementCommands() {
        var calls: [LibraryCommandContext.Action] = []
        let selecting = LibraryCommandContext(isReading:false,canSelect:true,isSelecting:true,isFocused:false) { calls.append($0) }
        for action in [LibraryCommandContext.Action.cards,.list,.captureTasks,.taxonomy] { selecting.perform(action) }
        XCTAssertTrue(calls.isEmpty)
        selecting.perform(.bulkResults);selecting.perform(.select)
        XCTAssertEqual(calls,[.bulkResults,.select])
    }
    func testReaderMenuDoesNotRunBehindAnotherPresentation() {
        var calls: [ReaderCommandContext.Action] = []
        let context = ReaderCommandContext(isEnabled:false,isMarked:false,isArchived:false,notesVisible:false) { calls.append($0) }
        context.perform(.appearance);context.perform(.notes);context.perform(.star);context.perform(.archive)
        XCTAssertTrue(calls.isEmpty)
    }
    func testAlertBlocksGlobalCommandsAndEmptySelectionCanStillFinish() {
        var calls: [LibraryCommandContext.Action] = []
        let modal = LibraryCommandContext(isReading: true, canSelect: false, isSelecting: false, isFocused: false, isPresentingAlert: true) { calls.append($0) }
        modal.perform(.captureTasks);modal.perform(.bulkResults);modal.perform(.taxonomy)
        XCTAssertTrue(calls.isEmpty)
        let emptySelection = LibraryCommandContext(isReading: false, canSelect: false, isSelecting: true, isFocused: false) { calls.append($0) }
        emptySelection.perform(.select)
        XCTAssertEqual(calls, [.select])
    }
    func testAnnotationDeletionAlertIsScopedAndBlocksNewPresentations() {
        let workspace = AnnotationWorkspace()
        workspace.bind(to: AnnotationScope(bookmarkID: "a", connectionID: "one"))
        workspace.annotationToDelete = BookmarkAnnotation(id:"mark",startSelector:"p[1]",startOffset:0,endSelector:"p[1]",endOffset:2,color:"yellow",note:"",text:"阅读")
        XCTAssertTrue(workspace.hasPresentedAlert)
        workspace.bind(to: AnnotationScope(bookmarkID: "b", connectionID: "one"))
        XCTAssertNil(workspace.annotationToDelete)
        XCTAssertFalse(workspace.hasPresentedAlert)
    }
    func testFocusedCommandsCannotSelectOrChangeHiddenReaderCollection() {
        var calls: [LibraryCommandContext.Action] = []
        let context = LibraryCommandContext(isReading: true, canSelect: true, isSelecting: false, isFocused: false) { calls.append($0) }
        context.perform(.select);context.perform(.cards);context.perform(.list)
        XCTAssertTrue(calls.isEmpty)
        context.perform(.focus);context.perform(.captureTasks);context.perform(.bulkResults);context.perform(.taxonomy)
        XCTAssertEqual(calls, [.focus,.captureTasks,.bulkResults,.taxonomy])
    }
    func testCollectionCommandsKeepEmptyTaskAndResultEntrypointsAvailable() {
        var calls: [LibraryCommandContext.Action] = []
        let context = LibraryCommandContext(isReading: false, canSelect: false, isSelecting: false, isFocused: false) { calls.append($0) }
        context.perform(.select);context.perform(.focus)
        XCTAssertTrue(calls.isEmpty)
        context.perform(.cards);context.perform(.list);context.perform(.captureTasks);context.perform(.bulkResults)
        XCTAssertEqual(calls, [.cards,.list,.captureTasks,.bulkResults])
    }
    func testApprovedSymbolsExistInTargetSystemAndNotesAreNotHighlightAction() {
        for symbol in AppSymbol.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil), symbol.rawValue)
        }
        XCTAssertNotEqual(AppSymbol.notes, AppSymbol.highlight)
        XCTAssertNotEqual(AppSymbol.select, AppSymbol.confirmed)
    }
}
