import XCTest
@testable import ReadeckMac

private actor CaptureTransportProbe {
    var sends = 0
    func lostResponse() throws -> String { sends += 1; throw URLError(.networkConnectionLost) }
    func accepted() -> String { sends += 1; return "nas-id" }
    func count() -> Int { sends }
}

private actor VerificationGate {
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

final class CapturePipelineTests: XCTestCase {
    func testPublishedGenerationUploadsInsteadOfOldPartialPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let packages = CapturePackageStore(root: root.appendingPathComponent("packages"))
        var job = CaptureJob(url: "https://mp.weixin.qq.com/s/a", title: "", labels: [])
        let old = CapturedArticle(url: URL(string: job.url)!, title: "old", author: "", siteName: "", published: nil, html: "<p>old partial</p>", assets: [], missingImages: ["missing"])
        let new = CapturedArticle(url: old.url, title: "new", author: "", siteName: "", published: nil, html: "<p>new complete</p>", assets: [], missingImages: [])
        _ = try await packages.save(old, id: job.id, instance: "a")
        job.packageGeneration = try await packages.saveGeneration(new, id: job.id, instance: "a")
        job.stage = .ready
        try await store.saveCaptureJob(job, instance: "a")
        let pipeline = CapturePipeline(store: store, packages: packages, instance: "a", send: { package, _, _ in
            XCTAssertEqual(package.html, new.html); return "new-id"
        }, candidates: { _ in [] }, verify: { id, manifest in
            XCTAssertEqual(manifest.text, "newcomplete")
            return Bookmark(id: id, url: manifest.url.absoluteString, loaded: true, state: 0, hasArticle: true)
        })
        await pipeline.process(id: job.id)
        let result = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(result?.stage, .complete)
        let directory = await packages.directory(id: job.id, instance: "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testLateVerificationFailureCannotOverwriteReplacementCompletion() async throws {
        let (store, packages, root, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = VerificationGate()
        let first = CapturePipeline(store: store, packages: packages, instance: "a", send: { _, _, _ in "nas-id" }, candidates: { _ in [] }, verify: { _, _ in
            await gate.wait(); throw URLError(.timedOut)
        })
        let old = Task { await first.process(id: job.id) }
        for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        let replacement = CapturePipeline(store: store, packages: packages, instance: "a", send: { _, _, _ in XCTFail("must not send"); return "" }, candidates: { _ in [] }, verify: { id, manifest in Bookmark(id: id, url: manifest.url.absoluteString, loaded: true, state: 0, hasArticle: true) })
        await replacement.process(id: job.id)
        await gate.release(); await old.value
        let saved = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(saved?.stage, .complete)
        XCTAssertEqual(saved?.bookmarkID, "nas-id")
    }
    func testLostResponseNeverAutomaticallyPostsAgain() async throws {
        let (store, packages, root, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = CaptureTransportProbe()
        let pipeline = CapturePipeline(store: store, packages: packages, instance: "a", send: { _, _, _ in try await probe.lostResponse() }, candidates: { _ in [] }, verify: { _, _ in throw CaptureError.invalidPackage })
        await pipeline.process(id: job.id)
        await pipeline.process(id: job.id)
        let count = await probe.count()
        XCTAssertEqual(count, 1)
        let jobs = try await store.captureJobs(instance: "a")
        XCTAssertEqual(jobs.first?.stage, .uncertain)
        _ = try await packages.load(id: job.id, instance: "a")
    }

    func testReturnedIDIsDurableBeforeVerificationAndRestartDoesNotRepost() async throws {
        let (store, packages, root, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = CaptureTransportProbe()
        let pipeline = CapturePipeline(store: store, packages: packages, instance: "a", send: { _, _, _ in await probe.accepted() }, candidates: { _ in XCTFail("must use returned ID"); return [] }, verify: { id, _ in
            let current = try await store.captureJobs(instance: "a").first
            XCTAssertEqual(current?.bookmarkID, "nas-id")
            XCTAssertEqual(current?.stage, .verifying)
            throw CaptureError.verification("still processing")
        })
        await pipeline.process(id: job.id)
        try await store.recoverCaptureJobs(instance: "a")
        await pipeline.process(id: job.id)
        let count = await probe.count()
        XCTAssertEqual(count, 1)
        let saved = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(saved?.stage, .verifying)
    }

    func testMissingImagesBlockUploadAndRetainPackage() async throws {
        let (store, packages, root, job) = try await fixture(missing: ["image"])
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = CaptureTransportProbe()
        let pipeline = CapturePipeline(store: store, packages: packages, instance: "a", send: { _, _, _ in await probe.accepted() }, candidates: { _ in [] }, verify: { _, _ in throw CaptureError.invalidPackage })
        await pipeline.process(id: job.id)
        let count = await probe.count()
        XCTAssertEqual(count, 0)
        let saved = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(saved?.stage, .failed)
        XCTAssertNil(saved?.attemptedAt)
    }

    func testMultipleReconciliationCandidatesStayUncertainWithoutClaimingOrSending() async throws {
        let (store, packages, root, original) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = original; job.stage = .uncertain; job.attemptedAt = Date()
        try await store.saveCaptureJob(job, instance: "a")
        let probe = CaptureTransportProbe()
        let pipeline = CapturePipeline(store: store, packages: packages, instance: "a", send: { _, _, _ in await probe.accepted() }, candidates: { job in
            [Bookmark(id: "one", url: job.url), Bookmark(id: "two", url: job.url)]
        }, verify: { _, _ in XCTFail("ambiguous candidate must not be claimed"); throw CaptureError.invalidPackage })
        await pipeline.process(id: job.id)
        let count = await probe.count(); XCTAssertEqual(count, 0)
        let saved = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(saved?.stage, .uncertain); XCTAssertNil(saved?.bookmarkID)
    }

    func testVerifiedArchiveCompletesAndReleasesOnlyItsPackage() async throws {
        let (store, packages, root, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = CapturePipeline(store: store, packages: packages, instance: "a", send: { _, _, _ in "nas-id" }, candidates: { _ in [] }, verify: { id, manifest in
            Bookmark(id: id, url: manifest.url.absoluteString, loaded: true, state: 0, hasArticle: true)
        })
        await pipeline.process(id: job.id)
        let saved = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(saved?.stage, .complete)
        let bookmark = try await store.bookmark(id: "nas-id", instance: "a")
        XCTAssertNotNil(bookmark)
        do { _ = try await packages.load(id: job.id, instance: "a"); XCTFail("verified package should be released") } catch { }
    }

    private func fixture(missing: [String] = []) async throws -> (LocalStore, CapturePackageStore, URL, CaptureJob) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(url: root.appendingPathComponent("test.sqlite"))
        let packages = CapturePackageStore(root: root.appendingPathComponent("packages"))
        var job = CaptureJob(url: "https://mp.weixin.qq.com/s/one", title: "title", labels: [])
        job.stage = .ready
        _ = try await packages.save(CapturedArticle(url: URL(string: job.url)!, title: job.title, author: "", siteName: "", published: nil, html: "<p>text</p>", assets: [], missingImages: missing), id: job.id, instance: "a")
        try await store.saveCaptureJob(job, instance: "a")
        return (store, packages, root, job)
    }
}
