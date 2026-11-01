import AppKit
import XCTest
import ImageIO
@testable import ReadeckMac

final class WechatCaptureTests: XCTestCase {
    func testWechatURLValidationUsesExactHostAndPublicCanonicalURL() throws {
        XCTAssertFalse(WechatArticleParser.isWechatArticleURL("https://mp.weixin.qq.com.evil.test/s/one"))
        XCTAssertFalse(WechatArticleParser.isWechatArticleURL("https://evilmp.weixin.qq.com/s/one"))
        let url = try CaptureSourceURL("https://mp.weixin.qq.com/s?__biz=one&mid=two&idx=1&sn=three&key=private#wechat_redirect")
        XCTAssertNil(URLComponents(url: url.canonical, resolvingAgainstBaseURL: false)?.fragment)
        XCTAssertFalse(url.canonical.absoluteString.contains("private"))
        XCTAssertTrue(url.canonical.absoluteString.contains("__biz=one"))
    }

    func testArchiveExtractionNormalizesLazyImagesAndDoesNotBlockArticleKeywords() throws {
        let source = "https://mp.weixin.qq.com/s/public#wechat_redirect"
        let image = "https://mmbiz.qpic.cn/picture/640?wx_fmt=png&key=private"
        let html = "<html><head><meta property='og:title' content='验证码与付费设计'><meta name='author' content='作者'></head><body><h1 id='activity-name'>标题</h1><div id='js_content' style='visibility:hidden'><p onclick='alert(1)'>文章讨论验证码和付费，不是验证页面。</p><img data-src='\(image.replacingOccurrences(of: "&", with: "&amp;"))'><img class='placeholder'><script>evil()</script></div></body></html>"
        let archive = try fixture(html: html, images: [(image, Self.png())])
        let captured = try WechatArticleParser.extract(archive: archive, source: CaptureSourceURL(source), packageID: "test")
        XCTAssertEqual(captured.assets.count, 1)
        XCTAssertEqual(captured.author, "作者")
        XCTAssertTrue(captured.html.contains("文章讨论验证码"))
        XCTAssertFalse(captured.html.contains("onclick"))
        XCTAssertFalse(captured.html.contains("script"))
        XCTAssertFalse(captured.html.contains("private"))
        XCTAssertFalse(captured.html.contains("visibility"))
        let asset = try XCTUnwrap(captured.assets.first, "Missing: \(captured.missingImages)")
        XCTAssertTrue(captured.html.contains(asset.location.absoluteString))
        XCTAssertEqual(asset.mimeType, "image/png")
        XCTAssertEqual(asset.data, Self.png())
        XCTAssertTrue(captured.missingImages.isEmpty)
    }

    func testWechatCoverMetadataReusesAnArchivedBodyImageWithoutLeakingOriginalURL() throws {
        let image = "https://mmbiz.qpic.cn/image?key=private"
        let html = "<meta property='og:image' content='\(image)'><div id='js_content'><p>正文</p><img src='\(image)'></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: [(image, Self.png())]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/public"), packageID: "cover")
        XCTAssertTrue(article.html.contains("property=\"og:image\""))
        XCTAssertTrue(article.html.contains(article.assets[0].location.absoluteString))
        XCTAssertFalse(article.html.contains("key=private"))
    }

    func testIndependentWechatCoverIsArchivedWithoutBecomingBodyContent() throws {
        let cover = "https://mmbiz.qpic.cn/cover?key=secret"
        let html = "<meta property='og:image' content='\(cover)'><div id='js_content'><p>正文</p></div>"
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 800, bitsPerPixel: 32)!
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: [(cover, data)]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/public"), packageID: "cover")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.assets[0].coverOnly)
        XCTAssertTrue(article.html.contains("og:image"))
        XCTAssertFalse(article.html.contains("key=secret"))
        XCTAssertTrue(article.missingImages.isEmpty)
    }

    func testMissingArchiveImageIsReportedAndInvalidResourceIsNotAccepted() throws {
        let html = "<div id='js_content'><p>正文</p><img src='https://mmbiz.qpic.cn/missing'><img src='https://mmbiz.qpic.cn/not-image'></div>"
        let captured = try WechatArticleParser.extract(archive: fixture(html: html, images: [("https://mmbiz.qpic.cn/not-image", Data("<html>403</html>".utf8))]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/public"), packageID: "test")
        XCTAssertEqual(captured.missingImages.count, 2)
        XCTAssertTrue(captured.assets.isEmpty)
    }

    func testArchiveWithoutBodyIsInteractionRequiredAndLimitsAreEnforced() throws {
        let source = try CaptureSourceURL("https://mp.weixin.qq.com/s/public")
        XCTAssertThrowsError(try WechatArticleParser.extract(archive: fixture(html: "<body>环境异常，请完成验证</body>", images: []), source: source, packageID: "test"))
        var limits = CaptureLimits(); limits.maximumArchiveBytes = 1
        XCTAssertThrowsError(try WechatArticleParser.extract(archive: fixture(html: "<div id='js_content'>正文</div>", images: []), source: source, packageID: "test", limits: limits))
    }

    func testInlineImagesAndRepeatedLazyImagesDoNotLeakOriginalURLs() throws {
        let image = "https://mmbiz.qpic.cn/image?key=private"
        let html = "<div id='js_content'><a href='https://example.com/page?key=private&amp;x=1'>正文</a><img data-src='\(image)'><img data-src='\(image)'><img src='data:image/png;base64,\(Self.png().base64EncodedString())'></div>"
        let result = try WechatArticleParser.extract(archive: fixture(html: html, images: [(image, Self.png())]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/public"), packageID: "inline")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertTrue(result.missingImages.isEmpty)
        XCTAssertFalse(result.html.contains("private"))
        XCTAssertFalse(result.html.contains("mmbiz.qpic.cn"))
        XCTAssertFalse(result.html.contains("data:image"))
    }

    func testAVIFBodyImageIsConvertedToServerCompatiblePNG() throws {
        let png = Self.png()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.avif" as CFString, 1, nil) else { throw XCTSkip("System cannot encode AVIF fixture") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("System cannot encode AVIF fixture") }
        let url = "https://img.ithome.com/article.avif"
        let html = "<div id='readeck-captured-content'><p>正文</p><img src='\(url)'></div>"
        let article = try CaptureArchiveParser.extract(archive: fixture(html: html, images: [(url, bytes as Data)]), source: CaptureSourceURL("https://www.ithome.com/0/904/887.htm"), packageID: "avif")
        XCTAssertEqual(article.assets.first?.mimeType, "image/png")
        XCTAssertEqual(article.assets.first?.location.pathExtension, "png")
        XCTAssertTrue(article.missingImages.isEmpty)
    }

    func testOversizedIndividualImageFailsExplicitly() throws {
        let image = "https://mmbiz.qpic.cn/image"
        var limits = CaptureLimits(); limits.maximumImageBytes = 1
        XCTAssertThrowsError(try WechatArticleParser.extract(archive: fixture(html: "<div id='js_content'><p>正文</p><img src='\(image)'></div>", images: [(image, Self.png())]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/public"), packageID: "large", limits: limits))
    }

    func testImageShareAndTextShareTemplatesAreNormalizedWithoutArticleBody() async throws {
        let picture = "https://mmbiz.qpic.cn/picture"
        let template = try WechatTemplateAdapter.html(type: 8, html: "图集说明", text: "", pictures: [picture])
        let gallery = try WechatArticleParser.extract(archive: fixture(html: template, images: [(picture, Self.png())]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/gallery"), packageID: "gallery")
        XCTAssertEqual(gallery.assets.count, 1)
        XCTAssertTrue(gallery.html.contains("图集说明"))
        let text = try WechatTemplateAdapter.html(type: 10, html: "", text: "短文第一行\n第二行", pictures: [])
        let article = try WechatArticleParser.extract(archive: fixture(html: text, images: []), source: CaptureSourceURL("https://mp.weixin.qq.com/s/text"), packageID: "text")
        XCTAssertTrue(article.html.contains("短文第一行"))
        XCTAssertTrue(article.assets.isEmpty)
    }

    func testImportedHTMLCannotReadAdjacentLocalImageFiles() throws {
        let html = "<div id='js_content'><p>导入正文</p><img src='file:///private/tmp/secret.png'></div>"
        let result = try WechatImport.archive(data: Data(html.utf8), fileExtension: "html", source: CaptureSourceURL("https://mp.weixin.qq.com/s/import"))
        let article = try WechatArticleParser.extract(archive: result, source: CaptureSourceURL("https://mp.weixin.qq.com/s/import"), packageID: "import")
        XCTAssertEqual(article.missingImages.count, 1)
        XCTAssertTrue(article.assets.isEmpty)
        XCTAssertFalse(article.html.contains("file:"))
    }

    func testBodyBackgroundImageIsArchivedInsteadOfSilentlyDropped() throws {
        let picture = "https://mmbiz.qpic.cn/background"
        let article = try WechatArticleParser.extract(archive: fixture(html: "<div id='js_content'><p>正文</p><section style='background-image:url(\(picture))'>图片说明</section></div>", images: [(picture, Self.png())]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/background"), packageID: "background")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.html.contains("readeck-capture.invalid"))
    }

    func testSanitizerRemovesCitationCredentialsAndSignedLinkQueries() throws {
        let html = "<div id='js_content'><blockquote cite='https://x.test/?access_token=secret-cite'>正文</blockquote><q cite='https://x.test/?key=secret-q'>引用</q><a href='https://x.test/page?id=public&amp;X-Amz-Credential=secret-aws&amp;X-Amz-Signature=secret-sign&amp;X-Goog-Signature=secret-google'>链接</a></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: []), source: CaptureSourceURL("https://mp.weixin.qq.com/s/public"), packageID: "signed")
        XCTAssertFalse(article.html.contains("secret"))
        XCTAssertFalse(article.html.contains("cite="))
        XCTAssertTrue(article.html.contains("id=public"))
    }

    func testVerificationRejectsPlaceholderImagesButAcceptsProportionalResizing() {
        let expected = [CaptureManifest.Asset(location: URL(string: "https://readeck-capture.invalid/p")!, mimeType: "image/png", checksum: "unused", byteCount: 1, width: 400, height: 200)]
        XCTAssertFalse(CaptureVerification.dimensionsMatch(expected: expected, actual: [(32, 32)]))
        XCTAssertFalse(CaptureVerification.dimensionsMatch(expected: expected, actual: [(8, 4)]))
        XCTAssertTrue(CaptureVerification.dimensionsMatch(expected: expected, actual: [(200, 100)]))
    }

    func testResponsiveImageUsesLoadedResourceAndUnresolvedVariantIsMissing() throws {
        let image = "https://mmbiz.qpic.cn/responsive"
        let html = "<div id='js_content'><p>正文</p><picture><source srcset='\(image) 2x'><img srcset='\(image) 2x'></picture></div>"
        let source = try CaptureSourceURL("https://mp.weixin.qq.com/s/responsive")
        let loaded = try WechatArticleParser.extract(archive: fixture(html: html, images: [(image, Self.png())]), source: source, packageID: "responsive")
        XCTAssertEqual(loaded.assets.count, 1)
        XCTAssertTrue(loaded.missingImages.isEmpty)
        let missing = try WechatArticleParser.extract(archive: fixture(html: html, images: []), source: source, packageID: "responsive")
        XCTAssertEqual(missing.missingImages.count, 1)
        let selected = "<div id='js_content'><p>正文</p><img src='https://mmbiz.qpic.cn/old' data-readeck-src='\(image)'></div>"
        let actual = try WechatArticleParser.extract(archive: fixture(html: selected, images: [(image, Self.png())]), source: source, packageID: "selected")
        XCTAssertEqual(actual.assets.count, 1)
    }

    func testPixelAndRepeatedReferenceLimitsFailExplicitly() throws {
        let picture = "https://mmbiz.qpic.cn/picture"
        let source = try CaptureSourceURL("https://mp.weixin.qq.com/s/limits")
        var pixels = CaptureLimits(); pixels.maximumImagePixels = 10
        XCTAssertThrowsError(try WechatArticleParser.extract(archive: fixture(html: "<div id='js_content'><img src='\(picture)'></div>", images: [(picture, Self.png())]), source: source, packageID: "pixels", limits: pixels))
        var references = CaptureLimits(); references.maximumImages = 1
        XCTAssertThrowsError(try WechatArticleParser.extract(archive: fixture(html: "<div id='js_content'><img src='\(picture)'><img src='\(picture)'></div>", images: [(picture, Self.png())]), source: source, packageID: "references", limits: references))
    }

    func testTransparentWebPBecomesPNGBeforeNASUpload() throws {
        // Generated lossless 32x32 RGBA WebP; red square on a transparent canvas.
        let bytes = try XCTUnwrap(Data(base64Encoded: "UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wHgM/FPMf8BDTEPqXdpsCEf2fAHq95QA="))
        let picture = "https://mmbiz.qpic.cn/transparent"
        let article = try WechatArticleParser.extract(archive: fixture(html: "<div id='js_content'><p>正文</p><img src='\(picture)'></div>", images: [(picture, bytes)]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/alpha"), packageID: "alpha")
        let asset = try XCTUnwrap(article.assets.first)
        XCTAssertEqual(asset.mimeType, "image/png")
        XCTAssertTrue(asset.location.path.hasSuffix(".png"))
        XCTAssertTrue(asset.data.starts(with: [137, 80, 78, 71]))
        XCTAssertTrue(CaptureImageIdentity.resembles(CaptureImageIdentity.read(bytes)?.fingerprint, CaptureImageIdentity.read(asset.data)?.fingerprint))
    }

    func testSerializedProfileCardAvatarDoesNotBlockBodyImages() throws {
        let picture = "https://mmbiz.qpic.cn/article/640"
        let html = "<div id='js_content'><mp-common-profile><template shadowrootmode='open'><div class='wx_profile_hd'><img class='wx_profile_avatar' src='http://mmbiz.qpic.cn/profile/300'><span>测试公众号</span></div></template></mp-common-profile><p>文章正文</p><img src='\(picture)'></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: [(picture, Self.png())]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/profile"), packageID: "profile")
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.html.contains("文章正文"))
        XCTAssertTrue(article.html.contains("测试公众号"))
        XCTAssertFalse(article.html.contains("profile/300"))
    }

    func testProfileAvatarExclusionDoesNotHideMissingArticleImage() throws {
        let html = "<div id='js_content'><mp-common-profile><template shadowrootmode='open'><img class='wx_profile_avatar' src='http://mmbiz.qpic.cn/profile/300'></template></mp-common-profile><p>文章正文</p><img class='wx_profile_avatar' src='https://mmbiz.qpic.cn/actual-article-image'></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: []), source: CaptureSourceURL("https://mp.weixin.qq.com/s/profile"), packageID: "profile")
        XCTAssertEqual(article.missingImages.count, 1)
        XCTAssertTrue(article.assets.isEmpty)
    }

    func testMusicWidgetCoverIsNotRequiredButSongInformationIsRetained() throws {
        let picture = "https://mmbiz.qpic.cn/body/640"
        let html = "<div id='js_content'><p>正文配图</p><mp-common-clmusic music_name='小宇' singer='歌手'><template shadowrootmode='open'><div class='audio_card'><span class='audio_card_thumb' style='background-image:url(http://wx.y.gtimg.cn/album.jpg)'></span><button>播放控件</button></div></template></mp-common-clmusic><img src='\(picture)'></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: [(picture, Self.png())]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/music?key=private-session#wechat_redirect"), packageID: "music")
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.html.contains("小宇"))
        XCTAssertTrue(article.html.contains("歌手"))
        XCTAssertFalse(article.html.contains("wx.y.gtimg.cn"))
        XCTAssertFalse(article.html.contains("播放控件"))
        XCTAssertTrue(article.html.contains("href=\"https://mp.weixin.qq.com/s/music\""))
        XCTAssertFalse(article.html.contains("private-session"))
        XCTAssertFalse(article.html.contains("#wechat_redirect"))
    }

    func testWidgetNormalizationDoesNotSkipOrdinaryBackgroundOrUnknownWidgetImages() throws {
        let html = "<div id='js_content'><p>正文</p><mp-common-clmusic music_name='歌曲' singer='歌手'><template shadowrootmode='open'><span class='audio_card_thumb' style='background-image:url(http://wx.y.gtimg.cn/album.jpg)'></span></template></mp-common-clmusic><section class='audio_card_thumb' style='background-image:url(https://mmbiz.qpic.cn/body-background)'></section><mp-unknown><template shadowrootmode='open'><img src='https://mmbiz.qpic.cn/unknown-body'></template></mp-unknown></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: []), source: CaptureSourceURL("https://mp.weixin.qq.com/s/music"), packageID: "music")
        XCTAssertEqual(article.missingImages.count, 2)
        XCTAssertTrue(article.assets.isEmpty)
    }

    func testMiniProgramCardRetainsTitleWithoutRequiringItsUIAvatar() throws {
        let html = "<div id='js_content'><p>正文</p><mp-common-miniprogram data-miniprogram-type='card' data-miniprogram-title='资料下载' data-miniprogram-nickname='测试小程序'><template shadowrootmode='open'><img class='weapp_card_avatar' src='https://res.wx.qq.com/card-icon.png'><button>打开小程序</button></template></mp-common-miniprogram></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: []), source: CaptureSourceURL("https://mp.weixin.qq.com/s/mini"), packageID: "mini")
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertTrue(article.assets.isEmpty)
        XCTAssertTrue(article.html.contains("资料下载")); XCTAssertTrue(article.html.contains("测试小程序"))
    }

    func testNonCardMiniProgramImageRemainsRequiredArticleContent() throws {
        let image = "https://mmbiz.qpic.cn/linked-illustration"
        let html = "<div id='js_content'><p>正文插图</p><mp-common-miniprogram data-miniprogram-type='image'><img src='\(image)'></mp-common-miniprogram></div>"
        let source = try CaptureSourceURL("https://mp.weixin.qq.com/s/mini-image")
        let available = try WechatArticleParser.extract(archive: fixture(html: html, images: [(image, Self.png())]), source: source, packageID: "mini-image")
        XCTAssertEqual(available.assets.count, 1)
        let missing = try WechatArticleParser.extract(archive: fixture(html: html, images: []), source: source, packageID: "mini-image")
        XCTAssertEqual(missing.missingImages.count, 1)
    }

    func testMissingImageReasonIdentifiesStageAndHostWithoutPrivateURLParameters() throws {
        let html = "<div id='js_content'><p>正文</p><img src='https://mmbiz.qpic.cn/private-path?key=secret&amp;pass_ticket=secret'><img src='https://mmbiz.qpic.cn/broken'></div>"
        let article = try WechatArticleParser.extract(archive: fixture(html: html, images: [("https://mmbiz.qpic.cn/broken", Data("not an image".utf8))]), source: CaptureSourceURL("https://mp.weixin.qq.com/s/missing"), packageID: "missing")
        XCTAssertEqual(article.missingImages.count, 2)
        XCTAssertTrue(article.missingImages[0].contains("mmbiz.qpic.cn"))
        XCTAssertTrue(article.missingImages[0].contains("归档"))
        XCTAssertTrue(article.missingImages[1].contains("解码"))
        XCTAssertFalse(article.missingImages.joined().contains("secret"))
        XCTAssertFalse(article.missingImages.joined().contains("private-path"))
    }

    private func fixture(html: String, images: [(String, Data)]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "WebMainResource": ["WebResourceData": Data(html.utf8), "WebResourceMIMEType": "text/html", "WebResourceURL": "https://mp.weixin.qq.com/s/public"],
            "WebSubresources": images.map { ["WebResourceURL": $0.0, "WebResourceMIMEType": "image/png", "WebResourceData": $0.1] }
        ], format: .binary, options: 0)
    }

    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        rep.bitmapData?.initialize(repeating: 80, count: 128 * 32)
        return rep.representation(using: .png, properties: [:])!
    }
}
