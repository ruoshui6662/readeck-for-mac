import XCTest
@testable import ReadeckMac

final class CaptureStorageTests: XCTestCase {
    func testNewSiteImageOrderSurvivesPackageReloadIncludingRepeatedReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = CapturePackageStore(root: root)
        let url = URL(string: "https://readeck-capture.invalid/image.png")!
        let article = CapturedArticle(url: URL(string: "https://baike.baidu.com/item/测试/1")!, title: "词条", author: "", siteName: "百度百科", published: nil,
            html: "<p>正文</p><img src='\(url)'><img src='\(url)'>", assets: [.init(location: url, mimeType: "image/png", data: WechatCaptureTests.png(), width: 32, height: 32)], missingImages: [])
        let generation = try await packages.saveGeneration(article, id: "baike", instance: "fixture")
        let loaded = try await packages.load(id: "baike", instance: "fixture", generation: generation)
        XCTAssertEqual(loaded.manifest.imageOrder, [url, url])
    }

    func testLowSpaceRejectsNewGenerationWithoutChangingPreviousData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldStore = CapturePackageStore(root: root)
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/a")!, title: "", author: "", siteName: "", published: nil, html: "<p>正文</p>", assets: [], missingImages: ["missing"])
        _ = try await oldStore.save(article, id: "a", instance: "one")
        let lowSpace = CapturePackageStore(root: root, availableBytes: { _ in 0 })
        do { _ = try await lowSpace.saveGeneration(article, id: "a", instance: "one"); XCTFail("low space") } catch { }
        let old = try await oldStore.load(id: "a", instance: "one")
        XCTAssertEqual(old.html, article.html)
    }

    func testCleanupProtectsEveryPendingJobAndRecentUnpublishedGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = CapturePackageStore(root: root)
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/a")!, title: "", author: "", siteName: "", published: nil, html: "<p>正文</p>", assets: [], missingImages: [])
        let pending = try await packages.saveGeneration(article, id: "pending", instance: "one")
        let recent = try await packages.saveGeneration(article, id: "unpublished", instance: "one")
        _ = try await packages.cleanOrphanedFiles(instance: "one", protectedIDs: ["pending"], olderThan: Date().addingTimeInterval(-86400))
        _ = try await packages.load(id: "pending", instance: "one", generation: pending)
        _ = try await packages.load(id: "unpublished", instance: "one", generation: recent)
        let dir = await packages.directory(id: "unpublished", instance: "one")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: dir.path)
        let removed = try await packages.cleanOrphanedFiles(instance: "one", protectedIDs: ["pending"], olderThan: Date().addingTimeInterval(-86400))
        XCTAssertGreaterThan(removed, 0)
        _ = try await packages.load(id: "pending", instance: "one", generation: pending)
        do { _ = try await packages.load(id: "unpublished", instance: "one", generation: recent); XCTFail("old orphan") } catch { }
    }
}
