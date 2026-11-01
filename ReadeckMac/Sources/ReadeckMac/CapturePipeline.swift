import Foundation

/// Runs outside normal sync deadlines. Every job is permanently bound to its account.
actor CapturePipeline {
    let store: LocalStore
    let packages: CapturePackageStore
    let instance: String
    let send: @Sendable (CapturePackage, String, [String]) async throws -> String
    let candidates: @Sendable (CaptureJob) async throws -> [Bookmark]
    let verify: @Sendable (String, CaptureManifest) async throws -> Bookmark

    init(store: LocalStore, packages: CapturePackageStore, instance: String,
         send: @escaping @Sendable (CapturePackage, String, [String]) async throws -> String,
         candidates: @escaping @Sendable (CaptureJob) async throws -> [Bookmark],
         verify: @escaping @Sendable (String, CaptureManifest) async throws -> Bookmark) {
        self.store = store; self.packages = packages; self.instance = instance
        self.send = send; self.candidates = candidates; self.verify = verify
    }

    init(client: ReadeckClient, store: LocalStore, packages: CapturePackageStore) {
        self.init(store: store, packages: packages, instance: client.storageInstance,
            send: { try await client.uploadCapture($0, title: $1, labels: $2) },
            candidates: { job in
                var pending = PendingSave(url: job.url, title: job.title, labels: job.labels)
                pending.created = job.created; pending.attemptedAt = job.attemptedAt
                return try await client.matchingBookmarks(for: pending)
            }, verify: { try await client.verifyCapture(id: $0, manifest: $1) })
    }

    func process(id: String) async {
        guard var job = try? await store.captureJobs(instance: instance).first(where: { $0.id == id }),
              [.ready, .uncertain, .verifying].contains(job.stage) else { return }
        do {
            let package = try await packages.load(id: id, instance: instance, generation: job.packageGeneration)
            try Task.checkCancellation()
            if job.stage == .ready {
                guard package.manifest.missingImages.isEmpty else { throw CaptureError.missingImageDetails(package.manifest.missingImages) }
                guard let claimed = try await store.claimCaptureUpload(id: id, instance: instance) else { return }
                job = claimed
                // Once persisted as uploading, any loss of response is uncertain. Never time-based rePOST.
                let bookmarkID = try await send(package, job.title, job.labels)
                guard let accepted = try await store.recordCaptureAccepted(id: id, bookmarkID: bookmarkID, attemptedAt: job.attemptedAt, instance: instance) else { return }
                job = accepted
            }
            try Task.checkCancellation()
            if job.stage == .uncertain {
                let matches = try await candidates(job)
                guard matches.count == 1, let candidate = matches.first else {
                    job.message = matches.isEmpty ? "尚未找到可确认的归档；保留任务继续核对，不自动重发。" : "存在多个可能的归档，请在 NAS 核对；不会自动重复上传。"
                    _ = try await store.replaceCaptureJobIfCurrent(job, instance: instance)
                    return
                }
                // A matching URL alone is insufficient: verify canonical text and NAS image resources first.
                _ = try await SyncDeadline.run(seconds: 60) { [verify] in try await verify(candidate.id, package.manifest) }
                job.bookmarkID = candidate.id; job.stage = .verifying
                guard let claimed = try await store.replaceCaptureJobIfCurrent(job, instance: instance) else { return }
                job = claimed
            }
            guard let bookmarkID = job.bookmarkID else { throw CaptureError.invalidPackage }
            let bookmark = try await SyncDeadline.run(seconds: 60) { [verify] in try await verify(bookmarkID, package.manifest) }
            try Task.checkCancellation()
            job.stage = .complete; job.message = nil
            guard try await store.completeCaptureJob(job, bookmark: bookmark, instance: instance) else { return }
            try? await packages.remove(id: id, instance: instance)
        } catch {
            if job.stage == .uploading { job.stage = .uncertain }
            else if job.stage == .ready { job.stage = .failed }
            job.message = error is CancellationError ? "任务已暂停，连接恢复后继续核对。" : ConnectionDiagnostics.message(for: error)
            _ = try? await store.replaceCaptureJobIfCurrent(job, instance: instance)
        }
    }
}
