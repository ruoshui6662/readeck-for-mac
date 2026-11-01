import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var serverText = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    @Published var tokenText = ""
    @Published var connected = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var serverVersion: String?
    @Published var bookmarks: [Bookmark] = []
    @Published var pending: [PendingSave] = []
    @Published var pendingMutations: [PendingMutation] = []
    @Published var collections: [CollectionInfo] = []
    @Published var isSyncing = false
    @Published var syncMessage: String?
    @Published var conflictBookmarkID: String?
    @Published var missingBookmarkID: String?
    @Published var searchResults: [Bookmark]?
    @Published var collectionIDs: Set<String> = []
    @Published var showSaveSheet = false
    @Published var lastSyncAt: Date?
    @Published var nextRetryAt: Date?
    @Published var needsLocalNetworkPermission = false
    @Published var labelPreferences = LabelPreferences()
    @Published var taxonomyMessage: String?
    @Published var cachedLabelNames: [String] = []
    @Published var libraryActions: [LibraryAction] = []
    @Published var bulkOperations: [BulkOperationReceipt] = []
    @Published private(set) var isApplyingBulk = false
    @Published var bulkMessage: String?
    @Published var bulkError: String?
    private var activeBulkID: UUID?
    private var activeBulkTask: Task<BulkOperationReceipt, Error>?
    @Published var annotationItems: [String: [BookmarkAnnotation]] = [:]
    @Published var annotationMessages: [String: String] = [:]
    private var activeAnnotationBookmarkID: String?
    private var contentRevision = 0
    private var annotationLoadIDs: [String: UUID] = [:]
    @Published private(set) var cacheRetention: CacheRetention = .days30
    @Published private(set) var cacheStatistics: CacheStatistics?
    @Published private(set) var isCleaningCache = false
    @Published private(set) var cacheCleanupMessage: String?
    private let cacheDefaults: UserDefaults
    private var cacheMaintenanceTask: Task<Void, Never>?
    private var cacheStatisticsID = UUID()
    private var cacheOperationCount = 0

    var labelCatalog: LabelCatalog {
        LabelCatalog(bookmarks: bookmarks, pending: pending + captureJobs.filter { $0.stage != .complete && $0.stage != .cancelled }.map { PendingSave(url: $0.url, title: $0.title, labels: $0.labels) }, remoteNames: cachedLabelNames, preferences: labelPreferences)
    }

    private(set) var client: ReadeckClient?
    private var coordinator: SyncCoordinator?
    private var store: LocalStore?
    @Published var captureJobs: [CaptureJob] = []
    @Published var captureStorageBytes: Int64 = 0
    @Published var legacyWechatCacheBytes: Int64 = 0
    private let capturePackages: CapturePackageStore
    private let captureAcquisition: (@MainActor (CaptureSourceURL) async throws -> Data)?
    private let captureImportParser: (@Sendable (Data, String, CaptureSourceURL, String) async throws -> CapturedArticle)?
    private var captureWorker: Task<Void, Never>?
    private var captureWorkerID: UUID?
    private var activeCaptureImportIDs = Set<String>()
    private var captureImportWork: [String: Task<CapturedArticle, Error>] = [:]
    private var nativeCaptureSession: ArticleCaptureSession?

    private var periodicSync: Task<Void, Never>?
    private var captureRefreshTask: Task<Void, Never>?
    private var captureRefreshID: UUID?
    private var captureSchedule = CaptureRefreshSchedule()
    private var needsSync = false
    private var activeSyncID: UUID?
    private var generations = ConnectionGenerations()
    private var session: ConnectionSession?
    private let policy: SyncPolicy
    private var activeOperation: Task<LibrarySnapshot, Error>?
    private var recoveryTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var connectionAttemptID: UUID?

    init(client initialClient: ReadeckClient? = nil, store initialStore: LocalStore? = nil,
         policy: SyncPolicy = SyncPolicy(), connectionEvents: AsyncStream<ConnectionEvent>? = nil,
         cacheDefaults: UserDefaults = .standard,
         capturePackages: CapturePackageStore = CapturePackageStore(),
         captureAcquisition: (@MainActor (CaptureSourceURL) async throws -> Data)? = nil,
         captureImportParser: (@Sendable (Data, String, CaptureSourceURL, String) async throws -> CapturedArticle)? = nil) {
        self.captureImportParser = captureImportParser
        self.capturePackages = capturePackages
        self.captureAcquisition = captureAcquisition
        self.policy = policy
        self.cacheDefaults = cacheDefaults
        cacheRetention = CacheRetention.stored(cacheDefaults.integer(forKey: "cache.retentionDays"))
        do { store = try initialStore ?? LocalStore() }
        catch { errorMessage = error.localizedDescription }
        let restoredClient: ReadeckClient?
        if let initialClient {
            restoredClient = initialClient
        } else if let address = try? ServerAddress(serverText),
                  let token = CredentialStore.load(for: address) {
            restoredClient = ReadeckClient(address: address, token: token)
        } else {
            restoredClient = nil
        }
        if let candidate = restoredClient, let store {
            serverText = candidate.address.root.absoluteString
            tokenText = candidate.token
            client = candidate
            coordinator = SyncCoordinator(client: candidate, store: store)
            session = generations.begin(for: candidate)
            connected = true
            Task { await loadCached(); startCaptureWork(); await sync() }
            startPeriodicSync()
        }
        if let connectionEvents {
            eventsTask = Task { [weak self] in
                for await event in connectionEvents {
                    guard !Task.isCancelled else { return }
                    await self?.handleConnectionEvent(event)
                }
            }
        }
        cacheMaintenanceTask = Task { [weak self] in
            await self?.maintainArticleCache()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3_600)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.maintainArticleCache()
            }
        }
    }

    deinit {
        periodicSync?.cancel()
        captureRefreshTask?.cancel()
        activeOperation?.cancel()
        recoveryTask?.cancel()
        eventsTask?.cancel()
        cacheMaintenanceTask?.cancel()
        captureWorker?.cancel()
    }

    func connect() async {
        let attemptID = UUID()
        connectionAttemptID = attemptID
        stopConnectionWork()
        generations.invalidate()
        session = nil
        connected = false
        isBusy = true
        errorMessage = nil
        resetCaptureRefresh()
        defer { if connectionAttemptID == attemptID { isBusy = false } }
        do {
            let address = try ServerAddress(serverText)
            let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw ConnectionError.missingToken }
            let candidate = ReadeckClient(address: address, token: token)
            let info = try await SyncDeadline.run(seconds: policy.fullSyncTimeout) {
                let info = try await candidate.info()
                try await candidate.verify()
                return info
            }
            guard connectionAttemptID == attemptID else { return }
            try CredentialStore.save(token, for: address)
            UserDefaults.standard.set(address.root.absoluteString, forKey: "serverURL")
            periodicSync?.cancel()
            periodicSync = nil
            client = candidate
            if let store { coordinator = SyncCoordinator(client: candidate, store: store) }
            session = generations.begin(for: candidate)
            activeSyncID = nil
            isSyncing = false
            needsSync = false
            searchResults = nil
            collectionIDs = []
            serverVersion = info.version?.release
            connected = true
            needsLocalNetworkPermission = false
            lastSyncAt = nil
            retryAttempt = 0
            labelPreferences = LabelPreferences()
            taxonomyMessage = nil
            cachedLabelNames = []
            libraryActions = []
        bulkOperations = [];bulkMessage = nil;bulkError = nil
            annotationItems = [:]
            annotationMessages = [:]
            activeAnnotationBookmarkID = nil
            annotationLoadIDs = [:]
            await loadCached()
            startCaptureWork()
            await sync()
            startPeriodicSync()
        } catch {
            guard connectionAttemptID == attemptID else { return }
            resetCaptureRefresh()
            generations.invalidate()
            session = nil
            connected = false
            errorMessage = ConnectionDiagnostics.message(for: error)
            needsLocalNetworkPermission = error is NetworkAccessError
        }
    }

    func disconnect() {
        connectionAttemptID = nil
        stopConnectionWork()
        periodicSync?.cancel()
        periodicSync = nil
        resetCaptureRefresh()
        client = nil
        coordinator = nil
        session = nil
        generations.invalidate()
        activeSyncID = nil
        isSyncing = false
        needsSync = false
        connected = false
        bookmarks = []
        pending = []
        captureJobs = []
        pendingMutations = []
        conflictBookmarkID = nil
        missingBookmarkID = nil
        collections = []
        tokenText = ""
        serverVersion = nil
        labelPreferences = LabelPreferences()
        taxonomyMessage = nil
        cachedLabelNames = []
        libraryActions = []
        bulkOperations = [];bulkMessage = nil;bulkError = nil
        annotationItems = [:]
        annotationMessages = [:]
        activeAnnotationBookmarkID = nil
        annotationLoadIDs = [:]
        lastSyncAt = nil
        needsLocalNetworkPermission = false
        if let address = try? ServerAddress(serverText) { CredentialStore.delete(for: address) }
        UserDefaults.standard.removeObject(forKey: "serverURL")
    }

    func loadCached() async {
        guard let coordinator, let client, let session else { return }
        do {
            let snapshot = try await coordinator.cached()
            guard isCurrent(session, client: client) else { return }
            bookmarks = snapshot.bookmarks
            pending = snapshot.pending
            pendingMutations = snapshot.pendingMutations
            cachedLabelNames = snapshot.labelNames
            libraryActions = snapshot.actions
            bulkOperations = snapshot.bulkOperations
            if bulkMessage != nil, bulkError == nil, let latest = bulkOperations.first { bulkMessage = latest.summary }
            if let store {
                let jobs = try await store.captureJobs(instance: client.storageInstance)
                guard isCurrent(session, client: client) else { return }
                captureJobs = jobs
            }
            if let store {
                let preferences = try await store.labelPreferences(instance: client.storageInstance)
                guard isCurrent(session, client: client) else { return }
                applyLabelPreferences(preferences)
            }
            if !isSyncing { scheduleCaptureRefresh() }
        } catch {
            guard isCurrent(session, client: client) else { return }
            syncMessage = ConnectionDiagnostics.message(for: error)
        }
    }

    func sync() async {
        guard let coordinator, let client, let session,
              isCurrent(session, client: client) else { return }
        if isSyncing { needsSync = true; return }
        cancelRecovery()
        cancelCaptureRefresh()
        let syncID = UUID()
        activeSyncID = syncID
        isSyncing = true
        syncMessage = nil
        conflictBookmarkID = nil
        missingBookmarkID = nil
        var succeeded = false
        defer { finishSync(syncID, refreshCaptures: succeeded) }
        do {
            let timeout = policy.fullSyncTimeout
            let operation = Task { try await SyncDeadline.run(seconds: timeout) { try await coordinator.sync() } }
            activeOperation = operation
            let snapshot = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard isCurrent(session, client: client) else { return }
            if snapshot.bookmarks != bookmarks || Set(snapshot.actions.map(\.id)) != Set(libraryActions.map(\.id)) {
                contentRevision += 1
            }
            bookmarks = snapshot.bookmarks
            pending = snapshot.pending
            pendingMutations = snapshot.pendingMutations
            collections = snapshot.collections
            cachedLabelNames = snapshot.labelNames
            libraryActions = snapshot.actions
            bulkOperations = snapshot.bulkOperations
            if bulkMessage != nil, bulkError == nil, let latest = bulkOperations.first { bulkMessage = latest.summary }
            if let id = activeAnnotationBookmarkID {
                let items = try await coordinator.annotations(bookmarkID: id, refresh: false)
                guard isCurrent(session, client: client) else { return }
                annotationItems[id] = items
            }
            succeeded = true
            lastSyncAt = Date()
            needsLocalNetworkPermission = false
            retryAttempt = 0
        } catch {
            guard isCurrent(session, client: client) else { return }
            if !(error is CancellationError) {
                syncMessage = ConnectionDiagnostics.message(for: error)
                scheduleRecovery(for: error)
            }
            conflictBookmarkID = (error as? SyncError)?.conflictingBookmarkID
            missingBookmarkID = (error as? SyncError)?.missingBookmarkID
            await loadCached()
        }
    }

    func resolveConflict(keepLocal: Bool) async {
        guard let conflictBookmarkID else { return }
        await resolveBulkConflict(id: conflictBookmarkID, keepLocal: keepLocal)
    }

    func discardMissingBookmark() async {
        guard let missingBookmarkID else { return }
        await discardMissingBulk(id: missingBookmarkID)
    }

    @discardableResult
    func saveURL(_ raw: String, title: String = "", category: String? = nil, tags: [String] = []) async -> Bool {
        guard let coordinator, let client, let session else { return false }
        guard let text = CaptureInput.url(in: raw) else {
            syncMessage = "请输入有效的网页地址。"
            return false
        }
        do {
            if let source = try? CaptureSourceURL(text), let store {
                guard source.site.availableForCapture else {
                    syncMessage = AppLanguage.text("小红书请在“保存网页”中导入浏览器单文件网页。")
                    return false
                }
                let labels = try CategoryCodec.labelsForWrite(CategoryCodec.replacingCategory(in: LabelCatalog.cleanedTags(tags), with: category))
                var job = CaptureJob(url: source.canonical.absoluteString, title: title, labels: labels)
                try await store.saveCaptureJob(job, instance: client.storageInstance)
                guard isCurrent(session, client: client) else { return false }
                await rememberLabels(labels, client: client, session: session)
                await loadCached()
                guard isCurrent(session, client: client) else { return false }
                startCaptureWork()
                return true
            }

            let labels = CategoryCodec.replacingCategory(in: LabelCatalog.cleanedTags(tags), with: category)
            try await coordinator.enqueue(url: text, title: title, labels: labels)
            guard isCurrent(session, client: client) else { return false }
            await rememberLabels(labels, client: client, session: session)
            guard isCurrent(session, client: client) else { return false }
            await loadCached()
            guard isCurrent(session, client: client) else { return false }
            Task { await sync() }
            return true
        } catch {
            guard isCurrent(session, client: client) else { return false }
            syncMessage = ConnectionDiagnostics.message(for: error)
            return false
        }
    }

    @discardableResult
    func importWechatFile(_ file: URL, sourceURL: String, title: String, category: String?, tags: [String]) async -> Bool {
        await importCaptureFile(file, sourceURL: sourceURL, title: title, category: category, tags: tags)
    }

    @discardableResult
    func importCaptureFile(_ file: URL, sourceURL: String, title: String, category: String?, tags: [String], replacingJobID: String? = nil) async -> Bool {
        guard let client, let store, let session else { return false }
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        var importedJob: CaptureJob?
        do {
            let source = try CaptureSourceURL(sourceURL)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= CaptureLimits().maximumArchiveBytes else { throw CaptureError.invalidPackage }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let labels = try CategoryCodec.labelsForWrite(CategoryCodec.replacingCategory(in: LabelCatalog.cleanedTags(tags), with: category))
            var job = CaptureJob(url: source.canonical.absoluteString, title: title, labels: labels)
            if let replacingJobID {
                guard let existing = try await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == replacingJobID }),
                      existing.stage == .failed, existing.attemptedAt == nil,
                      !activeCaptureImportIDs.contains(existing.id),
                      try CaptureSourceURL(existing.url).canonical == source.canonical else { return false }
                job = existing
                job.title = title; job.labels = labels
                if source.site == .xiaohongshu { job.requestURL = nil }
            }
            job.stage = .importing; job.preparationID = UUID().uuidString; job.message = nil
            activeCaptureImportIDs.insert(job.id)
            defer { activeCaptureImportIDs.remove(job.id); captureImportWork[job.id] = nil }
            if replacingJobID != nil {
                guard let saved = try await store.replaceCaptureJobIfCurrent(job, instance: client.storageInstance) else { return false }
                job = saved
            } else { job = try await store.saveCaptureJob(job, instance: client.storageInstance) }
            importedJob = job
            let packageID = job.id
            let fileExtension = file.pathExtension
            let parser = captureImportParser
            let work = Task<CapturedArticle, Error> {
                let article: CapturedArticle
                if let parser { article = try await parser(data, fileExtension, source, packageID) }
                else if source.site == .xiaohongshu {
                    guard ["mhtml", "mht"].contains(fileExtension.lowercased()) else { throw WechatParseError.parseError("请在浏览器中保存为“网页（单个文件）”，再选择 .mhtml 文件。") }
                    let prepared = try await Task.detached { try XiaohongshuImport.prepare(data: data, source: source) }.value
                    let completed = try await XiaohongshuImageDownload.supplement(prepared)
                    article = try await Task.detached { try XiaohongshuImport.article(completed, packageID: packageID) }.value
                }
                else {
                    article = try await Task.detached {
                        let archive = try WechatImport.archive(data: data, fileExtension: fileExtension, source: source)
                        return try WechatArticleParser.extract(archive: archive, source: source, packageID: packageID)
                    }.value
                }
                try Task.checkCancellation()
                return article
            }
            captureImportWork[job.id] = work
            await loadCached()
            let article = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard isCurrent(session, client: client) else { return false }
            let generation = try await capturePackages.saveGeneration(article, id: job.id, instance: client.storageInstance)
            guard try await store.completeCapturePreparation(id: job.id, title: article.title, instance: client.storageInstance, preparationID: job.preparationID, generation: generation, report: article.resourceReport) else {
                try? await capturePackages.removeGeneration(id: job.id, instance: client.storageInstance, generation: generation)
                return false
            }
            guard isCurrent(session, client: client) else { return false }
            await rememberLabels(labels, client: client, session: session)
            await loadCached(); startCaptureWork()
            return true
        } catch {
            if let importedJob, var current = try? await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == importedJob.id }), current.stage != .cancelled {
                let site = (try? CaptureSourceURL(sourceURL).site) ?? .wechat
                current.stage = .failed; current.message = WechatParseError.captureMessage(for: error, site: site)
                _ = try? await store.replaceCaptureJobIfCurrent(current, instance: client.storageInstance)
            }
            if isCurrent(session, client: client) {
                if !(error is CancellationError) { syncMessage = error.localizedDescription }
                await loadCached()
            }
            return false
        }
    }

    func cancelCaptureWork() {
        captureWorker?.cancel(); captureWorker = nil; captureWorkerID = nil
        for work in captureImportWork.values { work.cancel() }
        captureImportWork.removeAll()
        nativeCaptureSession = nil
    }

    func cleanCaptureScratch() async {
        guard let client, let store, let session, captureWorker == nil, activeCaptureImportIDs.isEmpty else { return }
        do {
            let jobs = try await store.captureJobs(instance: client.storageInstance)
            guard isCurrent(session, client: client), captureWorker == nil, activeCaptureImportIDs.isEmpty else { return }
            let protected = Set(jobs.filter { $0.stage != .cancelled && $0.stage != .complete }.map(\.id))
            let count = try await capturePackages.cleanOrphanedFiles(instance: client.storageInstance, protectedIDs: protected, olderThan: Date().addingTimeInterval(-86400))
            guard isCurrent(session, client: client) else { return }
            cacheCleanupMessage = String(format: AppLanguage.text("已整理 %lld 项旧临时采集文件，待同步任务已保留。"), count)
            await refreshCacheStatistics()
        } catch {
            if isCurrent(session, client: client) { cacheCleanupMessage = AppLanguage.text("采集文件整理未完成，请稍后重试。") }
        }
    }

    func capturePreview(id: String) async throws -> CapturePackagePreview {
        guard let client, let store, let session else { throw CaptureError.invalidPackage }
        guard let job = try await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == id }),
              job.stage != .cancelled, job.stage != .complete else { throw CaptureError.invalidPackage }
        let package = try await capturePackages.load(id: id, instance: client.storageInstance, generation: job.packageGeneration)
        let preview = try await Task.detached { try CapturePackagePreview.make(package: package) }.value
        let current = try await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == id })
        guard isCurrent(session, client: client), let current,
              current.stage != .cancelled, current.stage != .complete,
              current.packageGeneration == job.packageGeneration else { throw CancellationError() }
        return preview
    }

    func showCaptureWindow() { nativeCaptureSession?.show() }

    func retryCapture(_ id: String) async {
        guard let client, let store, let session else { return }
        do {
            guard var job = try await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == id }) else { return }
            if (try? CaptureSourceURL(job.url).site) == .xiaohongshu, job.attemptedAt == nil {
                syncMessage = AppLanguage.text("小红书自动采集已停用；可导入已保存的网页文件。")
                return
            }
            if job.stage == .needsInteraction, let nativeCaptureSession { nativeCaptureSession.show(); return }
            if job.attemptedAt == nil && [.failed, .needsInteraction].contains(job.stage) {
                job.stage = .queued; job.message = nil; job.recaptureRequested = true; job.preparationID = nil
                guard try await store.replaceCaptureJobIfCurrent(job, instance: client.storageInstance) != nil else { return }
            }
            guard isCurrent(session, client: client) else { return }
            startCaptureWork()
        } catch { syncMessage = error.localizedDescription }
    }

    func resendUncertainCapture(_ id: String) async {
        guard captureWorker == nil else { syncMessage = "另一个采集任务正在运行，请稍后再试。"; return }
        guard let client, let store, let session else { return }
        do {
            try await store.authorizeCaptureResend(id: id, instance: client.storageInstance)
            guard isCurrent(session, client: client) else { return }
            startCaptureWork()
        } catch { syncMessage = error.localizedDescription }
    }

    func cancelCapture(_ id: String) async {
        guard let client, let store, let session else { return }
        do {
            guard let job = try await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == id }), job.attemptedAt == nil else { return }
            guard try await store.cancelCaptureJob(id: id, instance: client.storageInstance) else { await loadCached(); return }
            captureImportWork.removeValue(forKey: id)?.cancel()
            if job.stage == .capturing || job.stage == .needsInteraction { cancelCaptureWork() }
            try await capturePackages.remove(id: id, instance: client.storageInstance)
            guard isCurrent(session, client: client) else { return }
            await loadCached()
            startCaptureWork()
        } catch { syncMessage = error.localizedDescription }
    }

    private func startCaptureWork() {
        guard captureWorker == nil, let client, let store, let session, isCurrent(session, client: client) else { return }
        let workerID = UUID(); captureWorkerID = workerID
        captureWorker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.captureWorkerID == workerID {
                    self.captureWorker = nil; self.captureWorkerID = nil; self.nativeCaptureSession = nil
                }
            }
            do {
                try await store.recoverCaptureJobs(instance: client.storageInstance, activeImports: self.activeCaptureImportIDs)
                let pipeline = CapturePipeline(client: client, store: store, packages: self.capturePackages)
                var processed = Set<String>()
                while !Task.isCancelled && self.isCurrent(session, client: client) {
                    let jobs = try await store.captureJobs(instance: client.storageInstance)
                    guard var job = jobs.first(where: { !processed.contains($0.id) && [.queued, .ready, .uncertain, .verifying].contains($0.stage) }) else { break }
                    processed.insert(job.id)
                    if job.requestURL != nil, job.attemptedAt == nil,
                       (try? CaptureSourceURL(job.url).site) == .xiaohongshu {
                        job.stage = .failed
                        job.message = AppLanguage.text("小红书自动采集已停用；任务和本机文件已保留。")
                        _ = try await store.replaceCaptureJobIfCurrent(job, instance: client.storageInstance)
                        await self.loadCached()
                        continue
                    }
                    if job.stage == .queued {
                        guard let claimed = try await store.claimCapturePreparation(id: job.id, instance: client.storageInstance) else { continue }
                        job = claimed
                        if job.recaptureRequested != true,
                           let saved = try? await self.capturePackages.load(id: job.id, instance: client.storageInstance, generation: job.packageGeneration),
                           saved.manifest.missingImages.isEmpty {
                            _ = try await store.completeCapturePreparation(id: job.id, title: saved.manifest.title, instance: client.storageInstance, preparationID: job.preparationID, generation: job.packageGeneration, report: saved.manifest.resourceReport, sourceURL: saved.manifest.url)
                            await pipeline.process(id: job.id)
                            await self.loadCached()
                            continue
                        }
                        await self.loadCached()
                        try Task.checkCancellation()
                        do {
                            let source = try CaptureSourceURL(job.requestURL ?? job.url)
                            let article: CapturedArticle
                            let archive: Data
                            if let acquire = self.captureAcquisition { archive = try await acquire(source) }
                            else {
                                let acquisition = ArticleCaptureSession()
                                self.nativeCaptureSession = acquisition
                                let capturedID = job.id
                                let preparationID = job.preparationID
                                acquisition.onProgress = { [weak self] report in
                                    Task { @MainActor in
                                        guard let self, self.captureWorkerID == workerID, self.isCurrent(session, client: client),
                                              var latest = try? await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == capturedID }),
                                              [.capturing, .needsInteraction].contains(latest.stage), latest.preparationID == preparationID else { return }
                                        latest.resourceReport = report
                                        _ = try? await store.replaceCaptureJobIfCurrent(latest, instance: client.storageInstance)
                                        await self.loadCached()
                                    }
                                }
                                acquisition.onInteraction = { [weak self] in
                                    Task { @MainActor in
                                        guard let self, self.captureWorkerID == workerID, self.isCurrent(session, client: client) else { return }
                                        _ = try? await store.markCaptureInteraction(id: capturedID, instance: client.storageInstance, preparationID: preparationID)
                                        guard self.captureWorkerID == workerID, self.isCurrent(session, client: client) else { return }
                                        await self.loadCached()
                                    }
                                }
                                archive = try await acquisition.capture(source)
                            }
                            try Task.checkCancellation()
                            guard self.isCurrent(session, client: client) else { return }
                            article = try await Task.detached {
                                try CaptureArticleParser.extract(archive: archive, source: source, packageID: job.id)
                            }.value
                            try Task.checkCancellation()
                            guard self.isCurrent(session, client: client) else { return }
                            let generation = try await self.capturePackages.saveGeneration(article, id: job.id, instance: client.storageInstance)
                            if Task.isCancelled || !self.isCurrent(session, client: client) {
                                try? await self.capturePackages.removeGeneration(id: job.id, instance: client.storageInstance, generation: generation)
                                throw CancellationError()
                            }
                            if try await !store.completeCapturePreparation(id: job.id, title: article.title, instance: client.storageInstance, preparationID: job.preparationID, generation: generation, report: article.resourceReport, sourceURL: article.url) {
                                try? await self.capturePackages.removeGeneration(id: job.id, instance: client.storageInstance, generation: generation)
                            }
                        } catch {
                            guard self.captureWorkerID == workerID else { return }
                            guard var latest = try await store.captureJobs(instance: client.storageInstance).first(where: { $0.id == job.id }),
                                  [.capturing, .needsInteraction].contains(latest.stage), latest.preparationID == job.preparationID else { continue }
                            latest.stage = error is CancellationError ? .queued : .failed
                            let site = (try? CaptureSourceURL(latest.url).site) ?? .wechat
                            latest.message = error is CancellationError ? "采集已暂停，连接恢复后继续。" : WechatParseError.captureMessage(for: error, site: site)
                            _ = try await store.replaceCaptureJobIfCurrent(latest, instance: client.storageInstance)
                        }
                        self.nativeCaptureSession = nil
                    }
                    guard !Task.isCancelled, self.isCurrent(session, client: client) else { return }
                    await self.loadCached()
                    await pipeline.process(id: job.id)
                    guard !Task.isCancelled, self.isCurrent(session, client: client) else { return }
                    await self.loadCached()
                }
            } catch {
                if self.isCurrent(session, client: client) { self.syncMessage = error.localizedDescription }
            }
        }
    }

    @discardableResult
    func applyBulk(id: String, bookmarks items: [Bookmark], intent: BulkEditIntent) async -> Bool {
        guard !isApplyingBulk, let coordinator, let client, let session else { return false }
        let operationID = UUID();activeBulkID = operationID
        isApplyingBulk = true;bulkMessage = nil;bulkError = nil
        defer {
            if activeBulkID == operationID { isApplyingBulk = false;activeBulkID = nil;activeBulkTask = nil }
        }
        do {
            let work = Task { try await coordinator.enqueueBulk(id: id, bookmarks: items, intent: intent) }
            activeBulkTask = work
            let receipt = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard isCurrent(session, client: client), activeBulkID == operationID else { return false }
            contentRevision += 1
            if case .organize(_, let additions, _) = intent { await rememberLabels(additions, client: client, session: session) }
            guard isCurrent(session, client: client) else { return false }
            if intent.isDeletion {
                for item in items { annotationLoadIDs[item.id] = nil;annotationItems[item.id] = nil;annotationMessages[item.id] = nil }
            }
            await loadCached()
            guard isCurrent(session, client: client) else { return false }
            if let results = searchResults {
                let overlaid = try await coordinator.overlay(results)
                guard isCurrent(session, client: client) else { return false }
                searchResults = overlaid
            }
            bulkMessage = receipt.waitingCount > 0 ? BulkText.format("已保存到本机，%lld 篇待同步。", receipt.waitingCount) : AppLanguage.text("所选文章无需新增更改。")
            Task { guard isCurrent(session, client: client) else { return };await sync() }
            return true
        } catch {
            guard isCurrent(session, client: client), activeBulkID == operationID else { return false }
            if !(error is CancellationError) { bulkError = error.localizedDescription;bulkMessage = error.localizedDescription }
            return false
        }
    }

    func retryBulk(id: String) async {
        guard let coordinator, let client, let session else { return }
        do {
            try await coordinator.retryBulk(id: id)
            guard isCurrent(session, client: client) else { return }
            await loadCached()
            guard isCurrent(session, client: client) else { return }
            await sync()
        } catch { if isCurrent(session, client: client) { bulkMessage = error.localizedDescription } }
    }

    func resolveBulkConflict(id: String, keepLocal: Bool) async {
        guard let coordinator, let client, let session else { return }
        do {
            try await coordinator.resolveConflict(id: id, keepLocal: keepLocal)
            guard isCurrent(session, client: client) else { return }
            if conflictBookmarkID == id { conflictBookmarkID = nil }
            contentRevision += 1
            await loadCached()
            guard isCurrent(session, client: client) else { return }
            try await reconcileSearchTargets([id], coordinator: coordinator, client: client, session: session)
            guard isCurrent(session, client: client) else { return }
            await sync()
        } catch { if isCurrent(session, client: client) { bulkMessage = error.localizedDescription } }
    }

    func discardMissingBulk(id: String) async {
        guard let coordinator, let client, let session else { return }
        do {
            try await coordinator.discardMissingBookmark(id: id)
            guard isCurrent(session, client: client) else { return }
            if missingBookmarkID == id { missingBookmarkID = nil }
            contentRevision += 1
            await loadCached()
            guard isCurrent(session, client: client) else { return }
            try await reconcileSearchTargets([id], coordinator: coordinator, client: client, session: session)
        } catch { if isCurrent(session, client: client) { bulkMessage = error.localizedDescription } }
    }

    private func reconcileSearchTargets(_ ids: Set<String>, coordinator: SyncCoordinator, client: ReadeckClient, session: ConnectionSession) async throws {
        guard let results = searchResults else { return }
        let latest = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id,$0) })
        let reconciled = results.compactMap { ids.contains($0.id) ? latest[$0.id] : $0 }
        let values = try await coordinator.overlay(reconciled)
        guard isCurrent(session, client: client) else { return }
        searchResults = values
    }

    @discardableResult
    func updateBookmark(_ item: Bookmark, patch: BookmarkPatch) async -> Bool {
        guard let coordinator, let client, let session else { return false }
        do {
            try await coordinator.enqueueMutation(bookmark: item, patch: patch)
            guard isCurrent(session, client: client) else { return false }
            contentRevision += 1
            if let labels = patch.labels { await rememberLabels(labels, client: client, session: session) }
            guard isCurrent(session, client: client) else { return false }
            await loadCached()
            guard isCurrent(session, client: client) else { return false }
            if let results = searchResults {
                let updated = try await coordinator.overlay(results)
                guard isCurrent(session, client: client) else { return false }
                searchResults = updated
            }
            Task { await sync() }
            return true
        } catch {
            guard isCurrent(session, client: client) else { return false }
            syncMessage = ConnectionDiagnostics.message(for: error)
            return false
        }
    }

    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = nil; return }
        guard let client, let session else { return }
        let coordinator = self.coordinator
        let revision = contentRevision
        do {
            let results = try await client.listBookmarks(query: [URLQueryItem(name: "search", value: query)])
            guard !Task.isCancelled, isCurrent(session, client: client), contentRevision == revision else { return }
            let overlaid = try await coordinator?.overlay(results) ?? results
            guard isCurrent(session, client: client), contentRevision == revision else { return }
            searchResults = overlaid
        } catch {
            guard !Task.isCancelled, isCurrent(session, client: client), contentRevision == revision else { return }
            searchResults = nil
            syncMessage = "在线搜索不可用，正在显示本地结果。"
        }
    }

    func togglePinnedLabel(_ name: String) async {
        guard let store, let client, let session else { return }
        do {
            let preferences = try await store.togglePinnedLabel(name, instance: client.storageInstance)
            guard isCurrent(session, client: client) else { return }
            applyLabelPreferences(preferences)
        } catch {
            guard isCurrent(session, client: client) else { return }
            syncMessage = error.localizedDescription
        }
    }

    @discardableResult
    func deleteBookmark(_ item: Bookmark) async -> Bool {
        await performLibraryChange(bookmarkID: item.id) { coordinator in
            try await coordinator.enqueueDeleteBookmark(id: item.id)
        }
    }

    @discardableResult
    func deleteLabel(_ name: String) async -> Bool {
        let aliases: [String]
        if let category = CategoryCodec.name(from: name) {
            let known = bookmarks.flatMap(\.labelValues) + pending.flatMap(\.labels) + cachedLabelNames
            aliases = LabelCatalog.unique(known.filter { CategoryCodec.name(from: $0) == category } + [name])
        } else { aliases = [name] }
        return await performLibraryChange { coordinator in
            for alias in aliases { try await coordinator.enqueueDeleteLabel(name: alias) }
        }
    }

    @discardableResult
    func addManagedLabel(_ value: String, kind: ManagedLabelKind) async -> Bool {
        guard let store, let client, let session else { return false }
        do {
            let name = try kind.validatedName(value)
            let existing = kind == .category ? labelCatalog.categories : labelCatalog.tags
            guard !existing.contains(name) else { throw TaxonomyError.invalid("这个\(kind.title)已存在。") }
            let preferences = try await store.addManagedLabel(name, kind: kind, instance: client.storageInstance)
            guard isCurrent(session, client: client) else { return false }
            applyLabelPreferences(preferences)
            taxonomyMessage = nil
            return true
        } catch {
            guard isCurrent(session, client: client) else { return false }
            taxonomyMessage = error.localizedDescription
            return false
        }
    }

    func loadAnnotations(for item: Bookmark, refresh: Bool = true) async {
        guard let coordinator, let client, let session else { return }
        activeAnnotationBookmarkID = item.id
        let loadID = UUID()
        annotationLoadIDs[item.id] = loadID
        do {
            let cached = try await coordinator.annotations(bookmarkID: item.id, refresh: false)
            guard isCurrent(session, client: client), annotationLoadIDs[item.id] == loadID else { return }
            annotationItems[item.id] = cached
            if refresh {
                let fresh = try await SyncDeadline.run(seconds: policy.captureTimeout) {
                    try await coordinator.annotations(bookmarkID: item.id, refresh: true)
                }
                guard isCurrent(session, client: client), annotationLoadIDs[item.id] == loadID else { return }
                annotationItems[item.id] = fresh
            }
            annotationMessages[item.id] = nil
        } catch {
            guard isCurrent(session, client: client), !Task.isCancelled, annotationLoadIDs[item.id] == loadID else { return }
            annotationMessages[item.id] = "划线暂时无法刷新，已保留本机内容。\(ConnectionDiagnostics.message(for: error))"
        }
    }

    @discardableResult
    func createAnnotation(_ selection: AnnotationSelection, for item: Bookmark, color: String = "yellow", note: String = "") async -> Bool {
        await performLibraryChange(bookmarkID: item.id) { coordinator in
            try await coordinator.enqueueCreateAnnotation(bookmarkID: item.id, selection: selection, color: color, note: note)
        }
    }

    @discardableResult
    func updateAnnotation(_ annotation: BookmarkAnnotation, for item: Bookmark, color: String, note: String) async -> Bool {
        await performLibraryChange(bookmarkID: item.id) { coordinator in
            try await coordinator.enqueueUpdateAnnotation(bookmarkID: item.id, annotation: annotation, color: color, note: note)
        }
    }

    @discardableResult
    func deleteAnnotation(_ annotation: BookmarkAnnotation, for item: Bookmark) async -> Bool {
        await performLibraryChange(bookmarkID: item.id) { coordinator in
            try await coordinator.enqueueDeleteAnnotation(bookmarkID: item.id, id: annotation.id)
        }
    }

    private func performLibraryChange(bookmarkID: String? = nil,
                                      _ change: (SyncCoordinator) async throws -> Void) async -> Bool {
        guard let coordinator, let client, let session else { return false }
        do {
            try await change(coordinator)
            guard isCurrent(session, client: client) else { return false }
            contentRevision += 1
            if let bookmarkID { annotationLoadIDs[bookmarkID] = nil }
            await loadCached()
            guard isCurrent(session, client: client) else { return false }
            if let bookmarkID {
                let items = try await coordinator.annotations(bookmarkID: bookmarkID, refresh: false)
                guard isCurrent(session, client: client) else { return false }
                annotationItems[bookmarkID] = items
                annotationMessages[bookmarkID] = nil
            }
            // Remove deleted results and labels from an outstanding online search as well.
            if let results = searchResults {
                let updated = try await coordinator.overlay(results)
                guard isCurrent(session, client: client) else { return false }
                searchResults = updated
            }
            Task {
                guard isCurrent(session, client: client) else { return }
                await sync()
            }
            return true
        } catch {
            guard isCurrent(session, client: client) else { return false }
            syncMessage = ConnectionDiagnostics.message(for: error)
            return false
        }
    }

    private func rememberLabels(_ labels: [String], client: ReadeckClient, session: ConnectionSession) async {
        guard let store, let preferences = try? await store.recordRecentLabels(labels, instance: client.storageInstance),
              isCurrent(session, client: client) else { return }
        applyLabelPreferences(preferences)
    }

    private func applyLabelPreferences(_ preferences: LabelPreferences) {
        if preferences.revision >= labelPreferences.revision { labelPreferences = preferences }
    }

    func loadCollection(id: String) async {
        guard let client, let session else { return }
        do {
            let items = try await client.listBookmarks(query: [URLQueryItem(name: "collection", value: id)])
            guard isCurrent(session, client: client) else { return }
            collectionIDs = Set(items.map(\.id))
        } catch {
            guard isCurrent(session, client: client) else { return }
            syncMessage = error.localizedDescription
        }
    }

    func article(for item: Bookmark) async throws -> String {
        guard let client, let store, let session else { throw APIError.invalidResponse }
        let instance = client.storageInstance
        let generation = await store.articleCacheGeneration()
        if let cached = try await store.article(id: item.id, instance: instance, notOlderThan: cacheRetention.cutoff(at: Date())) {
            guard isCurrent(session, client: client) else { throw CancellationError() }
            return cached
        }
        let html = try await client.article(id: item.id)
        guard isCurrent(session, client: client) else { throw CancellationError() }
        try await store.setArticle(html, id: item.id, instance: instance, generation: generation)
        guard isCurrent(session, client: client) else { throw CancellationError() }
        return html
    }

    func setCacheRetention(_ value: CacheRetention) async {
        cacheRetention = value
        cacheDefaults.set(value.rawValue, forKey: "cache.retentionDays")
        await maintainArticleCache()
    }

    func refreshCacheStatistics() async {
        guard let store else { return }
        let requestID = UUID()
        cacheStatisticsID = requestID
        do {
            let value = try await store.articleCacheStatistics()
            let captureSizes = await capturePackages.diskUsage()
            guard cacheStatisticsID == requestID else { return }
            cacheStatistics = value
            captureStorageBytes = captureSizes.pending
            legacyWechatCacheBytes = captureSizes.legacy
        } catch {
            guard cacheStatisticsID == requestID else { return }
            cacheCleanupMessage = "无法读取缓存占用：\(error.localizedDescription)"
        }
    }

    func clearArticleCache() async { await maintainArticleCache(clearAll: true) }

    private func maintainArticleCache(clearAll: Bool = false) async {
        guard let store else { return }
        cacheOperationCount += 1
        isCleaningCache = true
        defer {
            cacheOperationCount -= 1
            isCleaningCache = cacheOperationCount > 0
        }
        do {
            let result = try await store.cleanArticleCache(through: clearAll ? nil : cacheRetention.cutoff(at: Date()))
            if clearAll || result.removedCount > 0 {
                var message = "\(clearAll ? "已清理" : "自动清理了") \(result.removedCount) 篇正文，约 \(ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file))。"
                if result.protectedCount > 0 { message += "\(result.protectedCount) 篇包含待同步更改，暂时保留。" }
                cacheCleanupMessage = message
            }
        } catch {
            cacheCleanupMessage = "缓存清理未完成：\(error.localizedDescription)"
        }
        await refreshCacheStatistics()
    }

    func updateReadingProgress(_ progress: Int, for item: Bookmark) async {
        guard progress > (item.readProgress ?? 0) else { return }
        await updateBookmark(item, patch: BookmarkPatch(readProgress: progress))
    }

    private func cancelCaptureRefresh() {
        captureRefreshTask?.cancel()
        captureRefreshTask = nil
        captureRefreshID = nil
    }

    private func resetCaptureRefresh() {
        cancelCaptureRefresh()
        captureSchedule = CaptureRefreshSchedule()
    }

    private func scheduleCaptureRefresh() {
        cancelCaptureRefresh()
        captureSchedule.reconcile(bookmarks)
        guard !isSyncing, let client, let session,
              let delay = captureSchedule.nextDelay() else { return }
        let refreshID = UUID()
        captureRefreshID = refreshID
        captureRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, delay))) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.isCurrent(session, client: client) else { return }
            defer {
                if self.captureRefreshID == refreshID {
                    self.captureRefreshTask = nil
                    self.captureRefreshID = nil
                }
            }
            await self.refreshCaptures()
        }
    }

    private func refreshCaptures() async {
        guard let coordinator, let client, let session,
              isCurrent(session, client: client), !isSyncing else { return }
        let ids = captureSchedule.takeDueIDs()
        guard !ids.isEmpty else { scheduleCaptureRefresh(); return }
        let syncID = UUID()
        activeSyncID = syncID
        isSyncing = true
        var succeeded = false
        defer { finishSync(syncID, refreshCaptures: succeeded) }
        do {
            let timeout = policy.captureTimeout
            let operation = Task {
                try await SyncDeadline.run(seconds: timeout) { try await coordinator.refreshCaptures(ids: ids) }
            }
            activeOperation = operation
            let snapshot = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard isCurrent(session, client: client) else { return }
            bookmarks = snapshot.bookmarks
            pending = snapshot.pending
            pendingMutations = snapshot.pendingMutations
            succeeded = true
        } catch {
            guard isCurrent(session, client: client) else { return }
            if !(error is CancellationError) {
                syncMessage = ConnectionDiagnostics.message(for: error)
                scheduleRecovery(for: error)
            }
            conflictBookmarkID = (error as? SyncError)?.conflictingBookmarkID
            missingBookmarkID = (error as? SyncError)?.missingBookmarkID
            await loadCached()
        }
    }

    private func finishSync(_ syncID: UUID, refreshCaptures: Bool) {
        guard activeSyncID == syncID else { return }
        activeOperation = nil
        activeSyncID = nil
        isSyncing = false
        // Wake/network/user requests can arrive while a failed round is loading its cache.
        // Honor that pending request after the round releases its busy state as well.
        if needsSync {
            needsSync = false
            Task { await sync() }
        } else if refreshCaptures {
            scheduleCaptureRefresh()
        }
    }

    func cancelSync() {
        needsSync = false
        cancelRecovery()
        cancelCaptureRefresh()
        activeOperation?.cancel()
        syncMessage = "已取消本轮同步，本机更改仍保留。"
    }

    private func stopConnectionWork() {
        activeBulkTask?.cancel();activeBulkTask = nil;activeBulkID = nil;isApplyingBulk = false
        cancelCaptureWork()
        periodicSync?.cancel()
        periodicSync = nil
        cancelCaptureRefresh()
        cancelRecovery()
        activeOperation?.cancel()
        activeOperation = nil
        activeSyncID = nil
        isSyncing = false
        needsSync = false
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        nextRetryAt = nil
    }

    private func scheduleRecovery(for error: Error) {
        cancelRecovery()
        needsLocalNetworkPermission = error is NetworkAccessError
        guard ConnectionDiagnostics.shouldRetry(error), let client, let session else { return }
        let delay = policy.retryDelay(attempt: retryAttempt)
        retryAttempt += 1
        nextRetryAt = Date().addingTimeInterval(delay)
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self, self.isCurrent(session, client: client) else { return }
            self.recoveryTask = nil
            await self.sync()
        }
    }

    private func handleConnectionEvent(_ event: ConnectionEvent) async {
        guard connected else { return }
        switch event {
        case .activated:
            guard syncMessage != nil || lastSyncAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        case .woke, .networkAvailable: break
        }
        startCaptureWork()
        await sync()
    }

    private func startPeriodicSync() {
        periodicSync?.cancel()
        periodicSync = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.startCaptureWork()
                await self?.sync()
            }
        }
    }

    private func isCurrent(_ session: ConnectionSession, client: ReadeckClient) -> Bool {
        generations.isCurrent(session, for: client)
    }
}

enum ConnectionError: LocalizedError {
    case missingToken
    var errorDescription: String? { "请输入 Readeck API Token。" }
}

struct ConnectionSession: Equatable {
    let generation: UUID
    let instance: String
}

struct ConnectionGenerations {
    private var current: ConnectionSession?

    mutating func begin(for client: ReadeckClient) -> ConnectionSession {
        let session = ConnectionSession(generation: UUID(), instance: client.storageInstance)
        current = session
        return session
    }

    mutating func invalidate() {
        current = nil
    }

    func isCurrent(_ session: ConnectionSession, for client: ReadeckClient) -> Bool {
        session == current && session.instance == client.storageInstance
    }
}
