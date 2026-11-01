import XCTest
@testable import ReadeckMac

final class CaptureSiteTests: XCTestCase {
    func testDoubanAndBilibiliRecognizeOnlyArticleURLs() throws {
        let review = try CaptureSourceURL("https://movie.douban.com/review/13542018/?utm_source=test")
        XCTAssertEqual(review.site, .douban); XCTAssertEqual(review.articleID, "13542018")
        XCTAssertEqual(review.canonical.absoluteString, "https://movie.douban.com/review/13542018/")
        let cv = try CaptureSourceURL("https://www.bilibili.com/read/cv25998686/")
        XCTAssertEqual(cv.site, .bilibili); XCTAssertEqual(cv.articleID, "cv25998686")
        let opus = try CaptureSourceURL("https://www.bilibili.com/opus/833952081894178818")
        XCTAssertEqual(opus.articleID, "opus833952081894178818")
        for value in ["https://movie.douban.com.evil.test/review/1/", "https://movie.douban.com/review/not-a-number/", "https://www.bilibili.com/opus/abc", "https://www.bilibili.com/read/cv0abc", "https://www.bilibili.com/video/BV123"] {
            XCTAssertThrowsError(try CaptureSourceURL(value), value)
        }
    }

    func testBilibiliLegacyResponseMustMatchRequestedArticle() throws {
        let good = Data(#"{"code":0,"data":{"id":25998686,"dyn_id_str":"833952081894178818"}}"#.utf8)
        XCTAssertEqual(try BilibiliLegacyResolver.opusURL(data: good, expectedCV: "25998686").absoluteString, "https://www.bilibili.com/opus/833952081894178818")
        XCTAssertThrowsError(try BilibiliLegacyResolver.opusURL(data: good, expectedCV: "26044608"))
        XCTAssertThrowsError(try BilibiliLegacyResolver.opusURL(data: Data(#"{"code":-509,"message":"rate limited"}"#.utf8), expectedCV: "25998686"))
    }

    func testRednoteAliasesPreservePublicOriginAndPrivateAcquisitionParameters() throws {
        for host in ["www.rednote.com", "rednote.com", "m.rednote.com"] {
            let source = try CaptureSourceURL("https://\(host)/discovery/item/6a770458000000003302d546?xsec_token=fixture-private&xsec_source=share")
            XCTAssertEqual(source.site, .xiaohongshu)
            XCTAssertEqual(source.articleID, "6a770458000000003302d546")
            XCTAssertEqual(source.canonical.host, "www.rednote.com")
            XCTAssertEqual(source.canonical.path, "/discovery/item/6a770458000000003302d546")
            XCTAssertNil(URLComponents(url: source.canonical, resolvingAgainstBaseURL: false)?.query)
            XCTAssertTrue(source.original.absoluteString.contains("fixture-private"))
            XCTAssertTrue(source.allowsNavigation(to: URL(string: "https://www.xiaohongshu.com/explore/6a770458000000003302d546")!))
        }
        for host in ["rednote.com.evil.test", "evilrednote.com"] {
            XCTAssertThrowsError(try CaptureSourceURL("https://\(host)/discovery/item/abc"))
        }
    }

    func testRecognizesOnlySupportedArticlePathsAndExactDomains() throws {
        XCTAssertEqual(try CaptureSourceURL("https://www.xiaohongshu.com/explore/abc123?xsec_token=private").site, .xiaohongshu)
        XCTAssertEqual(try CaptureSourceURL("https://baike.baidu.com/item/计算机/140192").site, .baike)
        for bad in ["https://www.xiaohongshu.com.evil.test/explore/abc", "https://baike.baidu.com.evil.test/item/abc", "https://xiaohongshu.com/user/profile/abc", "https://baike.baidu.com/search/word", "http://user:pass@www.xiaohongshu.com/explore/abc", "https://www.xiaohongshu.com:8443/explore/abc"] {
            XCTAssertThrowsError(try CaptureSourceURL(bad), bad)
        }
    }

    func testRequestParametersSurviveLocallyButCanonicalHasNoAccessParameters() throws {
        let source = try CaptureSourceURL("https://www.xiaohongshu.com/discovery/item/abc123?xsec_token=private&xsec_source=share&foo=tracking#section")
        XCTAssertTrue(source.original.absoluteString.contains("xsec_token=private"))
        XCTAssertEqual(source.canonical.absoluteString, "https://www.xiaohongshu.com/explore/abc123")
        XCTAssertEqual(source.articleID, "abc123")
        XCTAssertTrue(source.allowsNavigation(to: URL(string: "https://www.xiaohongshu.com/login")!))
        XCTAssertFalse(source.allowsNavigation(to: URL(string: "https://example.com/")!))
        XCTAssertFalse(source.allowsNavigation(to: URL(string: "https://user:pass@www.xiaohongshu.com/login")!))
    }

    func testShareTextAndShortLinkAreRecognizedWithoutChangingSignedRequest() throws {
        let link = "https://xhslink.com/a/abc123"
        XCTAssertEqual(CaptureInput.url(in: "分享文章 \(link)，复制后打开小红书！"), link)
        XCTAssertEqual(CaptureInput.url(in: "https://example.com/normal?a=1&b=2"), "https://example.com/normal?a=1&b=2")
        XCTAssertNil(CaptureInput.url(in: "这不是链接"))
        let short = try CaptureSourceURL(link)
        XCTAssertEqual(short.site, .xiaohongshu)
        XCTAssertNil(short.articleID)
        XCTAssertTrue(short.allowsNavigation(to: URL(string: "https://www.xiaohongshu.com/explore/abc")!))
        XCTAssertFalse(short.allowsNavigation(to: URL(string: "https://xhslink.com.evil.test/a/abc")!))
        XCTAssertEqual(try CaptureSourceURL("https://xhslink.cn/a/abc123").site, .xiaohongshu)
    }

    func testWechatCanonicalizationAndNavigationStayCompatible() throws {
        let source = try CaptureSourceURL("https://mp.weixin.qq.com/s?__biz=one&mid=two&idx=1&sn=three&key=private")
        XCTAssertEqual(source.site, .wechat)
        XCTAssertFalse(source.canonical.absoluteString.contains("private"))
        XCTAssertTrue(source.canonical.absoluteString.contains("__biz=one"))
        XCTAssertFalse(source.allowsNavigation(to: URL(string: "https://www.xiaohongshu.com/login")!))
    }

    func testOldCaptureJobDecodesAndNewRequestURLRoundTrips() throws {
        var job = CaptureJob(url: "https://www.xiaohongshu.com/explore/abc", title: "标题", labels: [])
        let old = try JSONEncoder().encode(job)
        XCTAssertNil(try JSONDecoder().decode(CaptureJob.self, from: old).requestURL)
        job.requestURL = "https://www.xiaohongshu.com/explore/abc?xsec_token=private"
        let restored = try JSONDecoder().decode(CaptureJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.requestURL, job.requestURL)
        XCTAssertFalse(restored.url.contains("private"))
    }
}
