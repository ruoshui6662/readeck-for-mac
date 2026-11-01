import XCTest
@testable import ReadeckMac

final class ManagedTaxonomyTests: XCTestCase {
    func testOldPreferencesDecodeWithoutNewDefinitionKeys() throws {
        let old = Data(#"{"pinned":["AI"],"recent":["阅读"],"revision":4}"#.utf8)
        let value = try JSONDecoder().decode(LabelPreferences.self, from: old)
        XCTAssertEqual(value.pinned, ["AI"])
        XCTAssertEqual(value.revision, 4)
        XCTAssertTrue(value.managedCategories.isEmpty)
        XCTAssertTrue(value.managedTags.isEmpty)
    }

    func testEmptyDefinitionsSurviveReopenAndCategoryAndTagCanShareDisplayName() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("library.sqlite")
        let store = try LocalStore(url: database)
        _ = try await store.addManagedLabel("设计", kind: .category, instance: "one")
        _ = try await store.addManagedLabel("设计", kind: .tag, instance: "one")
        let reopened = try LocalStore(url: database)
        let value = try await reopened.labelPreferences(instance: "one")
        let catalog = LabelCatalog(bookmarks: [], pending: [], remoteNames: [], preferences: value)
        XCTAssertEqual(catalog.categories, ["设计"])
        XCTAssertEqual(catalog.tags, ["设计"])
        let other = try await reopened.labelPreferences(instance: "two")
        XCTAssertTrue(other.managedCategories.isEmpty)
        XCTAssertTrue(other.managedTags.isEmpty)
    }

    func testInvalidReservedAndDuplicateNamesAreRejectedWithoutCreatingDefinitions() throws {
        var value = LabelPreferences()
        try value.addManagedLabel("  科技  ", kind: .category)
        XCTAssertEqual(value.managedCategories, ["科技"])
        XCTAssertThrowsError(try value.addManagedLabel("科技", kind: .category))
        XCTAssertThrowsError(try value.addManagedLabel("\n ", kind: .tag))
        XCTAssertThrowsError(try value.addManagedLabel("mac-category/hidden", kind: .tag))
        XCTAssertThrowsError(try value.addManagedLabel("未分类", kind: .category))
        XCTAssertThrowsError(try value.addManagedLabel("multi\nline", kind: .tag))
    }

    func testDeleteRemovesManagedDefinitionsAndPendingDeletionCannotBeRecreatedEarly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        _ = try await store.addManagedLabel("科技", kind: .category, instance: "one")
        try await store.enqueueDeleteLabel(name: CategoryCodec.label(for: "科技"), instance: "one")
        let value = try await store.labelPreferences(instance: "one")
        XCTAssertTrue(value.managedCategories.isEmpty)
        do {
            _ = try await store.addManagedLabel("科技", kind: .category, instance: "one")
            XCTFail("A still-pending global delete must not erase a newly reused definition")
        } catch {}
    }

    func testRemoteCategoryConflictIsVisibleWithoutChoosingOneSilently() throws {
        let labels = [CategoryCodec.label(for: "科技"), "AI", CategoryCodec.label(for: "工作")]
        let assignment = CategoryCodec.assignment(in: labels)
        XCTAssertTrue(assignment.hasConflict)
        XCTAssertNil(assignment.category)
        XCTAssertEqual(Set(assignment.names), Set(["科技", "工作"]))
        XCTAssertThrowsError(try CategoryCodec.labelsForWrite(labels))
        let fixed = try CategoryCodec.labelsForWrite(CategoryCodec.replacingCategory(in: labels, with: "工作"))
        XCTAssertEqual(fixed, ["AI", CategoryCodec.label(for: "工作")])
    }

    func testMalformedReservedCategoryMarkersRemainConflictsUntilExplicitlyResolved() throws {
        for marker in ["mac-category/", "mac-category/%ZZ", "mac-category/%20", "mac-category/%0A", "mac-category/%E6%9C%AA%E5%88%86%E7%B1%BB"] {
            XCTAssertTrue(CategoryCodec.assignment(in: ["keep", marker]).hasConflict, marker)
            XCTAssertThrowsError(try CategoryCodec.labelsForWrite(["keep", marker]), marker)
            XCTAssertEqual(try CategoryCodec.labelsForWrite(CategoryCodec.replacingCategory(in: ["keep", marker], with: nil)), ["keep"])
        }
    }

    func testLegacyEquivalentCategoryMarkersBecomeOneCanonicalCategoryOnWrite() throws {
        let labels = ["mac-category/科技", CategoryCodec.label(for: "科技"), "AI", "阅读", "AI"]
        XCTAssertEqual(CategoryCodec.assignment(in: labels).category, "科技")
        XCTAssertFalse(CategoryCodec.assignment(in: labels).hasConflict)
        let canonical = try CategoryCodec.labelsForWrite(labels)
        XCTAssertEqual(canonical, ["AI", "阅读", CategoryCodec.label(for: "科技")])
    }

    func testUpdatingUncertainLegacySavePreservesTheOriginalRequestLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        var pending = PendingSave(url: "https://example.com", title: "", labels: ["mac-category/A/B", "keep"])
        pending.attemptedAt = Date()
        try await store.updatePending(pending, instance: "one")
        let saved = try await store.pending(instance: "one")
        XCTAssertEqual(saved.first?.labels, pending.labels, "An uncertain POST must retain the label identity actually sent")
        try await store.enqueueDeleteLabel(name: "unrelated", instance: "one")
        let afterDelete = try await store.pending(instance: "one")
        XCTAssertEqual(afterDelete.first?.labels, pending.labels)
    }

    func testLegacyInvalidSaveDoesNotBlockUnrelatedGlobalDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let pending = PendingSave(url: "https://example.com", title: "", labels: ["mac-category/未分类", "keep"])
        try await store.updatePending(pending, instance: "one")
        try await store.enqueueDeleteLabel(name: "unrelated", instance: "one")
        let saved = try await store.pending(instance: "one")
        XCTAssertEqual(saved.first?.labels, pending.labels)
    }

    func testLegacyMutationSurvivesUnrelatedEditsAndGlobalDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let item = Bookmark(id: "one", url: "https://example.com", labels: ["keep"])
        let labels = ["mac-category/未分类", "keep"]
        try await store.upsert(item, instance: "one")
        let legacy = PendingMutation(bookmark: item, patch: BookmarkPatch(labels: labels))
        try await store.enqueueMutation(legacy, instance: "one")
        try await store.mergeMutation(bookmark: item, patch: BookmarkPatch(isMarked: true), instance: "one")
        try await store.enqueueDeleteLabel(name: "unrelated", instance: "one")
        let saved = try await store.mutation(id: item.id, instance: "one")
        XCTAssertEqual(saved?.desired.labels, labels)
        XCTAssertEqual(saved?.desired.isMarked, true)
    }

    func testQueueRejectsMultipleCategoriesButAllowsUnrelatedEditsToRemoteConflict() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let labels = [CategoryCodec.label(for: "A"), CategoryCodec.label(for: "B"), "keep"]
        let book = Bookmark(id: "one", url: "https://example.com", labels: labels)
        try await store.upsert(book, instance: "one")
        do {
            try await store.enqueue(PendingSave(url: book.url, title: "", labels: labels), instance: "one")
            XCTFail("Multiple category write accepted")
        } catch {}
        do {
            try await store.mergeMutation(bookmark: book, patch: BookmarkPatch(labels: labels), instance: "one")
            XCTFail("Multiple category patch accepted")
        } catch {}
        try await store.mergeMutation(bookmark: book, patch: BookmarkPatch(isMarked: true), instance: "one")
        let cached = try await store.bookmark(id: book.id, instance: "one")
        XCTAssertEqual(cached?.labels, labels)
        let mutation = try await store.mutation(id: book.id, instance: "one")
        XCTAssertNil(mutation?.desired.labels)
    }
}
