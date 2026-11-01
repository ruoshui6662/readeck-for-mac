import Foundation
import SQLite3

enum StoreError: LocalizedError {
    case database(String)
    var errorDescription: String? {
        if case let .database(message) = self { return "本地数据库错误：\(message)" }
        return nil
    }
}

actor LocalStore {
    static let defaultURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReadeckMac", isDirectory: true)
            .appendingPathComponent("library.sqlite")
    }()

    private var db: OpaquePointer?
    private let databaseURL: URL
    private var cacheGeneration: UInt64 = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = LocalStore.defaultURL, cacheMigrationDate: Date = Date()) throws {
        databaseURL = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw StoreError.database("无法打开 \(url.path)")
        }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS bulk_operations(instance TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS bookmarks(instance TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS capture_jobs(instance TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS pending(instance TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS pending_mutations(instance TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS library_actions(instance TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS annotations(instance TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS cursor(instance TEXT PRIMARY KEY, value TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS preferences(instance TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS sync_boundary(instance TEXT NOT NULL, event_time TEXT NOT NULL, id TEXT NOT NULL, event_type TEXT NOT NULL, PRIMARY KEY(instance,event_time,id,event_type));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS articles(instance TEXT NOT NULL, id TEXT NOT NULL, html TEXT NOT NULL, PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS article_access(instance TEXT NOT NULL,id TEXT NOT NULL,last_access REAL NOT NULL,PRIMARY KEY(instance,id));", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "INSERT OR IGNORE INTO article_access(instance,id,last_access) SELECT instance,id,\(cacheMigrationDate.timeIntervalSince1970) FROM articles;", nil, nil, nil) == SQLITE_OK else {
            throw StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit { sqlite3_close(db) }

    func librarySnapshot(collections: [CollectionInfo], instance: String) throws -> LibrarySnapshot {
        let mutations = try pendingMutations(instance: instance)
        let byID = Dictionary(uniqueKeysWithValues: mutations.map { ($0.bookmarkID, $0.desired) })
        return LibrarySnapshot(bookmarks: try bookmarks(instance: instance).map { byID[$0.id]?.applying(to: $0) ?? $0 },
                               pending: try pending(instance: instance).map { item in
                                   var visible = item
                                   visible.labels = try cleanLabels(item.labels, instance: instance)
                                   return visible
                               }, pendingMutations: mutations,
                               collections: collections, labelNames: try cachedLabelNames(instance: instance),
                               actions: try actions(instance: instance), bulkOperations: try bulkOperations(instance: instance))
    }

    func annotationState(bookmarkID: String, instance: String) throws -> (values: [BookmarkAnnotation], actions: [LibraryAction]) {
        guard try !deletedBookmarkIDs(instance: instance).contains(bookmarkID) else { return ([], []) }
        return (try annotationCache(bookmarkID: bookmarkID, instance: instance)?.values ?? [],
                try actions(instance: instance).filter { $0.bookmarkID == bookmarkID })
    }

    func labelPreferences(instance: String) throws -> LabelPreferences {
        guard let data = try payload(table: "preferences", id: "labels", instance: instance) else { return LabelPreferences() }
        return try JSONDecoder().decode(LabelPreferences.self, from: data)
    }

    func addManagedLabel(_ value: String, kind: ManagedLabelKind, instance: String) throws -> LabelPreferences {
        let name = try kind.validatedName(value)
        let pendingDeletion = try deletedLabels(instance: instance).contains {
            $0 == kind.serverLabel(name) || (kind == .category && CategoryCodec.name(from: $0) == name)
        }
        guard !pendingDeletion else { throw TaxonomyError.invalid("这个\(kind.title)正在同步删除，完成后可重新添加。") }
        var preferences = try labelPreferences(instance: instance)
        try preferences.addManagedLabel(name, kind: kind)
        try put(table: "preferences", instance: instance, id: "labels", data: JSONEncoder().encode(preferences))
        return preferences
    }

    func togglePinnedLabel(_ name: String, instance: String) throws -> LabelPreferences {
        var preferences = try labelPreferences(instance: instance)
        if try !deletedLabels(instance: instance).contains(name) { preferences.togglePin(name) }
        try put(table: "preferences", instance: instance, id: "labels", data: JSONEncoder().encode(preferences))
        return preferences
    }

    func recordRecentLabels(_ labels: [String], instance: String) throws -> LabelPreferences {
        var preferences = try labelPreferences(instance: instance)
        preferences.recordUse(try cleanLabels(labels, instance: instance))
        try put(table: "preferences", instance: instance, id: "labels", data: JSONEncoder().encode(preferences))
        return preferences
    }

    func cachedLabelNames(instance: String) throws -> [String] {
        guard let data = try payload(table: "preferences", id: "labelCatalog", instance: instance) else { return [] }
        return try JSONDecoder().decode([String].self, from: data)
    }

    func setCachedLabelNames(_ names: [String], instance: String) throws {
        try put(table: "preferences", instance: instance, id: "labelCatalog", data: JSONEncoder().encode(cleanLabels(names, instance: instance)))
    }

    func bookmarks(instance: String) throws -> [Bookmark] {
        try payloads(table: "bookmarks", instance: instance).map { try JSONDecoder.readeck.decode(Bookmark.self, from: $0) }
    }

    func upsert(_ bookmark: Bookmark, instance: String) throws {
        guard try !deletedBookmarkIDs(instance: instance).contains(bookmark.id) else { return }
        var bookmark = bookmark
        if let labels = bookmark.labels { bookmark.labels = try cleanLabels(labels, instance: instance) }
        try put(table: "bookmarks", instance: instance, id: bookmark.id, data: JSONEncoder().encode(bookmark))
    }

    func bookmark(id: String, instance: String) throws -> Bookmark? {
        guard let data = try payload(table: "bookmarks", id: id, instance: instance) else { return nil }
        return try JSONDecoder.readeck.decode(Bookmark.self, from: data)
    }

    func removeBookmark(id: String, instance: String, discardPending: Bool = false) throws {
        if !discardPending, try mutation(id: id, instance: instance) != nil { return }
        try inSavepoint("remove_bookmark") {
            if discardPending { try supersedeBulkEdits(id: id, keeping: nil, instance: instance) }
            try delete(table: "bookmarks", instance: instance, id: id)
            try delete(table: "articles", instance: instance, id: id)
            try delete(table: "article_access", instance: instance, id: id)
            try delete(table: "annotations", instance: instance, id: id)
            try delete(table: "pending_mutations", instance: instance, id: id)
        }
    }

    func captureJobs(instance: String) throws -> [CaptureJob] {
        try payloads(table: "capture_jobs", instance: instance).map { try JSONDecoder().decode(CaptureJob.self, from: $0) }
            .sorted { $0.created < $1.created }
    }

    @discardableResult
    func saveCaptureJob(_ value: CaptureJob, instance: String) throws -> CaptureJob {
        var job = value; job.revision = UUID().uuidString
        try put(table: "capture_jobs", instance: instance, id: job.id, data: JSONEncoder().encode(job))
        return job
    }

    func replaceCaptureJobIfCurrent(_ job: CaptureJob, instance: String) throws -> CaptureJob? {
        guard let current = try captureJobs(instance: instance).first(where: { $0.id == job.id }), current.revision == job.revision else { return nil }
        return try saveCaptureJob(job, instance: instance)
    }

    func recordCaptureAccepted(id: String, bookmarkID: String, attemptedAt: Date?, instance: String) throws -> CaptureJob? {
        guard var current = try captureJobs(instance: instance).first(where: { $0.id == id }),
              current.attemptedAt == attemptedAt, current.stage != .complete, current.stage != .cancelled else { return nil }
        current.bookmarkID = bookmarkID; current.stage = .verifying; current.message = nil
        return try saveCaptureJob(current, instance: instance)
    }

    func completeCaptureJob(_ job: CaptureJob, bookmark: Bookmark, instance: String) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            guard try replaceCaptureJobIfCurrent(job, instance: instance) != nil else { try execute("ROLLBACK"); return false }
            try upsert(bookmark, instance: instance)
            try execute("COMMIT")
            return true
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func claimCapturePreparation(id: String, instance: String) throws -> CaptureJob? {
        guard var job = try captureJobs(instance: instance).first(where: { $0.id == id }), job.stage == .queued else { return nil }
        job.stage = .capturing; job.preparationID = UUID().uuidString
        return try saveCaptureJob(job, instance: instance)
    }

    func completeCapturePreparation(id: String, title: String, instance: String, preparationID: String? = nil, generation: String? = nil, report: CaptureResourceReport? = nil, sourceURL: URL? = nil) throws -> Bool {
        guard var job = try captureJobs(instance: instance).first(where: { $0.id == id }),
              [.capturing, .needsInteraction, .importing].contains(job.stage), job.attemptedAt == nil,
              job.preparationID == preparationID else { return false }
        if job.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { job.title = title }
        if let sourceURL {
            let initial = try CaptureSourceURL(job.url)
            let resolved = try CaptureSourceURL(sourceURL.absoluteString)
            guard initial.site == resolved.site, initial.articleID == nil || initial.articleID == resolved.articleID else { throw CaptureError.invalidPackage }
            job.url = resolved.canonical.absoluteString
        }
        job.packageGeneration = generation; job.recaptureRequested = nil; job.preparationID = nil
        job.resourceReport = report
        job.stage = .ready; job.message = nil
        try saveCaptureJob(job, instance: instance)
        return true
    }

    func markCaptureInteraction(id: String, instance: String, preparationID: String?) throws -> Bool {
        guard var job = try captureJobs(instance: instance).first(where: { $0.id == id }),
              job.stage == .capturing, job.attemptedAt == nil, job.preparationID == preparationID else { return false }
        job.stage = .needsInteraction
        try saveCaptureJob(job, instance: instance)
        return true
    }

    func cancelCaptureJob(id: String, instance: String) throws -> Bool {
        guard var job = try captureJobs(instance: instance).first(where: { $0.id == id }), job.attemptedAt == nil else { return false }
        job.stage = .cancelled; job.message = nil
        try saveCaptureJob(job, instance: instance)
        return true
    }

    func authorizeCaptureResend(id: String, instance: String) throws {
        guard var job = try captureJobs(instance: instance).first(where: { $0.id == id }),
              job.stage == .uncertain, job.bookmarkID == nil else { return }
        job.stage = .ready; job.attemptedAt = nil; job.message = nil
        try saveCaptureJob(job, instance: instance)
    }

    func claimCaptureUpload(id: String, instance: String) throws -> CaptureJob? {
        guard var job = try captureJobs(instance: instance).first(where: { $0.id == id }),
              job.stage == .ready, job.attemptedAt == nil,
              try !actions(instance: instance).contains(where: { $0.kind == .deleteLabel || $0.kind == .renameLabel }) else { return nil }
        job.labels = try CategoryCodec.labelsForWrite(cleanLabels(job.labels, instance: instance))
        job.stage = .uploading; job.attemptedAt = Date(); job.message = nil
        return try saveCaptureJob(job, instance: instance)
    }

    func recoverCaptureJobs(instance: String, activeImports: Set<String> = []) throws {
        for var job in try captureJobs(instance: instance) {
            let oldStage = job.stage
            if job.stage == .capturing { job.stage = .queued }
            if job.stage == .importing && !activeImports.contains(job.id) {
                job.stage = .failed; job.message = "导入被中断，请重新选择网页文件，或重新采集原文。"
            }
            if job.stage == .uploading { job.stage = .uncertain }
            if job.stage != oldStage { try saveCaptureJob(job, instance: instance) }
        }
    }

    func pending(instance: String) throws -> [PendingSave] {
        try payloads(table: "pending", instance: instance).map { try JSONDecoder().decode(PendingSave.self, from: $0) }
            .sorted { $0.created < $1.created }
    }

    func enqueue(_ item: PendingSave, instance: String) throws {
        var item = item
        item.labels = try CategoryCodec.labelsForWrite(cleanLabels(item.labels, instance: instance))
        try put(table: "pending", instance: instance, id: item.id, data: JSONEncoder().encode(item))
    }

    func updatePending(_ item: PendingSave, instance: String) throws {
        // Existing outbox records may predate category validation. In particular, an
        // uncertain POST must retain the exact labels used for reconciliation.
        var item = item
        if item.attemptedAt == nil { item.labels = try cleanLabels(item.labels, instance: instance) }
        try put(table: "pending", instance: instance, id: item.id, data: JSONEncoder().encode(item))
    }

    func removePending(id: String, instance: String) throws {
        try delete(table: "pending", instance: instance, id: id)
    }

    func pendingMutations(instance: String) throws -> [PendingMutation] {
        try payloads(table: "pending_mutations", instance: instance)
            .map { try JSONDecoder().decode(PendingMutation.self, from: $0) }
            .sorted { $0.created < $1.created }
    }

    func mutation(id: String, instance: String) throws -> PendingMutation? {
        guard let data = try payload(table: "pending_mutations", id: id, instance: instance) else { return nil }
        return try JSONDecoder().decode(PendingMutation.self, from: data)
    }

    func enqueueMutation(_ mutation: PendingMutation, instance: String) throws {
        guard try !deletedBookmarkIDs(instance: instance).contains(mutation.bookmarkID) else { return }
        var mutation = mutation
        mutation.desired = try cleanPatch(mutation.desired, instance: instance)
        mutation.baseline = try cleanPatch(mutation.baseline, instance: instance)
        try inSavepoint("write_mutation") {
            try supersedeBulkEdits(id: mutation.bookmarkID, keeping: mutation.desired, revision: mutation.revision, instance: instance)
            try put(table: "pending_mutations", instance: instance, id: mutation.bookmarkID,
                    data: JSONEncoder().encode(mutation))
        }
    }

    func mergeMutation(bookmark item: Bookmark, patch: BookmarkPatch, instance: String) throws {
        guard !patch.isEmpty else { return }
        // Validate new label intent, not persistence of an existing legacy outbox
        // record (rebasing, deleting unrelated labels, or changing a star).
        var patch = patch
        if let labels = patch.labels { patch.labels = try CategoryCodec.labelsForWrite(cleanLabels(labels, instance: instance)) }
        let baseline = try bookmark(id: item.id, instance: instance) ?? item
        if var existing = try mutation(id: item.id, instance: instance) {
            existing.merge(patch, baselineBookmark: baseline)
            try enqueueMutation(existing, instance: instance)
        } else {
            try enqueueMutation(PendingMutation(bookmark: baseline, patch: patch), instance: instance)
        }
    }

    @discardableResult
    func removeMutation(id: String, revision: String, instance: String, confirmedBy remote: Bookmark? = nil) throws -> Bool {
        return try inSavepoint("remove_mutation") {
            if let remote { try confirmBulkMutation(id: id, remote: remote, instance: instance) }
            guard let current = try mutation(id: id, instance: instance), current.revision == revision else {
                return false
            }
            if remote == nil { try supersedeBulkEdits(id: id, keeping: nil, instance: instance) }
            try delete(table: "pending_mutations", instance: instance, id: id)
            return true
        }
    }

    func completeMutation(id: String, revision: String, sentPatch: BookmarkPatch,
                          updated: Bookmark, instance: String) throws {
        guard let current = try mutation(id: id, instance: instance) else {
            try upsert(updated, instance: instance)
            try confirmBulkMutation(id: id, remote: updated, instance: instance)
            return
        }

        try execute("BEGIN IMMEDIATE")
        do {
            try upsert(updated, instance: instance)
            try confirmBulkMutation(id: id, remote: updated, instance: instance)
            if current.revision == revision {
                try delete(table: "pending_mutations", instance: instance, id: id)
            } else {
                var rebased = current
                rebased.baseline.replaceFields(with: sentPatch)
                try enqueueMutation(rebased, instance: instance)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // Tombstones sanitize late network responses and stale editor/save snapshots after deletion.
    private func stringsPreference(_ key: String, instance: String) throws -> [String] {
        guard let data = try payload(table: "preferences", id: key, instance: instance) else { return [] }
        return try JSONDecoder().decode([String].self, from: data)
    }

    func deletedLabels(instance: String) throws -> Set<String> {
        Set(try stringsPreference("deletedLabels", instance: instance))
    }

    func deletedBookmarkIDs(instance: String) throws -> Set<String> {
        Set(try stringsPreference("deletedBookmarks", instance: instance))
    }

    func releaseCompletedLabelDeletions(instance: String) throws {
        let remaining = Set(try actions(instance: instance).filter { $0.kind == .deleteLabel }.compactMap(\.label))
        let protected = try deletedLabels(instance: instance).intersection(remaining)
        try put(table: "preferences", instance: instance, id: "deletedLabels", data: JSONEncoder().encode(Array(protected)))
    }

    func labelAliases(instance: String) throws -> [String: String] {
        guard let data = try payload(table: "preferences", id: "labelAliases", instance: instance) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func setLabelAliases(_ aliases: [String: String], instance: String) throws {
        try put(table: "preferences", instance: instance, id: "labelAliases", data: JSONEncoder().encode(aliases))
    }

    // Run discovery before sanitizing a newly fetched server label list. A late
    // legacy label must still schedule a remote rename even when an alias exists.
    func prepareReadableCategories(instance: String, observedLabels: [String] = []) throws {
        let books = try bookmarks(instance: instance)
        let saves = try pending(instance: instance)
        let mutations = try pendingMutations(instance: instance)
        let cachedNames = try cachedLabelNames(instance: instance)
        let deleted = try deletedLabels(instance: instance)
        let candidates = observedLabels + books.flatMap(\.labelValues) + saves.flatMap(\.labels)
            + mutations.flatMap { ($0.desired.labels ?? []) + ($0.baseline.labels ?? []) } + cachedNames
        var aliases = try labelAliases(instance: instance)
        var renames: [String: String] = [:]
        for label in candidates where label.hasPrefix(CategoryCodec.legacyPrefix) {
            guard let name = CategoryCodec.name(from: label) else { continue }
            let readable = CategoryCodec.label(for: name)
            guard !deleted.contains(label), !deleted.contains(readable) else { continue }
            aliases[label] = readable
            renames[label] = readable
        }
        guard !renames.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try setLabelAliases(aliases, instance: instance)
            let queued = try actions(instance: instance)
            for (legacy, readable) in renames.sorted(by: { $0.key < $1.key }) {
                if !queued.contains(where: { $0.kind == .renameLabel && $0.label == legacy }) {
                    try enqueueAction(LibraryAction(kind: .renameLabel, targetID: readable, label: legacy), instance: instance)
                }
            }
            for item in books { try upsert(item, instance: instance) }
            for item in saves { try updatePending(item, instance: instance) }
            for var mutation in mutations {
                let desired = try cleanPatch(mutation.desired, instance: instance)
                let baseline = try cleanPatch(mutation.baseline, instance: instance)
                if desired != mutation.desired || baseline != mutation.baseline {
                    mutation.desired = desired
                    mutation.baseline = baseline
                    mutation.revision = UUID().uuidString
                    try enqueueMutation(mutation, instance: instance)
                }
            }
            try setCachedLabelNames(cachedNames, instance: instance)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func cleanLabels(_ labels: [String], instance: String) throws -> [String] {
        let deleted = try deletedLabels(instance: instance)
        let aliases = try labelAliases(instance: instance)
        return LabelCatalog.unique(labels.compactMap { label in
            let mapped = aliases[label] ?? label
            return deleted.contains(label) || deleted.contains(mapped) ? nil : mapped
        })
    }

    func cleanPatch(_ patch: BookmarkPatch, instance: String) throws -> BookmarkPatch {
        var result = patch
        if let labels = patch.labels { result.labels = try cleanLabels(labels, instance: instance) }
        return result
    }

    func actions(instance: String) throws -> [LibraryAction] {
        try payloads(table: "library_actions", instance: instance)
            .map { try JSONDecoder().decode(LibraryAction.self, from: $0) }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }

    func action(id: String, instance: String) throws -> LibraryAction? {
        guard let data = try payload(table: "library_actions", id: id, instance: instance) else { return nil }
        return try JSONDecoder().decode(LibraryAction.self, from: data)
    }

    func enqueueAction(_ action: LibraryAction, instance: String) throws {
        var action = action
        if action.kind == .createAnnotation, let selection = action.selection,
           try actions(instance: instance).contains(where: { existing in
               existing.id != action.id && existing.kind == .createAnnotation && existing.bookmarkID == action.bookmarkID &&
               existing.optimisticAnnotation?.matches(selection: selection, color: action.color, note: action.note) == true
           }) { return }
        if let bookmarkID = action.bookmarkID, action.kind != .deleteBookmark {
            guard try !deletedBookmarkIDs(instance: instance).contains(bookmarkID) else { return }
            if let targetID = action.targetID {
                action.targetID = try resolvedAnnotationID(bookmarkID: bookmarkID, id: targetID, instance: instance)
            }
        }
        if action.kind == .deleteAnnotation, let bookmarkID = action.bookmarkID, let targetID = action.targetID {
            // A delete supersedes obsolete edits, including a PATCH that now returns 404.
            // Action IDs are independent, so completion of an in-flight old edit cannot erase this delete.
            for queued in try actions(instance: instance) where queued.kind == .updateAnnotation &&
                queued.bookmarkID == bookmarkID && queued.targetID == targetID {
                try removeAction(id: queued.id, instance: instance)
            }
        }
        try put(table: "library_actions", instance: instance, id: action.id, data: JSONEncoder().encode(action))
    }

    func claimAnnotationCreate(id: String, instance: String) throws -> LibraryAction? {
        guard var current = try action(id: id, instance: instance), current.kind == .createAnnotation else { return nil }
        current.attemptedAt = Date()
        try enqueueAction(current, instance: instance)
        return current
    }

    func cancelUnattemptedAnnotationCreate(bookmarkID: String, localID: String, instance: String) throws -> Bool {
        let actions = try actions(instance: instance)
        guard let create = actions.first(where: {
            $0.kind == .createAnnotation && $0.bookmarkID == bookmarkID && $0.localAnnotationID == localID
        }), create.attemptedAt == nil else { return false }
        try execute("BEGIN IMMEDIATE")
        do {
            for action in actions where action.id == create.id || (action.bookmarkID == bookmarkID && action.targetID == localID) {
                try removeAction(id: action.id, instance: instance)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return true
    }

    func resolvedAnnotationID(bookmarkID: String, id: String, instance: String) throws -> String {
        guard let data = try payload(table: "preferences", id: "annotationAlias:\(bookmarkID):\(id)", instance: instance) else { return id }
        return try JSONDecoder().decode(String.self, from: data)
    }

    func removeAction(id: String, instance: String) throws {
        try delete(table: "library_actions", instance: instance, id: id)
    }

    func enqueueDeleteBookmark(id: String, instance: String) throws {
        try execute("BEGIN IMMEDIATE")
        do { try enqueueDeleteBookmarkInTransaction(id: id, instance: instance); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func enqueueDeleteBookmarkInTransaction(id: String, instance: String) throws {
        guard try !deletedBookmarkIDs(instance: instance).contains(id) else { return }
        var deleted = try deletedBookmarkIDs(instance: instance)
        deleted.insert(id)
        try put(table: "preferences", instance: instance, id: "deletedBookmarks", data: JSONEncoder().encode(Array(deleted)))
        for action in try actions(instance: instance) where action.bookmarkID == id { try removeAction(id: action.id, instance: instance) }
        try supersedeBulkEdits(id: id, keeping: nil, instance: instance)
        try enqueueAction(LibraryAction(kind: .deleteBookmark, bookmarkID: id), instance: instance)
        try removeBookmark(id: id, instance: instance, discardPending: true)
    }

    func enqueueDeleteLabel(name: String, instance: String) throws {
        guard !name.isEmpty, try !deletedLabels(instance: instance).contains(name) else { return }
        var names = Set([name])
        if let category = CategoryCodec.name(from: name) {
            let aliases = try labelAliases(instance: instance)
            let known = try bookmarks(instance: instance).flatMap(\.labelValues)
                + pending(instance: instance).flatMap(\.labels) + cachedLabelNames(instance: instance)
                + Array(aliases.keys) + Array(aliases.values)
                + actions(instance: instance).compactMap(\.label)
            names.formUnion(known.filter { CategoryCodec.name(from: $0) == category })
            names.insert(CategoryCodec.label(for: category))
        }
        try execute("BEGIN IMMEDIATE")
        do {
            var deleted = try deletedLabels(instance: instance)
            let newlyDeleted = names.subtracting(deleted)
            deleted.formUnion(names)
            try put(table: "preferences", instance: instance, id: "deletedLabels", data: JSONEncoder().encode(Array(deleted)))
            for action in try actions(instance: instance) where action.kind == .renameLabel {
                if names.contains(action.label ?? "") || names.contains(action.targetID ?? "") {
                    try removeAction(id: action.id, instance: instance)
                }
            }
            for label in newlyDeleted.sorted() {
                try enqueueAction(LibraryAction(kind: .deleteLabel, label: label), instance: instance)
            }
            for item in try bookmarks(instance: instance) { try upsert(item, instance: instance) }
            for item in try pending(instance: instance) { try updatePending(item, instance: instance) }
            for var mutation in try pendingMutations(instance: instance) {
                mutation.revision = UUID().uuidString
                try enqueueMutation(mutation, instance: instance)
            }
            var preferences = try labelPreferences(instance: instance)
            preferences.pinned.removeAll { names.contains($0) }
            preferences.recent.removeAll { names.contains($0) }
            if let category = CategoryCodec.name(from: name) { preferences.managedCategories.removeAll { $0 == category } }
            else { preferences.managedTags.removeAll { $0 == name } }
            preferences.revision += 1
            try put(table: "preferences", instance: instance, id: "labels", data: JSONEncoder().encode(preferences))
            try setCachedLabelNames(cachedLabelNames(instance: instance), instance: instance)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    struct AnnotationCache: Codable {
        var values: [BookmarkAnnotation]
        var valid: Bool = true
    }

    func annotationCache(bookmarkID: String, instance: String) throws -> AnnotationCache? {
        guard let data = try payload(table: "annotations", id: bookmarkID, instance: instance) else { return nil }
        return try JSONDecoder().decode(AnnotationCache.self, from: data)
    }

    func setAnnotations(_ values: [BookmarkAnnotation], bookmarkID: String, instance: String, valid: Bool = true) throws {
        guard try !deletedBookmarkIDs(instance: instance).contains(bookmarkID) else { return }
        try put(table: "annotations", instance: instance, id: bookmarkID,
                data: JSONEncoder().encode(AnnotationCache(values: values, valid: valid)))
    }

    func invalidateAnnotations(bookmarkID: String, instance: String) throws {
        if var cache = try annotationCache(bookmarkID: bookmarkID, instance: instance) {
            cache.valid = false
            try put(table: "annotations", instance: instance, id: bookmarkID, data: JSONEncoder().encode(cache))
        }
    }

    func completeAnnotationCreate(_ action: LibraryAction, annotation: BookmarkAnnotation, instance: String) throws {
        guard try self.action(id: action.id, instance: instance) != nil,
              try !deletedBookmarkIDs(instance: instance).contains(action.bookmarkID ?? "") else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            let bookmarkID = action.bookmarkID!
            try put(table: "preferences", instance: instance, id: "annotationAlias:\(bookmarkID):\(action.localAnnotationID)",
                    data: JSONEncoder().encode(annotation.id))
            var values = try annotationCache(bookmarkID: bookmarkID, instance: instance)?.values ?? []
            values.removeAll { $0.id == annotation.id }
            values.append(annotation)
            try setAnnotations(values, bookmarkID: bookmarkID, instance: instance)
            for var next in try actions(instance: instance) where next.bookmarkID == bookmarkID && next.targetID == action.localAnnotationID {
                next.targetID = annotation.id
                try enqueueAction(next, instance: instance)
            }
            try removeAction(id: action.id, instance: instance)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func cursor(instance: String) throws -> String? {
        let statement = try prepare("SELECT value FROM cursor WHERE instance=?")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    func setCursor(_ value: String, instance: String) throws {
        let statement = try prepare("INSERT INTO cursor(instance,value) VALUES(?,?) ON CONFLICT(instance) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(value, at: 2, in: statement)
        try stepDone(statement)
    }

    func hasAppliedSyncEntry(_ entry: SyncEntry, instance: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sync_boundary WHERE instance=? AND event_time=? AND id=? AND event_type=?")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(entry.time, at: 2, in: statement)
        bind(entry.id, at: 3, in: statement)
        bind(entry.type, at: 4, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func checkpointSyncEntry(_ entry: SyncEntry, instance: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let insert = try prepare("INSERT OR IGNORE INTO sync_boundary(instance,event_time,id,event_type) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(insert) }
            bind(instance, at: 1, in: insert)
            bind(entry.time, at: 2, in: insert)
            bind(entry.id, at: 3, in: insert)
            bind(entry.type, at: 4, in: insert)
            try stepDone(insert)
            try setCursor(entry.time, instance: instance)
            let prune = try prepare("DELETE FROM sync_boundary WHERE instance=? AND event_time<>?")
            defer { sqlite3_finalize(prune) }
            bind(instance, at: 1, in: prune)
            bind(entry.time, at: 2, in: prune)
            try stepDone(prune)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func article(id: String, instance: String, notOlderThan cutoff: Date? = nil, accessedAt now: Date = Date()) throws -> String? {
        let statement = try prepare("SELECT a.html,t.last_access FROM articles a LEFT JOIN article_access t ON t.instance=a.instance AND t.id=a.id WHERE a.instance=? AND a.id=?")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(id, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if let cutoff, sqlite3_column_type(statement, 1) != SQLITE_NULL,
           sqlite3_column_double(statement, 1) <= cutoff.timeIntervalSince1970,
           try !protectedArticleKeys().contains(ArticleCacheKey(instance: instance, id: id)) { return nil }
        let html = String(cString: sqlite3_column_text(statement, 0))
        try touchArticle(id: id, instance: instance, at: now)
        return html
    }

    func setArticle(_ html: String, id: String, instance: String, accessedAt now: Date = Date(), generation: UInt64? = nil) throws {
        guard generation == nil || generation == cacheGeneration,
              try !deletedBookmarkIDs(instance: instance).contains(id) else { return }
        let statement = try prepare("INSERT INTO articles(instance,id,html) VALUES(?,?,?) ON CONFLICT(instance,id) DO UPDATE SET html=excluded.html")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(id, at: 2, in: statement)
        bind(html, at: 3, in: statement)
        try stepDone(statement)
        try touchArticle(id: id, instance: instance, at: now)
    }

    func articleCacheGeneration() -> UInt64 { cacheGeneration }

    private struct ArticleCacheKey: Hashable { let instance: String; let id: String }
    private struct ArticleCacheRecord { let key: ArticleCacheKey; let bytes: Int64; let accessedAt: Double }

    private func touchArticle(id: String, instance: String, at date: Date) throws {
        let statement = try prepare("INSERT INTO article_access(instance,id,last_access) VALUES(?,?,?) ON CONFLICT(instance,id) DO UPDATE SET last_access=excluded.last_access")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(id, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
        try stepDone(statement)
    }

    private func protectedArticleKeys() throws -> Set<ArticleCacheKey> {
        var keys = Set<ArticleCacheKey>()
        let mutations = try prepare("SELECT instance,id FROM pending_mutations")
        defer { sqlite3_finalize(mutations) }
        while sqlite3_step(mutations) == SQLITE_ROW {
            keys.insert(ArticleCacheKey(instance: String(cString: sqlite3_column_text(mutations, 0)),
                                        id: String(cString: sqlite3_column_text(mutations, 1))))
        }
        let actions = try prepare("SELECT instance,payload FROM library_actions")
        defer { sqlite3_finalize(actions) }
        while sqlite3_step(actions) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(actions, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(actions, 1)))
            let action = try JSONDecoder().decode(LibraryAction.self, from: data)
            if let id = action.bookmarkID {
                keys.insert(ArticleCacheKey(instance: String(cString: sqlite3_column_text(actions, 0)), id: id))
            }
        }
        return keys
    }

    private func articleCacheRecords() throws -> [ArticleCacheRecord] {
        let statement = try prepare("SELECT a.instance,a.id,length(CAST(a.html AS BLOB)),t.last_access FROM articles a LEFT JOIN article_access t ON t.instance=a.instance AND t.id=a.id")
        defer { sqlite3_finalize(statement) }
        var values: [ArticleCacheRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(ArticleCacheRecord(key: ArticleCacheKey(instance: String(cString: sqlite3_column_text(statement, 0)),
                                                                 id: String(cString: sqlite3_column_text(statement, 1))),
                                             bytes: sqlite3_column_int64(statement, 2),
                                             accessedAt: sqlite3_column_double(statement, 3)))
        }
        return values
    }

    func articleCacheStatistics() throws -> CacheStatistics {
        let records = try articleCacheRecords()
        let protected = try protectedArticleKeys()
        let bytes = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"].reduce(Int64(0)) { total, path in
            total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return CacheStatistics(articleCount: records.count, articleBytes: records.reduce(0) { $0 + $1.bytes },
                               protectedArticleCount: records.filter { protected.contains($0.key) }.count, databaseBytes: bytes)
    }

    func cleanArticleCache(through cutoff: Date?) throws -> CacheCleanupResult {
        let records = try articleCacheRecords()
        let protected = try protectedArticleKeys()
        let candidates = records.filter { cutoff == nil || $0.accessedAt <= cutoff!.timeIntervalSince1970 }
        let removable = candidates.filter { !protected.contains($0.key) }
        if cutoff == nil { cacheGeneration &+= 1 }
        try execute("BEGIN IMMEDIATE")
        do {
            for record in removable {
                try delete(table: "articles", instance: record.key.instance, id: record.key.id)
                try delete(table: "article_access", instance: record.key.instance, id: record.key.id)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        if cutoff == nil || !removable.isEmpty {
            // Eviction alone leaves free pages inside SQLite. Compact outside the transaction.
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("VACUUM")
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        return CacheCleanupResult(removedCount: removable.count, removedBytes: removable.reduce(0) { $0 + $1.bytes },
                                  protectedCount: candidates.filter { protected.contains($0.key) }.count)
    }

    private func payloads(table: String, instance: String) throws -> [Data] {
        let statement = try prepare("SELECT payload FROM \(table) WHERE instance=?")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        var result: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0) {
                result.append(Data(bytes: bytes, count: count))
            }
        }
        return result
    }

    private func payload(table: String, id: String, instance: String) throws -> Data? {
        let statement = try prepare("SELECT payload FROM \(table) WHERE instance=? AND id=?")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(id, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func put(table: String, instance: String, id: String, data: Data) throws {
        let statement = try prepare("INSERT INTO \(table)(instance,id,payload) VALUES(?,?,?) ON CONFLICT(instance,id) DO UPDATE SET payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(id, at: 2, in: statement)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(data.count), transient)
        }
        try stepDone(statement)
    }

    private func delete(table: String, instance: String, id: String) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE instance=? AND id=?")
        defer { sqlite3_finalize(statement) }
        bind(instance, at: 1, in: statement)
        bind(id, at: 2, in: statement)
        try stepDone(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.database(String(cString: sqlite3_errmsg(db)))
        }
    }
}

// MARK: - Batch transactions and durable per-item outcomes
extension LocalStore {
    private func inSavepoint<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try execute("SAVEPOINT \(name)")
        do {
            let value = try body()
            try execute("RELEASE SAVEPOINT \(name)")
            return value
        } catch {
            try? execute("ROLLBACK TO SAVEPOINT \(name)")
            try? execute("RELEASE SAVEPOINT \(name)")
            throw error
        }
    }

    func bulkOperations(instance: String) throws -> [BulkOperationReceipt] {
        try payloads(table: "bulk_operations", instance: instance)
            .map { try JSONDecoder().decode(BulkOperationReceipt.self, from: $0) }
            .sorted { $0.created > $1.created }
    }

    private func saveBulk(_ receipt: BulkOperationReceipt, instance: String) throws {
        try put(table: "bulk_operations", instance: instance, id: receipt.id, data: JSONEncoder().encode(receipt))
    }

    func enqueueBulk(id: String, bookmarks requested: [Bookmark], intent: BulkEditIntent, instance: String) throws -> BulkOperationReceipt {
        if let data = try payload(table: "bulk_operations", id: id, instance: instance) {
            return try JSONDecoder().decode(BulkOperationReceipt.self, from: data)
        }
        guard !requested.isEmpty else { throw BulkOrganizationError.invalid("请先选择文章。") }
        try execute("BEGIN IMMEDIATE")
        do {
            let deleted = try deletedBookmarkIDs(instance: instance)
            var seen = Set<String>(), entries: [BulkReceiptItem] = []
            for candidate in requested where seen.insert(candidate.id).inserted {
                guard !deleted.contains(candidate.id) else {
                    entries.append(BulkReceiptItem(bookmarkID: candidate.id, title: candidate.displayTitle, status: .skipped, message: "文章已在删除队列中。")); continue
                }
                guard let saved = try bookmark(id: candidate.id, instance: instance) else {
                    throw BulkOrganizationError.invalid(BulkText.format("“%@”缺少完整本机资料，请先刷新。", candidate.displayTitle))
                }
                let current = try mutation(id: saved.id, instance: instance)?.desired.applying(to: saved) ?? saved
                if intent.isDeletion {
                    try enqueueDeleteBookmarkInTransaction(id: saved.id, instance: instance)
                    let action = try actions(instance: instance).first { $0.kind == .deleteBookmark && $0.bookmarkID == saved.id }
                    entries.append(BulkReceiptItem(bookmarkID: saved.id, title: current.displayTitle, actionID: action?.id, status: .queued))
                } else {
                    let intended = try intent.patch(for: current)
                    let patch = try cleanPatch(intended, instance: instance)
                    if let labels = intended.labels, Set(labels) != Set(patch.labels ?? []) {
                        throw BulkOrganizationError.invalid("分类或标签已发生变化，请刷新后重试。")
                    }
                    if patch.isEmpty || patch.isSatisfied(by: current) {
                        entries.append(BulkReceiptItem(bookmarkID: saved.id, title: current.displayTitle, status: .skipped)); continue
                    }
                    try mergeMutation(bookmark: current, patch: patch, instance: instance)
                    let revision = try mutation(id: saved.id, instance: instance)?.revision
                    entries.append(BulkReceiptItem(bookmarkID: saved.id, title: current.displayTitle, patch: patch, mutationRevision: revision, status: .queued))
                }
            }
            let receipt = BulkOperationReceipt(id: id, intent: intent, created: Date(), items: entries)
            try saveBulk(receipt, instance: instance)
            try execute("COMMIT")
            return receipt
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func supersedeBulkEdits(id: String, keeping patch: BookmarkPatch?, revision: String? = nil, instance: String) throws {
        for var receipt in try bulkOperations(instance: instance) {
            var changed = false
            for index in receipt.items.indices where receipt.items[index].bookmarkID == id && receipt.items[index].status.isUnfinished {
                guard let intended = receipt.items[index].patch else { continue }
                if patch?.includes(intended) != true {
                    receipt.items[index].status = .superseded
                    receipt.items[index].message = "这项更改已被后续编辑或删除替代。"; changed = true
                } else if let revision {
                    receipt.items[index].mutationRevision = revision
                    receipt.items[index].status = .queued;receipt.items[index].failure = nil;receipt.items[index].message = nil
                    changed = true
                }
            }
            if changed { try saveBulk(receipt, instance: instance) }
        }
    }
    private func updateBulkItems(instance: String, _ transform: (inout BulkReceiptItem) -> Void) throws {
        for var receipt in try bulkOperations(instance: instance) {
            let previous = receipt
            for index in receipt.items.indices { transform(&receipt.items[index]) }
            if receipt != previous { try saveBulk(receipt, instance: instance) }
        }
    }

    func confirmBulkMutation(id: String, remote: Bookmark, instance: String) throws {
        try updateBulkItems(instance: instance) { entry in
            guard entry.bookmarkID == id, entry.status.isUnfinished,
                  let patch = entry.patch, patch.isSatisfied(by: remote) else { return }
            entry.status = .synced;entry.failure = nil;entry.message = nil
        }
    }

    func confirmBulkAction(id: String, instance: String) throws {
        try updateBulkItems(instance: instance) { entry in
            guard entry.actionID == id, entry.status.isUnfinished else { return }
            entry.status = .synced;entry.failure = nil;entry.message = nil
        }
    }

    func recordBulkFailure(bookmarkID: String, revision: String? = nil, actionID: String? = nil, error: Error, instance: String) throws {
        guard !(error is CancellationError) else { return }
        try updateBulkItems(instance: instance) { entry in
            guard entry.bookmarkID == bookmarkID, entry.status.isUnfinished,
                  actionID == nil ? entry.patch != nil : entry.actionID == actionID else { return }
            if actionID == nil, let revision, entry.mutationRevision != revision { return }
            entry.mutationRevision = revision ?? entry.mutationRevision
            entry.message = ConnectionDiagnostics.message(for: error)
            if (error as? SyncError)?.conflictingBookmarkID != nil {
                entry.status = .conflict;entry.failure = nil
            } else {
                entry.status = .failed
                if (error as? SyncError)?.missingBookmarkID != nil { entry.failure = .missing }
                else if case APIError.status(let code, _) = error, [400,401,403,404,422].contains(code) { entry.failure = .rejected }
                else { entry.failure = .transport }
            }
        }
    }

    func isBulkMutationBlocked(_ mutation: PendingMutation, instance: String) throws -> Bool {
        try bulkOperations(instance: instance).flatMap(\.items).contains {
            $0.bookmarkID == mutation.bookmarkID && $0.mutationRevision == mutation.revision &&
            ($0.status == .conflict || ($0.status == .failed && $0.failure != .transport))
        }
    }

    func isBulkAction(_ id: String, instance: String) throws -> Bool {
        try bulkOperations(instance: instance).flatMap(\.items).contains { $0.actionID == id }
    }

    func isBulkActionBlocked(_ id: String, instance: String) throws -> Bool {
        try bulkOperations(instance: instance).flatMap(\.items).contains {
            $0.actionID == id && $0.status == .failed && $0.failure != .transport
        }
    }

    func retryBulk(id: String, instance: String) throws {
        guard var receipt = try bulkOperations(instance: instance).first(where: { $0.id == id }) else { return }
        for index in receipt.items.indices where receipt.items[index].status == .failed && receipt.items[index].failure != .missing {
            receipt.items[index].status = .queued;receipt.items[index].failure = nil;receipt.items[index].message = nil
        }
        try saveBulk(receipt, instance: instance)
    }

}
