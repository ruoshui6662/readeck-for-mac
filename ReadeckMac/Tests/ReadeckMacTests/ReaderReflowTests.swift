import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderReflowTests: XCTestCase {
    private func reader(_ html: String) async throws -> (WKWebView, ReaderWebView.Coordinator) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(WKUserScript(source: AnnotationScript.bootstrap,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: config)
        let parent = ReaderWebView(html: html, baseURL: URL(string: "about:blank")!, style: .standard,
                                   initialProgress: 0, onProgress: { _ in })
        let coordinator = parent.makeCoordinator()
        web.navigationDelegate = coordinator
        coordinator.load(html: html, baseURL: parent.baseURL, style: .standard, in: web)
        for _ in 0..<300 {
            if !web.isLoading, web.url != nil,
               (try? await evaluate("return document.readyState==='complete'", in: web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await coordinator.styleTask?.value
        return (web, coordinator)
    }

    private func evaluate(_ script: String, in web: WKWebView) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    func testArchivedPublicArticlesRenderWithinReaderAtDifferentWidths() async throws {
        guard let directory = ProcessInfo.processInfo.environment["READECK_READER_ARTICLE_FIXTURES"] else {
            throw XCTSkip("Read-only archived public article fixtures are opt-in")
        }
        for name in ["sspai", "ithome", "wiki", "baike"] {
            let html = try String(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name + ".html"), encoding: .utf8)
            let (web, owner) = try await reader(html)
            for width in [700.0, 420.0] {
                web.setFrameSize(NSSize(width: width, height: 600))
                try await Task.sleep(for: .milliseconds(100))
                let value = try await evaluate("""
                    const root=document.getElementById('reader-content');
                    return { text:root.innerText.length, images:root.querySelectorAll('img').length,
                        viewport:document.documentElement.clientWidth, width:document.documentElement.scrollWidth };
                    """, in: web) as? [String: Any]
                XCTAssertGreaterThan((value?["text"] as? NSNumber)?.intValue ?? 0, 100, name)
                XCTAssertGreaterThan((value?["images"] as? NSNumber)?.intValue ?? 0, 0, name)
                XCTAssertLessThanOrEqual((value?["width"] as? NSNumber)?.doubleValue ?? .infinity,
                                         ((value?["viewport"] as? NSNumber)?.doubleValue ?? 0) + 1, name)
            }
            withExtendedLifetime(owner) {}
        }
    }

    func testITHomeFixedCaptureRendersCompleteImageInReader() async throws {
        guard let path = ProcessInfo.processInfo.environment["READECK_ITHOME_READER_FIXTURE"] else { throw XCTSkip("Opt-in IT Home reader fixture") }
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let (web, owner) = try await reader(html)
        defer { withExtendedLifetime(owner) {} }
        for width in [700.0, 420.0] {
            web.setFrameSize(NSSize(width: width, height: 600))
            try await Task.sleep(for: .milliseconds(200))
            let result = try await evaluate("""
                const root=document.getElementById('reader-content'), images=[...root.querySelectorAll('img')];
                return { text:root.innerText, images:images.length, loaded:images.filter(i=>i.complete && i.naturalWidth>0).length,
                viewport:document.documentElement.clientWidth, width:document.documentElement.scrollWidth };
                """, in: web) as? [String: Any]
            XCTAssertTrue((result?["text"] as? String ?? "").contains("人工智能"))
            XCTAssertEqual((result?["images"] as? NSNumber)?.intValue, 1)
            XCTAssertEqual((result?["loaded"] as? NSNumber)?.intValue, 1)
            XCTAssertLessThanOrEqual((result?["width"] as? NSNumber)?.doubleValue ?? .infinity, ((result?["viewport"] as? NSNumber)?.doubleValue ?? 0) + 1)
        }
    }

    func testExpandedPublicArticlesInNativeReader() async throws {
        guard let directory = ProcessInfo.processInfo.environment["READECK_EXPANDED_READER_FIXTURES"] else { throw XCTSkip("Opt-in expanded public article fixtures") }
        let samples: [(String, Int, Bool)] = [("新华网多图", 9, false), ("澎湃多图", 6, false), ("掘金代码图文", 7, true), ("博客园代码", 0, true), ("少数派图文", 1, false), ("IT之家图文旧链路", 1, false)]
        for (name, expectedImages, hasCode) in samples {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + "-reader.html")
            let html = try String(contentsOf: url, encoding: .utf8)
            let (web, owner) = try await reader(html)
            for width in [700.0, 420.0] {
                web.setFrameSize(NSSize(width: width, height: 600))
                try await Task.sleep(for: .milliseconds(200))
                let result = try await evaluate("""
                    const root=document.getElementById('reader-content'), images=[...root.querySelectorAll('img')];
                    for (const image of images) {
                      image.scrollIntoView({block:'center'});
                      for (let attempt=0; attempt<20 && !(image.complete && image.naturalWidth>0); attempt++)
                        await new Promise(resolve=>setTimeout(resolve,50));
                    }
                    return { text:root.innerText.length, images:images.length, loaded:images.filter(i=>i.complete && i.naturalWidth>0).length,
                      code:root.querySelectorAll('pre,code').length, viewport:document.documentElement.clientWidth, width:document.documentElement.scrollWidth };
                    """, in: web) as? [String: Any]
                XCTAssertGreaterThan((result?["text"] as? NSNumber)?.intValue ?? 0, 100, name)
                XCTAssertEqual((result?["images"] as? NSNumber)?.intValue, expectedImages, name)
                XCTAssertEqual((result?["loaded"] as? NSNumber)?.intValue, expectedImages, name)
                if hasCode { XCTAssertGreaterThan((result?["code"] as? NSNumber)?.intValue ?? 0, 0, name) }
                XCTAssertLessThanOrEqual((result?["width"] as? NSNumber)?.doubleValue ?? .infinity, ((result?["viewport"] as? NSNumber)?.doubleValue ?? 0) + 1, name)
            }
            withExtendedLifetime(owner) {}
        }
    }

    func testCapturedDoubanAndBilibiliArticlesInReader() async throws {
        guard let directory = ProcessInfo.processInfo.environment["READECK_NEWSITE_TEST_DIR"] else { throw XCTSkip("Opt-in captured article fixtures") }
        for (name, expectedImages, anchor) in [("douban-13542018-reader.html", 45, "当人们迷恋科幻片时"), ("bilibili-opus833952081894178818-reader.html", 11, "参考资料")] {
            let html = try String(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name), encoding: .utf8)
            let (web, owner) = try await reader(html)
            for width in [700.0, 420.0] {
                web.setFrameSize(NSSize(width: width, height: 600))
                let result = try await evaluate("""
                    const root=document.getElementById('reader-content'), images=[...root.querySelectorAll('img')];
                    for (const image of images) {
                      image.scrollIntoView({block:'center'});
                      for (let i=0; i<20 && !(image.complete && image.naturalWidth>0); i++) await new Promise(r=>setTimeout(r,50));
                    }
                    return { text:root.innerText, images:images.length, loaded:images.filter(i=>i.complete && i.naturalWidth>0).length,
                      viewport:document.documentElement.clientWidth, width:document.documentElement.scrollWidth };
                    """, in: web) as? [String: Any]
                XCTAssertTrue((result?["text"] as? String ?? "").contains(anchor), name)
                XCTAssertEqual((result?["images"] as? NSNumber)?.intValue, expectedImages, name)
                XCTAssertEqual((result?["loaded"] as? NSNumber)?.intValue, expectedImages, name)
                XCTAssertLessThanOrEqual((result?["width"] as? NSNumber)?.doubleValue ?? .infinity, ((result?["viewport"] as? NSNumber)?.doubleValue ?? 0) + 1, name)
            }
            withExtendedLifetime(owner) {}
        }
    }

    func testPublicBilibiliArticleInNativeReader() async throws {
        guard let path = ProcessInfo.processInfo.environment["READECK_BILI_READER_FIXTURE"] else { throw XCTSkip("Opt-in Bilibili reader probe") }
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let (web, owner) = try await reader(html)
        defer { withExtendedLifetime(owner) {} }
        for width in [700.0, 420.0] {
            web.setFrameSize(NSSize(width: width, height: 600))
            let result = try await evaluate("""
              const root=document.getElementById('reader-content'), imgs=[...root.querySelectorAll('img')];
              for(const img of imgs){img.scrollIntoView({block:'center'});for(let i=0;i<15&&!(img.complete&&img.naturalWidth>0);i++)await new Promise(r=>setTimeout(r,50));}
              return {text:root.innerText, images:imgs.length, loaded:imgs.filter(i=>i.complete&&i.naturalWidth>0).length,
                width:document.documentElement.scrollWidth, viewport:document.documentElement.clientWidth};
            """, in: web) as? [String: Any]
            let text = result?["text"] as? String ?? ""
            XCTAssertTrue(text.contains("程序性能提升的意义")); XCTAssertTrue(text.contains("参考资料"))
            XCTAssertEqual((result?["images"] as? NSNumber)?.intValue, 23)
            XCTAssertLessThanOrEqual((result?["width"] as? NSNumber)?.doubleValue ?? .infinity, ((result?["viewport"] as? NSNumber)?.doubleValue ?? 0) + 1)
            print("BILI_READER",width,"image elements",result?["images"] ?? 0,"loaded",result?["loaded"] ?? 0)
        }
    }

    func testUniformImageParagraphsAndEmptyBlocksWithoutChangingTreeOrText() async throws {
        let html = """
        <section id='outer' style='padding:80px;max-width:250px;background:red'>
        <p id='before' style='text-align:center;color:red;font-size:39px'>正文开始</p>
        <p id='blank'><br></p>
        <section id='image-wrap'><p id='image-p'><img id='image' width='80' height='40' src='data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="80" height="40"/%3E'></p></section>
        <p id='after'>正文结束<strong>语义加粗</strong></p></section>
        """
        let (web, owner) = try await reader(html)
        defer { withExtendedLifetime(owner) {} }
        let result = try await evaluate("""
            const $=id=>document.getElementById(id), s=id=>getComputedStyle($(id));
            return {padding:s('outer').paddingTop, blank:$('blank').getBoundingClientRect().height,
              imageDisplay:s('image').display, centered:Math.abs($('image').getBoundingClientRect().left+$('image').getBoundingClientRect().width/2-$('image-p').getBoundingClientRect().left-$('image-p').getBoundingClientRect().width/2)<1,
              width:$('image').getBoundingClientRect().width,
              imageGap:s('image-p').marginTop, wrapperGap:s('image-wrap').marginTop,
              paths:Array.from(document.querySelectorAll('#outer *')).map(n=>n.tagName).join(','),
              text:$('outer').textContent, weight:getComputedStyle(document.querySelector('strong')).fontWeight};
            """, in: web) as? [String: Any]
        XCTAssertEqual(result?["padding"] as? String, "0px")
        XCTAssertEqual((result?["blank"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(result?["imageDisplay"] as? String, "block")
        XCTAssertEqual(result?["centered"] as? Bool, true)
        XCTAssertEqual((result?["width"] as? NSNumber)?.doubleValue ?? 0, 80, accuracy: 1)
        XCTAssertEqual(result?["imageGap"] as? String, "15px")
        XCTAssertEqual(result?["wrapperGap"] as? String, "0px")
        XCTAssertEqual(result?["paths"] as? String, "P,P,BR,SECTION,P,IMG,P,STRONG")
        XCTAssertTrue((result?["text"] as? String)?.contains("正文结束语义加粗") == true)
        XCTAssertGreaterThanOrEqual(Int(result?["weight"] as? String ?? "0") ?? 0, 600)
    }

    func testHiddenContentCodeAndTableSurviveUnifiedLayout() async throws {
        let (web, owner) = try await reader("""
        <style>.source-hidden { display:none } p { color:red !important; margin:90px !important }</style>
        <div class='source-hidden' id='hidden'>不应显示</div>
        <p id='plain' style='color:orange!important;padding:70px;position:absolute;left:900px'>正常正文</p>
        <pre id='code'>  let x = 1;\n    keepSpaces();</pre>
        <p id='poem' style='white-space:pre-wrap'>诗句一\n\n诗句二</p>
        <table id='table'><tr><th>标题</th><td>值</td></tr></table>
        """)
        defer { withExtendedLifetime(owner) {} }
        let value = try await evaluate("""
            const s=id=>getComputedStyle(document.getElementById(id));
            return {hidden:s('hidden').display,color:s('plain').color,padding:s('plain').paddingTop,
                position:s('plain').position,pre:s('code').whiteSpace,poem:s('poem').whiteSpace,
                table:s('table').overflowX,text:document.getElementById('code').textContent,
                overflow:document.documentElement.scrollWidth>innerWidth};
            """, in: web) as? [String: Any]
        XCTAssertEqual(value?["hidden"] as? String, "none")
        XCTAssertEqual(value?["color"] as? String, "rgb(41, 41, 41)")
        XCTAssertEqual(value?["padding"] as? String, "0px")
        XCTAssertEqual(value?["position"] as? String, "static")
        XCTAssertEqual(value?["pre"] as? String, "pre")
        XCTAssertEqual(value?["poem"] as? String, "pre-wrap")
        XCTAssertEqual(value?["table"] as? String, "auto")
        XCTAssertEqual(value?["text"] as? String, "  let x = 1;\n    keepSpaces();")
        XCTAssertEqual(value?["overflow"] as? Bool, false)
    }

    func testCompatibilityRestoresOriginalStylesAndSwitchBackKeepsSelectors() async throws {
        let (web, owner) = try await reader("<section style='padding:45px'><p id='sample' style='color:red!important'>正文😀<b>加粗</b></p></section>")
        defer { withExtendedLifetime(owner) {} }
        let value = try await evaluate("""
            const root=document.getElementById('reader-content');
            const tree=Array.from(root.querySelectorAll('*')).map(n=>n.tagName).join(',');
            const text=root.textContent;
            const flow=window.__readerReflow;
            if(!flow) return {available:false};
            flow.setEnabled(false);
            const color=getComputedStyle(document.getElementById('sample')).color;
            const padding=getComputedStyle(root.querySelector('section')).paddingTop;
            flow.setEnabled(true);flow.setEnabled(false);flow.setEnabled(true);
            return {available:true,color,padding,treeUnchanged:tree===Array.from(root.querySelectorAll('*')).map(n=>n.tagName).join(','),
                textUnchanged:text===root.textContent,unified:getComputedStyle(document.getElementById('sample')).color};
            """, in: web) as? [String: Any]
        XCTAssertEqual(value?["available"] as? Bool, true)
        XCTAssertEqual(value?["color"] as? String, "rgb(255, 0, 0)")
        XCTAssertEqual(value?["padding"] as? String, "45px")
        XCTAssertEqual(value?["treeUnchanged"] as? Bool, true)
        XCTAssertEqual(value?["textUnchanged"] as? Bool, true)
        XCTAssertEqual(value?["unified"] as? String, "rgb(41, 41, 41)")
    }
    func testNewLayoutControlsApplyLiveWithoutReloadingOrChangingImageCount() async throws {
        let (web, owner) = try await reader("<p id='text'>可以调整的正文。</p><p id='picture'><img width='600' height='300' src='data:image/svg+xml,%3Csvg xmlns=\"http://www.w3.org/2000/svg\" width=\"600\" height=\"300\"/%3E'></p><p>后续正文</p>")
        let before = try await evaluate("return document.querySelector('#picture img').getBoundingClientRect().width", in: web) as? Double
        var style = ReaderStyle.standard
        style.imageSpacing = 1.5
        style.imageWidth = 50
        style.firstLineIndent = true
        style.alignment = "left"
        try await owner.applyStyle(style, in: web)
        let value = try await evaluate("""
            const s=id=>getComputedStyle(document.getElementById(id));
            return {indent:s('text').textIndent, alignment:s('text').textAlign, imageIndent:s('picture').textIndent,
              gap:s('picture').marginTop,width:document.querySelector('#picture img').getBoundingClientRect().width,
              count:document.querySelectorAll('img').length,documentID:document.body.dataset.readerDocument};
            """, in: web) as? [String: Any]
        XCTAssertEqual(value?["indent"] as? String, "30px")
        XCTAssertEqual(value?["imageIndent"] as? String, "0px")
        XCTAssertEqual(value?["alignment"] as? String, "left")
        XCTAssertEqual(value?["gap"] as? String, "22.5px")
        XCTAssertLessThan((value?["width"] as? Double) ?? 900, (before ?? 600)*0.6)
        XCTAssertEqual(value?["count"] as? Int, 1)
        style.unifiedLayout = false
        try await owner.applyStyle(style, in: web)
        let compatible = try await evaluate("return document.getElementById('reader-content').dataset.readerLayout", in: web)
        XCTAssertEqual(compatible as? String, "compatible")
        style.unifiedLayout = true
        try await owner.applyStyle(style, in: web)
        let documentID = try await evaluate("return document.body.dataset.readerDocument", in: web)
        XCTAssertEqual(documentID as? String, value?["documentID"] as? String)
    }

    func testLateImageKeepsReadingTextAtSameViewportPosition() async throws {
        let paragraphs = (0..<30).map { "<p id='p\($0)'>" + String(repeating: "正文段落用于验证图片迟到后仍停留在相同文字。", count: 8) + "</p>" }.joined()
        let (web, owner) = try await reader("<p><img id='late' width='600' height='20'></p>" + paragraphs)
        defer { withExtendedLifetime(owner) {} }
        let before = try await evaluate("""
            const p=document.getElementById('p8'); scrollBy(0,p.getBoundingClientRect().top-40);
            await new Promise(r=>setTimeout(r,80));
            window.__readerReflow?.capturePosition?.();
            return p.getBoundingClientRect().top;
            """, in: web) as? Double
        let after = try await evaluate("""
            const image=document.getElementById('late');
            await new Promise(resolve=>{image.onload=resolve;image.src='data:image/svg+xml,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="500"/>');});
            await new Promise(r=>setTimeout(r,180));
            return document.getElementById('p8').getBoundingClientRect().top;
            """, in: web) as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 3)
    }

    func testTypographyRetainsVisibleCharacterInsideLongParagraph() async throws {
        let (web, owner) = try await reader("<p id='long'>" + String(repeating: "长段落中的具体文字应保持阅读位置，中英文 mixed content 123。", count: 300) + "</p>")
        let before = try await evaluate("""
            document.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1900}));
            scrollTo(0,1900);await new Promise(r=>setTimeout(r,220));
            const p=document.getElementById('long');
            const r=document.caretRangeFromPoint(p.getBoundingClientRect().left+6,40);
            r.setEnd(r.startContainer,Math.min(r.startContainer.length,r.startOffset+1));
            window.__positionTestRange=r;
            return r.getBoundingClientRect().top;
            """, in: web) as? Double
        var style = ReaderStyle.standard
        style.fontSize = 23; style.contentWidth = 540; style.lineHeight = 1.9
        try await owner.applyStyle(style, in: web)
        let after = try await evaluate("return window.__positionTestRange.getBoundingClientRect().top", in: web) as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 3)
    }

    func testAnnotationSelectorsAndScalarOffsetsSurviveAllLayoutChanges() async throws {
        let (web, owner) = try await reader("<section><p>A😀中<strong>文😺</strong> tail</p><p>second</p></section>")
        let original = try await evaluate("""
            const p=document.querySelector('#reader-content p'),strong=p.querySelector('strong');
            getSelection().setBaseAndExtent(p.firstChild,1,strong.firstChild,3);
            return window.__readerAnnotations.selection();
            """, in: web) as? [String: Any]
        var style = ReaderStyle.standard;style.fontSize = 22;style.firstLineIndent = true
        try await owner.applyStyle(style, in: web)
        style.unifiedLayout = false;try await owner.applyStyle(style, in: web)
        style.unifiedLayout = true;try await owner.applyStyle(style, in: web)
        let result = try await evaluate("""
            const current=window.__readerAnnotations.selection();
            const saved={id:'server-roundtrip',start_selector:'section[1]/p[1]',start_offset:1,
              end_selector:'section[1]/p[1]/strong[1]',end_offset:2,color:'yellow',note:'批注'};
            window.__readerAnnotations.render([saved]);
            return {current,highlight:CSS.highlights.get('reader-annotation-yellow')?.size};
            """, in: web) as? [String: Any]
        let current = try XCTUnwrap(result?["current"] as? [String: Any])
        for key in ["start_selector", "end_selector", "text"] { XCTAssertEqual(current[key] as? String, original?[key] as? String) }
        for key in ["start_offset", "end_offset"] { XCTAssertEqual(current[key] as? Int, original?[key] as? Int) }
        XCTAssertEqual(current["text"] as? String, "😀中文😺")
        XCTAssertEqual(result?["highlight"] as? Int, 1)
    }

    func testFigureCaptionAndSpecialContentShareUnifiedRhythm() async throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='640' height='210'><rect width='640' height='210' fill='#d8e5df'/><path d='M0 160L120 50L250 175L410 35L640 170V210H0' fill='#8bab9b'/><circle cx='525' cy='48' r='22' fill='#f3dfb7'/></svg>"
        let image = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let (web, owner) = try await reader("""
        <h2>让文章回到阅读本身</h2>
        <p>不同来源的文章，也可以拥有一致的阅读节奏。字体、留白和图文间距跟随你的偏好，内容本身保持完整。</p>
        <figure><p id='media'><img src='\(image)'></p><figcaption id='caption'>插图与说明使用统一的间距</figcaption></figure>
        <p>阅读风格可以自由调整。语义上的<strong>重点</strong>、<em>强调</em>与<a href='https://example.com'>参考链接</a>仍被保留。</p>
        <blockquote><p>统一的是阅读体验，保留的是文章内容。</p></blockquote>
        <ul><li id='list'>列表保留层级与标记</li><li>代码和表格使用各自的阅读规则</li></ul>
        <pre>let reading = "comfortable"</pre>
        """)
        defer { withExtendedLifetime(owner) {} }
        let metrics = try await evaluate("""
            const s=id=>getComputedStyle(document.getElementById(id));
            return {mediaGap:s('media').marginTop,captionSize:s('caption').fontSize,
              captionAlign:s('caption').textAlign,list:s('list').display,
              bold:getComputedStyle(document.querySelector('strong')).fontWeight,
              italic:getComputedStyle(document.querySelector('em')).fontStyle,
              overflow:document.documentElement.scrollWidth>innerWidth};
            """, in: web) as? [String: Any]
        XCTAssertEqual(metrics?["mediaGap"] as? String, "0px")
        XCTAssertEqual(metrics?["captionSize"] as? String, "12.75px")
        XCTAssertEqual(metrics?["captionAlign"] as? String, "center")
        XCTAssertEqual(metrics?["list"] as? String, "list-item")
        XCTAssertEqual(metrics?["italic"] as? String, "italic")
        XCTAssertEqual(metrics?["overflow"] as? Bool, false)
        if let output = ProcessInfo.processInfo.environment["READECK_REFLOW_QA_DIR"] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 780),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false;window.contentView = web;window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(120))
            let picture = try await web.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(picture.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("reader-reflow.png"))
            let defaultsName = "readck-reflow-ui-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let appearance = NSHostingView(rootView: ReaderAppearanceView().environmentObject(ReaderPreferences(defaults: defaults))
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            window.contentView = appearance;window.setContentSize(NSSize(width: 300, height: 340))
            try await Task.sleep(for: .milliseconds(100))
            appearance.layoutSubtreeIfNeeded()
            let settings = try XCTUnwrap(appearance.bitmapImageRepForCachingDisplay(in: appearance.bounds))
            appearance.cacheDisplay(in: appearance.bounds, to: settings)
            try XCTUnwrap(settings.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("reader-settings.png"))
        }
    }

    func testAccessibilityHiddenDoesNotHideVisibleEquationsOrPictures() async throws {
        let (web, owner) = try await reader("<p>公式：<span id='equation' aria-hidden='true'>E = mc²</span></p><p><img id='visual' aria-hidden='true' width='100' height='50'></p><p><img id='hidden-picture' style='display:none' width='100' height='50'></p>")
        defer { withExtendedLifetime(owner) {} }
        let result = try await evaluate("""
            return {equation:getComputedStyle(document.getElementById('equation')).display,
              image:getComputedStyle(document.getElementById('visual')).display,
              hiddenPicture:getComputedStyle(document.getElementById('hidden-picture')).display,
              accessibility:document.getElementById('equation').getAttribute('aria-hidden')};
            """, in: web) as? [String: Any]
        XCTAssertNotEqual(result?["equation"] as? String, "none")
        XCTAssertNotEqual(result?["image"] as? String, "none")
        XCTAssertEqual(result?["accessibility"] as? String, "true")
        XCTAssertEqual(result?["hiddenPicture"] as? String, "none")
    }

    func testStandalonePicturesAndMixedParagraphPicturesUseImageControlsButIconsStayInline() async throws {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='600' height='300'/>"
        let source = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        let (web, owner) = try await reader("<p>之前</p><img id='direct' src='\(source)'><p>之后</p><p>说明文字<img id='mixed' src='\(source)'></p><p>内联图标<img id='icon' width='16' height='16'>继续文字</p>")
        var style = ReaderStyle.standard;style.imageWidth = 50;style.imageSpacing = 2
        try await owner.applyStyle(style, in: web)
        let result = try await evaluate("""
            const metrics=id=>{const n=document.getElementById(id),r=n.getBoundingClientRect(),p=n.parentElement.getBoundingClientRect(),s=getComputedStyle(n);
              return {width:r.width,display:s.display,gap:s.marginTop,centered:Math.abs(r.left+r.width/2-p.left-p.width/2)<1};};
            return {direct:metrics('direct'),mixed:metrics('mixed'),icon:metrics('icon')};
            """, in: web) as? [String: Any]
        for key in ["direct", "mixed"] {
            let item = try XCTUnwrap(result?[key] as? [String: Any])
            XCTAssertEqual(item["display"] as? String, "block")
            XCTAssertEqual(item["gap"] as? String, "30px")
            XCTAssertLessThan((item["width"] as? Double) ?? 900, 330)
            XCTAssertEqual(item["centered"] as? Bool, true)
        }
        XCTAssertEqual((result?["icon"] as? [String: Any])?["display"] as? String, "inline")
    }

    func testOverlappingStyleUpdatesShareOriginalVisibleCharacterAnchor() async throws {
        let (web, owner) = try await reader("<p id='long'>" + String(repeating: "连续调整字号时，应保持原来正在阅读的文字位置。", count: 500) + "</p>")
        let before = try await evaluate("""
            document.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1900}));
            scrollTo(0,1900);await new Promise(r=>setTimeout(r,220));
            const p=document.getElementById('long');
            const r=document.caretRangeFromPoint(p.getBoundingClientRect().left+6,40);
            r.setEnd(r.startContainer,r.startOffset+1);window.__rapidRange=r;
            window.__glyphTop=r=>Array.from(r.getClientRects()).find(rect=>rect.width>0&&rect.height>0).top;
            if(scrollY<1800) throw new Error('Test did not reach the reading location');
            return window.__glyphTop(r);
            """, in: web) as? Double
        var larger = ReaderStyle.standard;larger.fontSize = 26;larger.contentWidth = 480
        var final = ReaderStyle.standard;final.fontSize = 18;final.contentWidth = 780
        let firstStyle = larger, lastStyle = final
        let first = Task { @MainActor in try await owner.applyStyle(firstStyle, in: web) }
        let second = Task { @MainActor in try await owner.applyStyle(lastStyle, in: web) }
        try await first.value;try await second.value
        let after = try await evaluate("return window.__glyphTop(window.__rapidRange)", in: web) as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 3)
    }

    func testUserScrollDuringStyleUpdateWinsOverPendingRestoration() async throws {
        let (web, owner) = try await reader("<p>" + String(repeating: "用户滚动优先于旧排版位置恢复。", count: 900) + "</p>")
        _ = try await evaluate("""
            document.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:1900}));
            scrollTo(0,1900);await new Promise(r=>setTimeout(r,220));
            const observer=new MutationObserver(()=>{
              observer.disconnect();
              document.dispatchEvent(new WheelEvent('wheel',{bubbles:true,deltaY:350}));
              scrollBy(0,350);window.__userScrollY=scrollY;
            });
            observer.observe(document.getElementById('reader-style'),{childList:true,subtree:true,characterData:true});
            """, in: web)
        var style = ReaderStyle.standard;style.fontSize = 23
        try await owner.applyStyle(style, in: web)
        try await Task.sleep(for: .milliseconds(100))
        let value = try await evaluate("return {actual:scrollY,requested:window.__userScrollY}", in: web) as? [String: Double]
        XCTAssertEqual(try XCTUnwrap(value?["actual"]), try XCTUnwrap(value?["requested"]), accuracy: 3)
    }

}
