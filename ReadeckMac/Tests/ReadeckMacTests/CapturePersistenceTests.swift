import XCTest
import ImageIO
@testable import ReadeckMac

final class CapturePersistenceTests: XCTestCase {
    func testManySupportedAnimationsCanRoundTripTheirFrameMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(WechatCaptureTests.png() as CFData, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "com.compuserve.gif" as CFString, 300, nil))
        for _ in 0..<300 { CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let assets = (0..<14).map { CapturedAsset(location: URL(string: "https://readeck-capture.invalid/animation-\($0)")!, mimeType: "image/gif", data: output as Data, width: 32, height: 32) }
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/a")!, title: "", author: "", siteName: "", published: nil, html: "<p>正文</p>", assets: assets, missingImages: [])
        let packages = CapturePackageStore(root: root)
        let generation = try await packages.saveGeneration(article, id: "a", instance: "one")
        let loaded = try await packages.load(id: "a", instance: "one", generation: generation)
        XCTAssertEqual(loaded.manifest.assets.count, 14)
        XCTAssertEqual(loaded.manifest.assets.first?.frameFingerprints?.count, 300)
    }
    func testLegacyFrameMetadataIsRecoveredFromChecksumVerifiedImageBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = CapturePackageStore(root: root)
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/a")!, title: "", author: "", siteName: "", published: nil, html: "<p>正文</p>", assets: [.init(location: URL(string: "https://readeck-capture.invalid/image")!, mimeType: "image/png", data: WechatCaptureTests.png(), width: 32, height: 32)], missingImages: [])
        _ = try await packages.save(article, id: "a", instance: "one")
        let directory = await packages.directory(id: "a", instance: "one")
        let file = directory.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var assets = try XCTUnwrap(json["assets"] as? [[String: Any]])
        assets[0].removeValue(forKey: "frameCount"); assets[0].removeValue(forKey: "frameFingerprints")
        json["assets"] = assets
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let loaded = try await packages.load(id: "a", instance: "one")
        XCTAssertEqual(loaded.manifest.assets.first?.frameCount, 1)
    }
    func testLateInteractionCannotReviveCancellationOrAnotherPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let job = CaptureJob(url: "https://mp.weixin.qq.com/s/one", title: "", labels: [])
        try await store.saveCaptureJob(job, instance: "a")
        let claimed = try await store.claimCapturePreparation(id: job.id, instance: "a")
        let claim = try XCTUnwrap(claimed)
        _ = try await store.cancelCaptureJob(id: job.id, instance: "a")
        let updated = try await store.markCaptureInteraction(id: job.id, instance: "a", preparationID: claim.preparationID)
        XCTAssertFalse(updated)
        let current = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(current?.stage, .cancelled)
    }
    func testGenerationPublicationIsCrashSafeAndRejectsStalePreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = CapturePackageStore(root: root.appendingPathComponent("packages"))
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let old = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/one")!, title: "old", author: "", siteName: "", published: nil, html: "<p>old</p>", assets: [], missingImages: ["missing"])
        let new = CapturedArticle(url: old.url, title: "new", author: "", siteName: "", published: nil, html: "<p>new</p>", assets: [], missingImages: [])
        let job = CaptureJob(url: old.url.absoluteString, title: "", labels: [])
        _ = try await packages.save(old, id: job.id, instance: "a")
        try await store.saveCaptureJob(job, instance: "a")
        let claimed = try await store.claimCapturePreparation(id: job.id, instance: "a")
        let claim = try XCTUnwrap(claimed)
        let generation = try await packages.saveGeneration(new, id: job.id, instance: "a")
        // Crash before publication: the persisted job still references the legacy package.
        let persistedJobs = try await store.captureJobs(instance: "a")
        let persisted = try XCTUnwrap(persistedJobs.first)
        let before = try await packages.load(id: job.id, instance: "a", generation: persisted.packageGeneration)
        XCTAssertEqual(before.html, old.html)
        let published = try await store.completeCapturePreparation(id: job.id, title: new.title, instance: "a", preparationID: claim.preparationID, generation: generation)
        XCTAssertTrue(published)
        let reopened = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let afterJobs = try await reopened.captureJobs(instance: "a")
        let afterJob = try XCTUnwrap(afterJobs.first)
        let after = try await packages.load(id: job.id, instance: "a", generation: afterJob.packageGeneration)
        XCTAssertEqual(after.html, new.html)
        let stale = try await store.completeCapturePreparation(id: job.id, title: "stale", instance: "a", preparationID: claim.preparationID, generation: nil)
        XCTAssertFalse(stale)
        let legacy = try await packages.load(id: job.id, instance: "a")
        XCTAssertEqual(legacy.html, old.html)
        do { _ = try await packages.load(id: job.id, instance: "a", generation: "../outside"); XCTFail("invalid generation") } catch { }
    }

    func testCancelledPreparationCannotPublishGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let job = CaptureJob(url: "https://mp.weixin.qq.com/s/one", title: "", labels: [])
        try await store.saveCaptureJob(job, instance: "a")
        let claimed = try await store.claimCapturePreparation(id: job.id, instance: "a")
        let claim = try XCTUnwrap(claimed)
        _ = try await store.cancelCaptureJob(id: job.id, instance: "a")
        let accepted = try await store.completeCapturePreparation(id: job.id, title: "late", instance: "a", preparationID: claim.preparationID, generation: UUID().uuidString)
        XCTAssertFalse(accepted)
    }

    func testPackageIsAccountScopedAndDetectsTampering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = CapturePackageStore(root: root)
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/one")!, title: "文章", author: "作者", siteName: "公众号", published: nil, html: "<p>正文</p>", assets: [], missingImages: [])
        let id = UUID().uuidString
        let manifest = try await packages.save(article, id: id, instance: "account-a")
        XCTAssertEqual(manifest.title, "文章")
        let loaded = try await packages.load(id: id, instance: "account-a")
        XCTAssertEqual(loaded.html, article.html)
        do { _ = try await packages.load(id: id, instance: "account-b"); XCTFail("cross-account load") } catch { }
        let directory = await packages.directory(id: id, instance: "account-a")
        try Data("modified".utf8).write(to: directory.appendingPathComponent("page.html"))
        do { _ = try await packages.load(id: id, instance: "account-a"); XCTFail("tampered package") } catch { }
    }

    func testInterruptedUploadIsUncertainAndRetainsFrozenAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("test.sqlite"))
        var job = CaptureJob(url: "https://mp.weixin.qq.com/s/one", title: "文章", labels: ["分类/科技"])
        job.stage = .uploading; job.attemptedAt = Date()
        try await store.saveCaptureJob(job, instance: "a")
        try await store.recoverCaptureJobs(instance: "a")
        let jobs = try await store.captureJobs(instance: "a")
        XCTAssertEqual(jobs.first?.stage, .uncertain)
        XCTAssertEqual(jobs.first?.attemptedAt, job.attemptedAt)
        let other = try await store.captureJobs(instance: "b")
        XCTAssertTrue(other.isEmpty)
    }

    func testMultipartUsesOnlyResourcePartsAndCanonicalLocations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/one")!, title: "文章", author: "", siteName: "", published: nil,
            html: "<img src='https://readeck-capture.invalid/one/p.png'>", assets: [CapturedAsset(location: URL(string: "https://readeck-capture.invalid/one/p.png")!, mimeType: "image/png", data: WechatCaptureTests.png(), width: 32, height: 32)], missingImages: [])
        let packages = CapturePackageStore(root: root)
        _ = try await packages.save(article, id: "one", instance: "a")
        let loaded = try await packages.load(id: "one", instance: "a")
        let file = try CaptureMultipart.write(package: loaded, title: "标题", labels: ["分类/科技"], directory: root)
        let body = String(decoding: try Data(contentsOf: file.url), as: UTF8.self)
        XCTAssertEqual(body.components(separatedBy: "name=\"resource\"").count - 1, 2)
        XCTAssertFalse(body.contains("name=\"html\""))
        XCTAssertTrue(body.contains("Location: https://mp.weixin.qq.com/s/one\r\n"))
        XCTAssertTrue(body.contains("name=\"feature_find_main\"\r\n\r\nfalse"))
        XCTAssertFalse(body.contains(root.path))
    }

    func testUploadClaimWaitsForTaxonomyAndCancellationCannotOverwriteAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        var job = CaptureJob(url: "https://mp.weixin.qq.com/s/one", title: "文章", labels: ["分类/科技"])
        job.stage = .ready
        try await store.saveCaptureJob(job, instance: "a")
        try await store.enqueueDeleteLabel(name: "分类/科技", instance: "a")
        let blocked = try await store.claimCaptureUpload(id: job.id, instance: "a")
        XCTAssertNil(blocked)
        for action in try await store.actions(instance: "a") { try await store.removeAction(id: action.id, instance: "a") }
        let claimed = try await store.claimCaptureUpload(id: job.id, instance: "a")
        XCTAssertEqual(claimed?.labels, [])
        let cancelled = try await store.cancelCaptureJob(id: job.id, instance: "a")
        XCTAssertFalse(cancelled)
        let current = try await store.captureJobs(instance: "a").first
        XCTAssertEqual(current?.stage, .uploading)
        XCTAssertNotNil(current?.attemptedAt)
    }
}
