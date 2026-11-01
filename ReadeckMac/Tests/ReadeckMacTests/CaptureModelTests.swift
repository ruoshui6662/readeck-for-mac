import XCTest
@testable import ReadeckMac

private actor AcquisitionGate {
    var continuation: CheckedContinuation<Data, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: Data()); continuation = nil }
}

private actor ImportCancellationProbe {
    var started = false
    var cancelled = false
    func start() { started = true }
    func cancel() { cancelled = true }
}

final class CaptureModelTests: XCTestCase {
    @MainActor
    func testFailedReimportKeepsOriginalTaskAndPackageGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
        var job = CaptureJob(url: "https://www.rednote.com/discovery/item/abc123", title: "原笔记", labels: ["分类/食谱", "午餐"])
        job.stage = .failed; job.packageGeneration = "original-generation"
        try await store.saveCaptureJob(job, instance: client.storageInstance)
        let model = AppModel(client: client, store: store, capturePackages: CapturePackageStore(root: root.appendingPathComponent("packages")), captureImportParser: { _, _, _, _ in throw CaptureError.invalidPackage })
        let file = root.appendingPathComponent("test.mhtml"); try Data("invalid".utf8).write(to: file)
        let result = await model.importCaptureFile(file, sourceURL: job.url, title: job.title, category: "食谱", tags: ["午餐"], replacingJobID: job.id)
        XCTAssertFalse(result)
        XCTAssertEqual(model.captureJobs.first?.stage, .failed, "The visible task must leave importing immediately on failure")
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        XCTAssertEqual(jobs.count, 1); XCTAssertEqual(jobs.first?.id, job.id)
        XCTAssertEqual(jobs.first?.stage, .failed); XCTAssertEqual(jobs.first?.packageGeneration, "original-generation")
        XCTAssertEqual(Set(jobs.first?.labels ?? []), Set(job.labels)); XCTAssertNil(jobs.first?.attemptedAt)
        model.cancelCaptureWork()
    }

    @MainActor
    func testCancelImportAndDisconnectCancelRegisteredImportWork() async throws {
        for disconnect in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
            let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
            let probe = ImportCancellationProbe()
            let model = AppModel(client: client, store: store, capturePackages: CapturePackageStore(root: root.appendingPathComponent("packages")), captureImportParser: { _, _, _, _ in
                await probe.start()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { await probe.cancel(); throw error }
                throw CaptureError.invalidPackage
            })
            let file = root.appendingPathComponent("test.mhtml"); try Data("fixture".utf8).write(to: file)
            let work = Task { await model.importCaptureFile(file, sourceURL: "https://www.rednote.com/discovery/item/abc123", title: "", category: nil, tags: []) }
            for _ in 0..<100 { if await probe.started { break }; try await Task.sleep(for: .milliseconds(5)) }
            let jobs = try await store.captureJobs(instance: client.storageInstance)
            let job = try XCTUnwrap(jobs.first)
            if disconnect { model.cancelCaptureWork() } else { await model.cancelCapture(job.id) }
            for _ in 0..<100 { if await probe.cancelled { break }; try await Task.sleep(for: .milliseconds(5)) }
            let cancelled = await probe.cancelled
            XCTAssertTrue(cancelled, "Import network work must receive cancellation promptly")
            let saved = await work.value; XCTAssertFalse(saved)
            model.cancelCaptureWork()
        }
    }

    @MainActor
    func testFailedXiaohongshuImportDoesNotRestartAutomaticAcquisition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
        var job = CaptureJob(url: "https://www.rednote.com/discovery/item/abc123", title: "未完成导入", labels: [])
        job.stage = .failed; try await store.saveCaptureJob(job, instance: client.storageInstance)
        var acquisitions = 0
        let model = AppModel(client: client, store: store, captureAcquisition: { _ in acquisitions += 1; throw URLError(.notConnectedToInternet) })
        await model.retryCapture(job.id)
        for _ in 0..<100 { if acquisitions > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        model.cancelCaptureWork()
        XCTAssertEqual(acquisitions, 0)
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        XCTAssertEqual(jobs.first?.stage, .failed)
    }

    @MainActor
    func testBaikeUsesLocalCaptureQueueAndStripsTrackingParameters() async throws {
        for input in ["https://www.ithome.com/1/019/238.htm", "https://baike.baidu.com/item/计算机/140192?fromModule=home_hotspot", "https://movie.douban.com/review/123/", "https://www.bilibili.com/opus/456", "https://www.bilibili.com/read/cv123/"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
            let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
            var acquired: CaptureSourceURL?
            let model = AppModel(client: client, store: store, capturePackages: CapturePackageStore(root: root.appendingPathComponent("packages")), captureAcquisition: { source in
                acquired = source; throw URLError(.notConnectedToInternet)
            })
            let saved = await model.saveURL(input)
            XCTAssertTrue(saved)
            for _ in 0..<100 { if acquired != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
            model.cancelCaptureWork()
            let jobs = try await store.captureJobs(instance: client.storageInstance)
            let job = try XCTUnwrap(jobs.first)
            let pending = try await store.pending(instance: client.storageInstance)
            XCTAssertTrue(pending.isEmpty)
            XCTAssertNotNil(acquired)
            XCTAssertFalse(job.url.contains("private"))
            XCTAssertFalse(job.url.contains("fromModule"))
        }
    }

    @MainActor
    func testOrdinaryPublicArticleURLsRemainInNASSaveQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
        var acquisitions = 0
        let model = AppModel(client: client, store: store, captureAcquisition: { _ in acquisitions += 1; throw URLError(.notConnectedToInternet) })
        let urls = [
            "https://sspai.com/post/96715",
            "https://zh.wikipedia.org/wiki/电子计算机",
        ]
        for url in urls {
            let saved = await model.saveURL(url)
            XCTAssertTrue(saved)
        }
        let pending = try await store.pending(instance: client.storageInstance)
        XCTAssertEqual(Set(pending.map(\.url)), Set(urls.compactMap { URL(string: $0)?.absoluteString }))
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertEqual(acquisitions, 0)
        model.cancelCaptureWork()
    }

    @MainActor
    func testXiaohongshuLinkDoesNotEnqueueAutomaticCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
        let model = AppModel(client: client, store: store, captureAcquisition: { _ in throw URLError(.notConnectedToInternet) })
        let saved = await model.saveURL("https://www.xiaohongshu.com/explore/abc123?xsec_token=private")
        XCTAssertFalse(saved)
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        let pending = try await store.pending(instance: client.storageInstance)
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertTrue(pending.isEmpty)
        model.cancelCaptureWork()
    }

    @MainActor
    func testOldAutomaticXiaohongshuTaskIsPausedWithoutAcquisitionOrUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
        var job = CaptureJob(url: "https://www.rednote.com/discovery/item/abc123", title: "旧任务", labels: [])
        job.requestURL = job.url + "?xsec_token=fixture"
        try await store.saveCaptureJob(job, instance: client.storageInstance)
        var acquisitions = 0
        let model = AppModel(client: client, store: store, captureAcquisition: { _ in acquisitions += 1; throw URLError(.notConnectedToInternet) })
        for _ in 0..<100 {
            if try await store.captureJobs(instance: client.storageInstance).first?.stage == .failed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.cancelCaptureWork()
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        let saved = try XCTUnwrap(jobs.first)
        XCTAssertEqual(saved.stage, .failed)
        XCTAssertNil(saved.attemptedAt)
        XCTAssertNotNil(saved.requestURL)
        XCTAssertEqual(acquisitions, 0)
    }

    @MainActor
    func testManualFileImportCanReplacePausedAutomaticXiaohongshuTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "fixture-only")
        var job = CaptureJob(url: "https://www.rednote.com/discovery/item/abc123", title: "旧任务", labels: [])
        job.requestURL = job.url + "?xsec_token=fixture"
        job.stage = .failed
        try await store.saveCaptureJob(job, instance: client.storageInstance)
        let model = AppModel(client: client, store: store,
            capturePackages: CapturePackageStore(root: root.appendingPathComponent("packages")),
            captureImportParser: { _, _, source, _ in
                CapturedArticle(url: source.canonical, title: "手动导入", author: "", siteName: "", published: nil,
                                html: "<p>文章</p>", assets: [], missingImages: [])
            })
        let file = root.appendingPathComponent("saved.mhtml")
        try Data("fixture".utf8).write(to: file)
        let imported = await model.importCaptureFile(file, sourceURL: job.url, title: "", category: nil, tags: [], replacingJobID: job.id)
        XCTAssertTrue(imported)
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        XCTAssertNil(jobs.first?.requestURL, "A manual replacement must no longer be marked as an automatic browser task")
        model.cancelCaptureWork()
    }

    func testResolvedShortLinkUpdatesPublicSourceBeforeUploadWithoutOverwritingRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        var job = CaptureJob(url: "https://xhslink.com/a/short", title: "", labels: [])
        job.requestURL = job.url
        try await store.saveCaptureJob(job, instance: "fixture")
        let claimed = try await store.claimCapturePreparation(id: job.id, instance: "fixture")
        let claim = try XCTUnwrap(claimed)
        let done = try await store.completeCapturePreparation(id: job.id, title: "图集", instance: "fixture", preparationID: claim.preparationID, sourceURL: URL(string: "https://www.xiaohongshu.com/explore/abc123")!)
        XCTAssertTrue(done)
        let updates = try await store.captureJobs(instance: "fixture")
        let updated = try XCTUnwrap(updates.first)
        XCTAssertEqual(updated.url, "https://www.xiaohongshu.com/explore/abc123")
        XCTAssertEqual(updated.requestURL, job.requestURL)
    }

    @MainActor
    func testFailedRecapturePreservesExistingPartialPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "test")
        let packages = CapturePackageStore(root: root.appendingPathComponent("packages"))
        var job = CaptureJob(url: "https://mp.weixin.qq.com/s/one", title: "旧文章", labels: [])
        job.stage = .failed
        try await store.saveCaptureJob(job, instance: client.storageInstance)
        let article = CapturedArticle(url: URL(string: job.url)!, title: job.title, author: "", siteName: "", published: nil,
            html: "<p>已取得的正文</p>", assets: [], missingImages: ["正文图片 1：缺失"])
        _ = try await packages.save(article, id: job.id, instance: client.storageInstance)
        var attempts = 0
        let model = AppModel(client: client, store: store, capturePackages: packages, captureAcquisition: { _ in attempts += 1; throw URLError(.notConnectedToInternet) })
        await model.retryCapture(job.id)
        for _ in 0..<100 {
            let current = try await store.captureJobs(instance: client.storageInstance).first
            if current?.stage == .failed && attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.cancelCaptureWork()
        let packageExists = FileManager.default.fileExists(atPath: await packages.directory(id: job.id, instance: client.storageInstance).appendingPathComponent("manifest.json").path)
        XCTAssertTrue(packageExists, "A failed recapture must not delete the only partial package")
        XCTAssertEqual(attempts, 1)
        let failed = try await store.captureJobs(instance: client.storageInstance).first
        XCTAssertTrue(failed?.message?.contains("微信") == true)
        XCTAssertFalse(failed?.message?.contains("NAS") == true)
    }

    @MainActor
    func testCancelledImportCannotRecreatePackageOrReportSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "capture-test")
        let gate = AcquisitionGate()
        let packages = CapturePackageStore(root: root.appendingPathComponent("packages"))
        let model = AppModel(client: client, store: store, capturePackages: packages, captureImportParser: { _, _, source, _ in
            _ = await gate.wait()
            return CapturedArticle(url: source.canonical, title: "文章", author: "", siteName: "", published: nil, html: "<p>正文</p>", assets: [], missingImages: [])
        })
        let file = root.appendingPathComponent("test.html"); try Data("test".utf8).write(to: file)
        let importing = Task { await model.importWechatFile(file, sourceURL: "https://mp.weixin.qq.com/s/one", title: "", category: nil, tags: []) }
        for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        let job = try XCTUnwrap(jobs.first)
        await model.cancelCapture(job.id)
        await gate.release()
        let result = await importing.value
        XCTAssertFalse(result)
        let saved = try await store.captureJobs(instance: client.storageInstance).first
        XCTAssertEqual(saved?.stage, .cancelled)
        let directory = await packages.directory(id: job.id, instance: client.storageInstance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        model.cancelCaptureWork()
    }

    @MainActor
    func testLateAcquisitionCannotReviveCancelledJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "capture-test")
        let gate = AcquisitionGate()
        let packages = CapturePackageStore(root: root.appendingPathComponent("packages"))
        let model = AppModel(client: client, store: store, capturePackages: packages, captureAcquisition: { _ in await gate.wait() })
        _ = await model.saveURL("https://mp.weixin.qq.com/s/one")
        for _ in 0..<100 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        let waiting = await gate.waiting; XCTAssertTrue(waiting)
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        let job = try XCTUnwrap(jobs.first)
        await model.cancelCapture(job.id)
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        let saved = try await store.captureJobs(instance: client.storageInstance).first
        XCTAssertEqual(saved?.stage, .cancelled)
        XCTAssertNil(saved?.attemptedAt)
        let ordinary = try await store.pending(instance: client.storageInstance)
        XCTAssertTrue(ordinary.isEmpty)
        model.cancelCaptureWork()
    }

    @MainActor
    func testWechatSaveEnqueuesDurablyWithoutWaitingForAcquisitionOrOrdinaryQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(url: root.appendingPathComponent("db.sqlite"))
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:1/"), token: "capture-test")
        let model = AppModel(client: client, store: store, capturePackages: CapturePackageStore(root: root.appendingPathComponent("packages")), captureAcquisition: { _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        })
        let start = Date()
        let saved = await model.saveURL("https://mp.weixin.qq.com/s/one", category: "科技", tags: ["阅读"])
        XCTAssertTrue(saved)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let jobs = try await store.captureJobs(instance: client.storageInstance)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(Set(jobs[0].labels), ["分类/科技", "阅读"])
        let ordinary = try await store.pending(instance: client.storageInstance)
        XCTAssertTrue(ordinary.isEmpty)
        model.cancelCaptureWork()
    }
}
