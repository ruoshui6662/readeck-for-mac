import AppKit
import WebKit
import SwiftSoup
import XCTest
@testable import ReadeckMac

@MainActor
final class SiteCaptureAdapterTests: XCTestCase {
    func testDoubanSnapshotKeepsBodyAndRejectsDifferentReview() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let html = "<h1>影评标题</h1><div id='review-123-content'><div class='review-content' data-author='作者'><p>正文开始</p><img src='\(image)'><p>正文结束</p></div></div><div>推荐评论</div>"
        let (web, observer) = try await load(html, url: "https://movie.douban.com/review/123/")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://movie.douban.com/review/123/"))
        XCTAssertTrue(snapshot.html.contains("正文开始")); XCTAssertTrue(snapshot.html.contains("正文结束")); XCTAssertFalse(snapshot.html.contains("推荐评论"))
        XCTAssertEqual(try SwiftSoup.parse(snapshot.html).select("img").count, 1)
        do { _ = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://movie.douban.com/review/456/")); XCTFail("must not capture a different review") } catch {}
    }

    func testBilibiliSnapshotRejectsComponentsAndVerifiesLegacyIdentity() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let html = "<div class='opus-module-title'>文章标题</div><div class='opus-module-content'><p>正文开始</p><div class='opus-para-link-card'><img src='https://evil.test/icon'>视频组件</div><div class='opus-para-pic'><img src='\(image)'></div><p>正文结束</p></div><div class='opus-module-copyright'>cv123</div>"
        let (web, observer) = try await load(html, url: "https://www.bilibili.com/opus/456")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://www.bilibili.com/read/cv123/"))
        let doc = try SwiftSoup.parse(snapshot.html)
        XCTAssertEqual(try doc.select("img").count, 1)
        XCTAssertTrue(snapshot.html.contains("正文开始")); XCTAssertTrue(snapshot.html.contains("正文结束"))
        XCTAssertFalse(snapshot.html.contains("evil.test"))
        do { _ = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://www.bilibili.com/read/cv999/")); XCTFail("must verify legacy ID") } catch {}
    }

    func testITHomeCapturePreservesArticleAndOriginalLazyImage() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let html = "<h1>新闻标题</h1><div id='paragraph'><p>正文第一段</p><p><img src='https://img.ithome.com/images/v2/t.png' data-original='\(image)'></p><p>正文最后一段</p></div><div>推荐文章</div>"
        let (web, observer) = try await load(html, url: "https://www.ithome.com/0/904/887.htm")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let source = try CaptureSourceURL("https://www.ithome.com/0/904/887.htm")
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: source)
        let doc = try SwiftSoup.parse(snapshot.html)
        XCTAssertEqual(try doc.select("img").first()?.attr("src"), image)
        XCTAssertTrue(snapshot.html.contains("正文第一段")); XCTAssertTrue(snapshot.html.contains("正文最后一段"))
        XCTAssertFalse(snapshot.html.contains("推荐文章"))
        let archive = try await SiteCaptureAdapter.capture(web: web, source: source)
        let article = try CaptureArticleParser.extract(archive: archive, source: source, packageID: "ithome")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
    }

    func testBaikeUsesLazyImageSourcesRatherThanPlaceholders() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let placeholder = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        let html = "<h1>词条</h1><div class='main-content'><p>正文<img src='\(placeholder)' data-lazy-src='\(image)'><img src='\(placeholder)' data-lazy='\(image)'><img src='\(image)' data-lazy='true'></p></div>"
        let (web, observer) = try await load(html, url: "https://baike.baidu.com/item/测试/1")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let source = try CaptureSourceURL("https://baike.baidu.com/item/测试/1")
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: source)
        let images = try SwiftSoup.parse(snapshot.html).select("img")
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(try images[0].attr("src"), image)
        XCTAssertEqual(try images[1].attr("src"), image)
        XCTAssertEqual(try images[2].attr("src"), image)
        let article = try CaptureArticleParser.extract(archive: fixture(snapshot.html), source: source, packageID: "lazy")
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertEqual(article.assets.count, 1)
    }
    func testXiaohongshuPublicCDNUsesHTTPSWithoutChangingOpaqueParameters() async throws {
        let body = "<script>window.__INITIAL_STATE__={note:{noteDetailMap:{abc123:{note:{noteId:'abc123',type:'normal',title:'图文',desc:'说明',imageList:[{urlDefault:'http://sns-web-i10.rednotecdn.com/photo!nd_dft_webp?sign=keep'}]}}}}}</script>"
        let (web, observer) = try await load(body, url: "https://www.rednote.com/discovery/item/abc123")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://www.rednote.com/discovery/item/abc123"))
        XCTAssertEqual(try SwiftSoup.parse(snapshot.html).select("img").first()?.attr("src"), "https://sns-web-i10.rednotecdn.com/photo!nd_dft_webp?sign=keep")
    }

    func testModernBaikeComponentsRecoverUnrenderedImagesAndExcludePeripheralContent() async throws {
        let html = #"""
        <h1 class="J-lemma-title">力箭二号</h1><div class="mainContent_UO0lo">
          <div class="lemma-subscribe"><img src="https://baikebcs.bdimg.com/icon.png">订阅</div>
          <div class="lemmaSummary_NiNn9 J-summary"><p>中型液体运载火箭</p></div>
          <div class="hotspotContentWrapper_abc">热点新闻</div>
          <div class="J-basic-info"><dl><div><dt>研制单位</dt><dd>中科宇航</dd></div></dl></div>
          <div class="catalogWrapper_abc">原页目录</div>
          <div class="J-lemma-content"><div class="paraTitle_abc" data-level="1"><h2>发展历程</h2><span>播报</span><div>编辑<svg><path/></svg></div></div><div class="para_abc" data-tag="paragraph">正文
            <div class="J-lemma-content-single-image" data-single-image='{"url":"https://bkimg.cdn.bcebos.com/pic/public-hash?x-bce-process=image/resize,m_lfit,w_220,h_220,limit_1","title":"火箭试验"}'></div>
          </div></div><div class="albumList_abc">更多图册</div><div id="J-lemma-reference"><div class="referenceTitle_abc">参考资料</div><ul><li><a href="/reference/1">来源报道</a></li></ul></div>
        </div>
        """#
        let (web, observer) = try await load(html, url: "https://baike.baidu.com/item/力箭二号/63795768")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://baike.baidu.com/item/力箭二号/63795768"))
        let doc = try SwiftSoup.parse(snapshot.html)
        XCTAssertEqual(try doc.select("img").count, 1)
        XCTAssertEqual(try doc.select("img").first()?.attr("src"), "https://bkimg.cdn.bcebos.com/pic/public-hash")
        XCTAssertEqual(try doc.select("figcaption").text(), "火箭试验")
        XCTAssertEqual(try doc.select("table th").text(), "研制单位")
        XCTAssertTrue(try doc.select("table td").text().contains("中科宇航"))
        for unwanted in ["订阅", "热点新闻", "原页目录", "更多图册", "播报", "编辑"] { XCTAssertFalse(try doc.body()!.text().contains(unwanted), unwanted) }
        XCTAssertEqual(try doc.select("svg").count, 0)
        XCTAssertTrue(try doc.select("h2").text().contains("发展历程"))
        XCTAssertTrue(snapshot.html.contains("来源报道"))
    }

    func testNewSiteOnePixelPlaceholderBlocksCompleteCapture() throws {
        let image = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        let article = try CaptureArticleParser.extract(archive: fixture("<title>词条</title><div id='readeck-captured-content'><p>词条正文</p><img src='\(image)'></div>"), source: CaptureSourceURL("https://baike.baidu.com/item/测试/1"), packageID: "placeholder")
        XCTAssertEqual(article.missingImages.count, 1)
        XCTAssertEqual(article.resourceReport?.issues.first?.position, 1)
    }

    func testDOMFallbackRequiresBothNoteIdentityAndReliableImageCount() async throws {
        for attributes in ["", "data-note-id='abc123'"] {
            let (web, observer) = try await load("<div id='noteContainer' \(attributes)><div id='detail-title'>图集</div><div id='detail-desc'>说明</div><div class='swiper-slide' data-swiper-slide-index='0'><img src='https://sns-webpic-qc.xhscdn.com/one'></div><div class='swiper-slide' data-swiper-slide-index='1'><img src='https://sns-webpic-qc.xhscdn.com/two'></div></div>", url: "https://www.xiaohongshu.com/explore/abc123")
            defer { web.stopLoading(); withExtendedLifetime(observer) {} }
            do { _ = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123")); XCTFail("Identity and total count are required") } catch { }
        }
    }

    func testNativeBrowserCapturePackagesEveryImageWithoutExternalHotlinks() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let state = "{note:{noteDetailMap:{abc123:{note:{noteId:'abc123',type:'normal',title:'浏览器图集',desc:'正文',imageList:[{urlDefault:'\(image)'},{urlDefault:'\(image)'}]}}}}}"
        let (web, observer) = try await load("<script>window.__INITIAL_STATE__=\(state)</script>", url: "https://www.xiaohongshu.com/explore/abc123")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let source = try CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123?xsec_token=private")
        let archive = try await SiteCaptureAdapter.capture(web: web, source: source)
        let article = try CaptureArticleParser.extract(archive: archive, source: source, packageID: "native")
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertEqual(try SwiftSoup.parse(article.html).select("img").count, 2)
        XCTAssertFalse(article.html.contains("data:image"))
        XCTAssertEqual(article.url.absoluteString, "https://www.xiaohongshu.com/explore/abc123")
    }

    func testStructuredNoteMatchesCurrentIDAndKeepsAllImagesAndRepeatedPositions() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let state: [String: Any] = ["note": ["noteDetailMap": [
            "other": ["note": ["noteId": "other", "title": "错误文章", "desc": "不能采集"]],
            "abc123": ["note": ["noteId": "abc123", "type": "normal", "title": "图集标题", "desc": "第一行\n第二行", "user": ["nickname": "作者"], "imageList": [["urlDefault": image], ["urlDefault": image]]]]
        ]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: state), encoding: .utf8)!
        let (web, observer) = try await load("<script>window.__INITIAL_STATE__=\(json)</script>", url: "https://www.xiaohongshu.com/explore/abc123")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123?xsec_token=private"))
        let archive = try fixture(snapshot.html)
        let article = try CaptureArticleParser.extract(archive: archive, source: CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123"), packageID: "gallery")
        XCTAssertEqual(article.title, "图集标题")
        XCTAssertEqual(article.author, "作者")
        XCTAssertFalse(article.html.contains("错误文章"))
        XCTAssertFalse(article.html.contains("private"))
        XCTAssertEqual(try SwiftSoup.parse(article.html).select("img").count, 2)
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
    }

    func testNeverFallsBackToAnotherCachedNoteOrVideoPoster() async throws {
        for value in ["{note:{noteDetailMap:{other:{note:{title:'错误文章',desc:'正文'}}}}}", "{note:{noteDetailMap:{abc123:{note:{noteId:'abc123',type:'video',title:'视频',desc:'说明'}}}}}"] {
            let (web, observer) = try await load("<script>window.__INITIAL_STATE__=\(value)</script>", url: "https://www.xiaohongshu.com/explore/abc123")
            defer { web.stopLoading(); withExtendedLifetime(observer) {} }
            do {
                _ = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123"))
                XCTFail("wrong note or video must not be saved as a complete static article")
            } catch { }
        }
    }

    func testVisibleDOMFallbackFiltersAvatarCommentsAndCarouselClones() async throws {
        let html = "<div id='noteContainer' data-note-id='abc123'><span class='fraction'>1/1</span><div class='author'><img src='https://invalid.test/avatar'><span class='username'>作者</span></div><div id='detail-title'>可见图集</div><div id='detail-desc'>图文说明</div><div class='swiper-slide' data-swiper-slide-index='0'><img src='https://sns-webpic-qc.xhscdn.com/one?sign=keep'></div><div class='swiper-slide swiper-slide-duplicate' data-swiper-slide-index='0'><img src='https://sns-webpic-qc.xhscdn.com/one?sign=keep'></div><div class='comments-container'><img src='https://invalid.test/comment'>评论</div></div>"
        let (web, observer) = try await load(html, url: "https://www.xiaohongshu.com/explore/abc123")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123"))
        let doc = try SwiftSoup.parse(snapshot.html)
        XCTAssertEqual(try doc.select("img").count, 1)
        XCTAssertTrue(try doc.select("img").first()!.attr("src").contains("sign=keep"))
        XCTAssertFalse(snapshot.html.contains("avatar")); XCTAssertFalse(snapshot.html.contains("comment"))
    }

    func testBaikeNormalizesHeadingsTablesAndLazyImagesWithoutSidebarOrSourceStyles() async throws {
        let html = "<h1>计算机</h1><div class='main-content'><div class='lemma-summary'><p style='color:red'>词条摘要</p></div><dl class='basicInfo-block'><dt>中文名</dt><dd>计算机</dd></dl><div class='para-title level-2'><h2 class='title-text'>发展历史</h2></div><div class='para' style='font-size:50px'>词条正文<img data-src='https://bkimg.cdn.bcebos.com/pic/one'></div><table><tr><th>年份</th><td>2026</td></tr></table><aside>猜你喜欢</aside><div class='lemmaWgt-promotion'>广告</div><script>evil()</script></div>"
        let (web, observer) = try await load(html, url: "https://baike.baidu.com/item/计算机/140192")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let snapshot = try await SiteCaptureAdapter.snapshot(web: web, source: CaptureSourceURL("https://baike.baidu.com/item/计算机/140192"))
        let doc = try SwiftSoup.parse(snapshot.html)
        XCTAssertEqual(snapshot.title, "计算机")
        XCTAssertTrue(try doc.select("h2").text().contains("发展历史"))
        XCTAssertFalse(snapshot.html.contains("猜你喜欢")); XCTAssertFalse(snapshot.html.contains("广告"))
        XCTAssertFalse(snapshot.html.contains("style=")); XCTAssertFalse(snapshot.html.contains("script"))
        XCTAssertEqual(try doc.select("table").count, 1)
        XCTAssertEqual(try doc.select("img").first()?.attr("src"), "https://bkimg.cdn.bcebos.com/pic/one")
        let article = try CaptureArticleParser.extract(archive: fixture(snapshot.html), source: CaptureSourceURL("https://baike.baidu.com/item/计算机/140192"), packageID: "baike")
        XCTAssertEqual(article.siteName, "百度百科")
        XCTAssertEqual(article.missingImages.count, 1)
    }

    func testFrozenSourceMustStayOnSameSiteAndArticle() throws {
        let source = try CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123")
        XCTAssertThrowsError(try CaptureArticleParser.extract(archive: fixture("<div id='readeck-captured-content'>正文</div>", url: "https://evil.test/explore/abc123"), source: source, packageID: "wrong"))
        XCTAssertThrowsError(try CaptureArticleParser.extract(archive: fixture("<div id='readeck-captured-content'>正文</div>", url: "https://www.xiaohongshu.com/explore/other"), source: source, packageID: "wrong"))
    }

    private func fixture(_ html: String, url: String? = nil) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": ["WebResourceData": Data(html.utf8), "WebResourceURL": url ?? "", "WebResourceMIMEType": "text/html"], "WebSubresources": []], format: .binary, options: 0)
    }

    private func load(_ html: String, url: String) async throws -> (WKWebView, SiteLoadObserver) {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let loaded = expectation(description: "site fixture")
        let observer = SiteLoadObserver { loaded.fulfill() }; web.navigationDelegate = observer
        web.loadHTMLString(html, baseURL: URL(string: url))
        await fulfillment(of: [loaded], timeout: 10)
        return (web, observer)
    }
}

@MainActor
private final class SiteLoadObserver: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
