import Foundation

struct LibrarySnapshot {
    let bookmarks: [Bookmark]
    let pending: [PendingSave]
    let pendingMutations: [PendingMutation]
    let collections: [CollectionInfo]
    let labelNames: [String]
    var actions: [LibraryAction] = []
    var bulkOperations: [BulkOperationReceipt] = []
}

actor SyncCoordinator {
    private let client: ReadeckClient
    private let store: LocalStore
    private let instance: String
    private var syncInProgress = false
    private var annotationRevisions: [String: Int] = [:]

    init(client: ReadeckClient, store: LocalStore) {
        self.client = client
        self.store = store
        instance = client.storageInstance
    }

    func cached() async throws -> LibrarySnapshot {
        try await snapshot(collections: [])
    }

    func enqueue(url: String, title: String = "", labels: [String] = []) async throws {
        let item = PendingSave(url: url, title: title, labels: labels)
        try await store.enqueue(item, instance: instance)
    }

    func enqueueBulk(id: String, bookmarks: [Bookmark], intent: BulkEditIntent) async throws -> BulkOperationReceipt {
        try Task.checkCancellation()
        if let existing = try await store.bulkOperations(instance: instance).first(where: { $0.id == id }) { return existing }
        for item in bookmarks {
            try Task.checkCancellation()
            let local = try await store.bookmark(id: item.id, instance: instance)
            if local == nil || (intent.needsLabels && local?.labels == nil) {
                let complete = try await client.bookmark(id: item.id)
                try Task.checkCancellation()
                try await store.upsert(complete, instance: instance)
            }
        }
        try Task.checkCancellation()
        let receipt = try await store.enqueueBulk(id: id, bookmarks: bookmarks, intent: intent, instance: instance)
        if intent.isDeletion { for item in bookmarks { annotationRevisions[item.id, default: 0] += 1 } }
        return receipt
    }

    func retryBulk(id: String) async throws { try await store.retryBulk(id: id, instance: instance) }

    func enqueueMutation(bookmark: Bookmark, patch: BookmarkPatch) async throws {
        try await store.mergeMutation(bookmark: bookmark, patch: patch, instance: instance)
    }

    func overlay(_ items: [Bookmark]) async throws -> [Bookmark] {
        let pending = try await store.pendingMutations(instance: instance)
        let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.bookmarkID, $0.desired) })
        let deleted = try await store.deletedBookmarkIDs(instance: instance)
        var result: [Bookmark] = []
        for item in items where !deleted.contains(item.id) {
            var item = byID[item.id]?.applying(to: item) ?? item
            item.labels = try await store.cleanLabels(item.labelValues, instance: instance)
            result.append(item)
        }
        return result
    }

    func resolveConflict(id: String, keepLocal: Bool) async throws {
        guard var mutation = try await store.mutation(id: id, instance: instance) else { return }
        if keepLocal {
            guard let remote = try await store.bookmark(id: id, instance: instance) else {
                throw APIError.invalidResponse
            }
            mutation.baseline = mutation.desired.baseline(from: remote)
            mutation.revision = UUID().uuidString
            try await store.enqueueMutation(mutation, instance: instance)
        } else {
            try await store.removeMutation(id: id, revision: mutation.revision, instance: instance)
        }
    }

    func discardMissingBookmark(id: String) async throws {
        try await store.removeBookmark(id: id, instance: instance, discardPending: true)
    }

    private func snapshot(collections: [CollectionInfo]) async throws -> LibrarySnapshot {
        try await store.librarySnapshot(collections: collections, instance: instance)
    }

    func enqueueDeleteBookmark(id: String) async throws {
        annotationRevisions[id, default: 0] += 1
        try await store.enqueueDeleteBookmark(id: id, instance: instance)
    }

    func enqueueDeleteLabel(name: String) async throws {
        try await store.enqueueDeleteLabel(name: name, instance: instance)
    }

    private func validateAnnotation(selection: AnnotationSelection, color: String, note: String) throws {
        guard !selection.startSelector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selection.endSelector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.startSelector.unicodeScalars.count <= 256,
              selection.endSelector.unicodeScalars.count <= 256,
              selection.startOffset >= 0, selection.endOffset >= 0,
              !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncError.invalidAnnotation("所选文字位置无效，请重新选择。")
        }
        let color = color.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !color.isEmpty, color.unicodeScalars.count <= 32 else {
            throw SyncError.invalidAnnotation("请选择有效的划线颜色。")
        }
        guard note.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count <= 1024 else {
            throw SyncError.invalidAnnotation("笔记最多支持 1024 个字符。")
        }
    }

    func enqueueCreateAnnotation(bookmarkID: String, selection: AnnotationSelection, color: String, note: String) async throws {
        try validateAnnotation(selection: selection, color: color, note: note)
        let color = color.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = AnnotationSelection(startSelector: selection.startSelector.trimmingCharacters(in: .whitespacesAndNewlines),
                                            startOffset: selection.startOffset,
                                            endSelector: selection.endSelector.trimmingCharacters(in: .whitespacesAndNewlines),
                                            endOffset: selection.endOffset, text: selection.text)
        guard try await !store.deletedBookmarkIDs(instance: instance).contains(bookmarkID) else { return }
        annotationRevisions[bookmarkID, default: 0] += 1
        try await store.enqueueAction(LibraryAction(kind: .createAnnotation, bookmarkID: bookmarkID,
                                                   selection: selection, color: color, note: note), instance: instance)
    }

    func enqueueUpdateAnnotation(bookmarkID: String, annotation: BookmarkAnnotation, color: String, note: String) async throws {
        try validateAnnotation(selection: annotation.selection, color: color, note: note)
        let color = color.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try await !store.deletedBookmarkIDs(instance: instance).contains(bookmarkID) else { return }
        annotationRevisions[bookmarkID, default: 0] += 1
        try await store.enqueueAction(LibraryAction(kind: .updateAnnotation, bookmarkID: bookmarkID,
                                                   targetID: annotation.id, selection: annotation.selection,
                                                   color: color, note: note), instance: instance)
    }

    func enqueueDeleteAnnotation(bookmarkID: String, id: String) async throws {
        annotationRevisions[bookmarkID, default: 0] += 1
        if try await store.cancelUnattemptedAnnotationCreate(bookmarkID: bookmarkID, localID: id, instance: instance) { return }
        guard try await !store.deletedBookmarkIDs(instance: instance).contains(bookmarkID) else { return }
        try await store.enqueueAction(LibraryAction(kind: .deleteAnnotation, bookmarkID: bookmarkID, targetID: id), instance: instance)
    }

    func annotations(bookmarkID: String, refresh: Bool = false) async throws -> [BookmarkAnnotation] {
        guard try await !store.deletedBookmarkIDs(instance: instance).contains(bookmarkID) else { return [] }
        let revision = annotationRevisions[bookmarkID, default: 0]
        if refresh {
            let remote = try await client.annotations(bookmarkID: bookmarkID)
            if revision == annotationRevisions[bookmarkID, default: 0] {
                try await store.setAnnotations(remote, bookmarkID: bookmarkID, instance: instance)
            }
        }
        let state = try await store.annotationState(bookmarkID: bookmarkID, instance: instance)
        return annotationOverlay(state.values, actions: state.actions)
    }

    private func annotationOverlay(_ items: [BookmarkAnnotation], actions: [LibraryAction]) -> [BookmarkAnnotation] {
        var values = items
        for action in actions {
            switch action.kind {
            case .createAnnotation:
                if let annotation = action.optimisticAnnotation {
                    // A lost POST may already be visible in the fetched list.
                    if let index = values.firstIndex(where: { $0.matches(selection: annotation.selection, color: annotation.color, note: annotation.note) }) {
                        values[index] = annotation
                    } else { values.append(annotation) }
                }
            case .updateAnnotation:
                if let index = values.firstIndex(where: { $0.id == action.targetID }) {
                    values[index].color = action.color
                    values[index].note = action.note
                }
            case .deleteAnnotation: values.removeAll { $0.id == action.targetID }
            case .deleteBookmark: return []
            case .deleteLabel, .renameLabel: break
            }
        }
        return values
    }

    private func replayAction(_ original: LibraryAction) async throws {
        guard var action = try await store.action(id: original.id, instance: instance) else { return }
        if let bookmarkID = action.bookmarkID,
           try await store.deletedBookmarkIDs(instance: instance).contains(bookmarkID), action.kind != .deleteBookmark {
            try await store.removeAction(id: action.id, instance: instance)
            return
        }
        switch action.kind {
        case .deleteBookmark:
            try await client.deleteBookmark(id: action.bookmarkID!)
            try await store.removeBookmark(id: action.bookmarkID!, instance: instance, discardPending: true)
            try await store.confirmBulkAction(id: action.id, instance: instance)
        case .renameLabel:
            if let oldName = action.label, let newName = action.targetID {
                if try await store.pending(instance: instance).contains(where: { $0.attemptedAt != nil }) { return }
                if try await store.captureJobs(instance: instance).contains(where: \.blocksTaxonomyChanges) { return }
                try await client.renameLabel(oldName: oldName, newName: newName)
            }
        case .deleteLabel:
            // A request with a lost response may still create a bookmark carrying the old label.
            // Reconcile it before global deletion, including the 90-second uncertainty window.
            if try await store.pending(instance: instance).contains(where: { $0.attemptedAt != nil }) { return }
                if try await store.captureJobs(instance: instance).contains(where: \.blocksTaxonomyChanges) { return }
            try await client.deleteLabel(name: action.label!)
        case .createAnnotation:
            let bookmarkID = action.bookmarkID!
            let selection = action.selection!
            if action.attemptedAt != nil {
                let remote = try await client.annotations(bookmarkID: bookmarkID)
                let matches = remote.filter { $0.matches(selection: selection, color: action.color, note: action.note) }
                if matches.count > 1 { throw SyncError.ambiguousAnnotation }
                if let match = matches.first {
                    annotationRevisions[bookmarkID, default: 0] += 1
                    try await store.setAnnotations(remote, bookmarkID: bookmarkID, instance: instance)
                    try await store.completeAnnotationCreate(action, annotation: match, instance: instance)
                    return
                }
                try await store.setAnnotations(remote, bookmarkID: bookmarkID, instance: instance)
                if Date().timeIntervalSince(action.attemptedAt!) < 90 { return }
            }
            guard let claimed = try await store.claimAnnotationCreate(id: action.id, instance: instance) else { return }
            action = claimed
            do {
                let annotation = try await client.createAnnotation(bookmarkID: bookmarkID, selection: selection,
                                                                  color: action.color, note: action.note)
                annotationRevisions[bookmarkID, default: 0] += 1
                try await store.completeAnnotationCreate(action, annotation: annotation, instance: instance)
                return
            } catch {
                if Self.definitelyNotSent(error) || Self.annotationWasRejected(error),
                   try await store.action(id: action.id, instance: instance) != nil {
                    action.attemptedAt = nil
                    try await store.enqueueAction(action, instance: instance)
                }
                throw error
            }
        case .updateAnnotation, .deleteAnnotation:
            guard let targetID = action.targetID, !targetID.hasPrefix("pending:") else { return }
            let bookmarkID = action.bookmarkID!
            if action.kind == .updateAnnotation {
                try await client.updateAnnotation(bookmarkID: bookmarkID, id: targetID, color: action.color, note: action.note)
            } else {
                try await client.deleteAnnotation(bookmarkID: bookmarkID, id: targetID)
            }
            annotationRevisions[bookmarkID, default: 0] += 1
            var values = try await store.annotationCache(bookmarkID: bookmarkID, instance: instance)?.values ?? []
            if action.kind == .deleteAnnotation { values.removeAll { $0.id == targetID } }
            else if let index = values.firstIndex(where: { $0.id == targetID }) {
                values[index].color = action.color
                values[index].note = action.note
            }
            try await store.setAnnotations(values, bookmarkID: bookmarkID, instance: instance)
        }
        try await store.removeAction(id: action.id, instance: instance)
    }

    func refreshCaptures(ids: [String]) async throws -> LibrarySnapshot {
        var firstError: Error?
        for id in Set(ids).sorted() {
            try Task.checkCancellation()
            guard let local = try await store.bookmark(id: id, instance: instance),
                  local.isProcessing else { continue }
            do {
                let updated = try await client.bookmark(id: id)
                try Task.checkCancellation()
                try await store.upsert(updated, instance: instance)
            } catch APIError.status(404, _) {
                if try await store.mutation(id: id, instance: instance) != nil {
                    if firstError == nil {
                        firstError = SyncError.missingBookmark(id: id, title: local.displayTitle)
                    }
                } else {
                    try await store.removeBookmark(id: id, instance: instance)
                }
            } catch {
                throw error
            }
        }
        if let firstError { throw firstError }
        return try await snapshot(collections: [])
    }

    func sync() async throws -> LibrarySnapshot {
        if syncInProgress { return try await cached() }
        try await store.prepareReadableCategories(instance: instance)
        syncInProgress = true
        defer { syncInProgress = false }
        try Task.checkCancellation()
        var firstError: Error?
        let pending = try await store.pending(instance: instance)
        for var item in pending {
            // Never rewrite an uncertain POST before matching its exact submitted payload.
            if item.attemptedAt == nil { item.labels = try await store.cleanLabels(item.labels, instance: instance) }
            try Task.checkCancellation()
            var submitting = false
            do {
                if item.attemptedAt != nil {
                    let matches = try await client.matchingBookmarks(for: item)
                    if matches.count == 1 {
                        try await store.upsert(matches[0], instance: instance)
                        try await store.removePending(id: item.id, instance: instance)
                        continue
                    }
                    if matches.count > 1 { throw SyncError.ambiguousSave(item.url) }
                    if let attemptedAt = item.attemptedAt,
                       Date().timeIntervalSince(attemptedAt) < 90 { continue }
                }
                // Canonicalize before persisting AND submitting so a lost response
                // reconciles against the same request. Older invalid outbox labels
                // retain the already-authorized intent; after delivery their article
                // appears in category conflicts, where the user can resolve it.
                // New saves have already passed strict validation in LocalStore.enqueue.
                item.labels = try await store.cleanLabels(item.labels, instance: instance)
                if let labels = try? CategoryCodec.labelsForWrite(item.labels) { item.labels = labels }
                item.attemptedAt = Date()
                try await store.updatePending(item, instance: instance)
                submitting = true
                let id = try await client.createBookmark(item)
                let bookmark = try await client.bookmark(id: id)
                try Task.checkCancellation()
                try await store.upsert(bookmark, instance: instance)
                try await store.removePending(id: item.id, instance: instance)
            } catch {
                if submitting, Self.definitelyNotSent(error) {
                    item.attemptedAt = nil
                    try await store.updatePending(item, instance: instance)
                }
                if ConnectionDiagnostics.mustStopRound(error) { throw error }
                if firstError == nil { firstError = error }
            }
        }

        for mutation in try await store.pendingMutations(instance: instance) {
            if try await store.isBulkMutationBlocked(mutation, instance: instance) { continue }
            if try await store.deletedBookmarkIDs(instance: instance).contains(mutation.bookmarkID) { continue }
            try Task.checkCancellation()
            do {
                var remote: Bookmark
                do {
                    remote = try await client.bookmark(id: mutation.bookmarkID)
                } catch APIError.status(404, _) {
                    let local = try await store.bookmark(id: mutation.bookmarkID, instance: instance)
                    throw SyncError.missingBookmark(id: mutation.bookmarkID,
                                                    title: local?.displayTitle ?? mutation.bookmarkID)
                }
                try await store.upsert(remote, instance: instance)
                remote.labels = try await store.cleanLabels(remote.labelValues, instance: instance)
                if mutation.desired.isSatisfied(by: remote) {
                    try await store.removeMutation(id: mutation.bookmarkID, revision: mutation.revision,
                                                   instance: instance, confirmedBy: remote)
                    continue
                }
                if mutation.desired.conflicts(with: remote, baseline: mutation.baseline) {
                    throw SyncError.conflictingEdit(id: remote.id, title: remote.displayTitle)
                }
                if try await store.deletedBookmarkIDs(instance: instance).contains(mutation.bookmarkID) { continue }
                var patch = try await store.cleanPatch(mutation.desired, instance: instance)
                if let progress = patch.readProgress {
                    patch.readProgress = max(progress, remote.readProgress ?? 0)
                }
                let updated = try await client.patchBookmark(id: mutation.bookmarkID, fields: patch.fields)
                try Task.checkCancellation()
                try await store.completeMutation(id: mutation.bookmarkID, revision: mutation.revision,
                                                 sentPatch: patch, updated: updated,
                                                 instance: instance)
            } catch {
                try await store.recordBulkFailure(bookmarkID: mutation.bookmarkID, revision: mutation.revision, error: error, instance: instance)
                if ConnectionDiagnostics.mustStopRound(error) { throw error }
                guard try await store.mutation(id: mutation.bookmarkID, instance: instance)?.revision == mutation.revision else { continue }
                if firstError == nil { firstError = error }
            }
        }

        // Read each action again when replaying: create completion may remap a later local target ID.
        for action in try await store.actions(instance: instance) {
            try Task.checkCancellation()
            if try await store.isBulkActionBlocked(action.id, instance: instance) { continue }
            do { try await replayAction(action) }
            catch {
                if let id = action.bookmarkID {
                    try await store.recordBulkFailure(bookmarkID: id, actionID: action.id, error: error, instance: instance)
                }
                if ConnectionDiagnostics.mustStopRound(error) { throw error }
                if firstError == nil { firstError = error }
                if action.kind == .deleteBookmark, try await store.isBulkAction(action.id, instance: instance) { continue }
                break // Preserve ordering for non-independent annotation/taxonomy actions.
            }
        }

        let cursor = try await store.cursor(instance: instance)
        do {
            let changes = try await client.syncEntries(since: cursor)
            for change in changes.reversed() {
                try Task.checkCancellation()
                if try await store.hasAppliedSyncEntry(change, instance: instance) { continue }
                annotationRevisions[change.id, default: 0] += 1
                try await store.invalidateAnnotations(bookmarkID: change.id, instance: instance)
                if change.type == "delete" {
                    try await store.removeBookmark(id: change.id, instance: instance)
                } else {
                    do {
                        let item = try await client.bookmark(id: change.id)
                        try Task.checkCancellation()
                        try await store.upsert(item, instance: instance)
                    } catch APIError.status(404, _) {
                        try await store.removeBookmark(id: change.id, instance: instance)
                    }
                }
                try await store.checkpointSyncEntry(change, instance: instance)
            }
        } catch {
            if ConnectionDiagnostics.mustStopRound(error) { throw error }
            if firstError == nil { firstError = error }
        }
        try Task.checkCancellation()
        let collections = try await client.collections()
        if let names = try? await client.labelNames() {
            try await store.prepareReadableCategories(instance: instance, observedLabels: names)
            try await store.setCachedLabelNames(names, instance: instance)
        }
        try Task.checkCancellation()
        // Every network save/patch in this round has completed. Preserve only still-pending deletes,
        // so an explicit later edit can create the same label name again.
        try await store.releaseCompletedLabelDeletions(instance: instance)
        if let firstError { throw firstError }
        return try await snapshot(collections: collections)
    }

    private static func annotationWasRejected(_ error: Error) -> Bool {
        guard case let APIError.status(code, _) = error else { return false }
        return [400, 401, 403, 404, 422].contains(code)
    }

    private static func definitelyNotSent(_ error: Error) -> Bool {
        if error is NetworkAccessError { return true }
        guard let network = error as? URLError else { return false }
        switch network.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

enum SyncError: LocalizedError {
    case ambiguousSave(String)
    case ambiguousAnnotation
    case invalidAnnotation(String)
    case conflictingEdit(id: String, title: String)
    case missingBookmark(id: String, title: String)

    var conflictingBookmarkID: String? {
        if case let .conflictingEdit(id, _) = self { return id }
        return nil
    }

    var missingBookmarkID: String? {
        if case let .missingBookmark(id, _) = self { return id }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case let .invalidAnnotation(message): return message
        case .ambiguousAnnotation: return "无法确认划线是否已保存，请检查服务端重复项。"
        case let .ambiguousSave(url): return "无法确认该网页是否已保存，请检查重复项：\(url)"
        case let .conflictingEdit(_, title): return "“\(title)”在其他设备也被修改。本机更改仍待同步。"
        case let .missingBookmark(_, title): return "“\(title)”已从服务端删除，本机更改无法上传。"
        }
    }
}
