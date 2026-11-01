import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadeckMac

final class CapturePreviewTests: XCTestCase {
    @MainActor
    func testNativePreviewActuallyDisplaysLocalImageWithJavaScriptDisabled() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = URL(string: "https://readeck-capture.invalid/image")!
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/a")!, title: "", author: "", siteName: "", published: nil, html: "<p>预览正文</p><img src='\(location)'>", assets: [.init(location: location, mimeType: "image/png", data: WechatCaptureTests.png(), width: 32, height: 32)], missingImages: [])
        let packages = CapturePackageStore(root: root)
        _ = try await packages.save(article, id: "a", instance: "one")
        let preview = try CapturePackagePreview.make(package: await packages.load(id: "a", instance: "one"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CapturePackagePreviewView(preview: preview))
        window.orderFront(nil)
        defer { window.close() }
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        var web: WKWebView?
        for _ in 0..<200 {
            web = window.contentView.flatMap(find)
            if let web, web.url == preview.url, !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let actual = try XCTUnwrap(web)
        XCTAssertFalse(actual.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let value = try await actual.evaluateJavaScript("document.querySelector('img')?.naturalWidth") as? Int
        XCTAssertEqual(value, 32)
        let textPresent = try await actual.evaluateJavaScript("document.body.textContent.includes('预览正文')") as? Bool
        XCTAssertEqual(textPresent, true)
    }
    func testPreviewHasOnlyVerifiedLocalResourcesAndNoActiveSourceContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = WechatCaptureTests.png()
        let location = URL(string: "https://readeck-capture.invalid/a/image.png")!
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/one")!, title: "文章", author: "", siteName: "", published: nil,
            html: "<p onclick='evil()'>正文</p><script>evil()</script><img src='\(location)'><img src='https://external.test/tracker'><a href='https://external.test/page'>链接</a>", assets: [.init(location: location, mimeType: "image/png", data: image, width: 32, height: 32)], missingImages: [])
        let packages = CapturePackageStore(root: root)
        _ = try await packages.save(article, id: "a", instance: "one")
        let preview = try CapturePackagePreview.make(package: await packages.load(id: "a", instance: "one"))
        XCTAssertEqual(preview.resources.count, 2)
        for value in ["evil()", "onclick", "external.test", "<script", "readeck-capture.invalid"] { XCTAssertFalse(preview.html.contains(value)) }
        XCTAssertTrue(preview.html.contains("default-src 'none'"))
        XCTAssertNil(preview.resource(for: URL(string: "readeck-preview://other/index.html")!))
        XCTAssertNil(preview.resource(for: preview.url.appendingPathComponent("../../private")))
        let asset = try XCTUnwrap(preview.resources.values.first { $0.mime == "image/png" })
        XCTAssertEqual(asset.data, image)
        do { _ = try await packages.load(id: "a", instance: "two"); XCTFail("cross-account preview") } catch { }
    }

    func testPreviewRejectsImageChangedAfterPackageWasLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = WechatCaptureTests.png()
        let article = CapturedArticle(url: URL(string: "https://mp.weixin.qq.com/s/a")!, title: "", author: "", siteName: "", published: nil, html: "<p>正文</p>", assets: [.init(location: URL(string: "https://readeck-capture.invalid/image")!, mimeType: "image/png", data: bytes, width: 32, height: 32)], missingImages: [])
        let packages = CapturePackageStore(root: root)
        _ = try await packages.save(article, id: "a", instance: "one")
        let package = try await packages.load(id: "a", instance: "one")
        try Data("tampered".utf8).write(to: package.file(for: package.manifest.assets[0]))
        XCTAssertThrowsError(try CapturePackagePreview.make(package: package))
    }
}
