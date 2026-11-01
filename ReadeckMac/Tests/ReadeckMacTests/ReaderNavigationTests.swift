import AppKit
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderNavigationTests: XCTestCase {
    func testFindMatchesUnicodeAcrossInlineNodesWithoutCrossingBlocks() async throws {
        let view = try await load("""
            <p>中文<span>阅读</span> 👩‍💻 <em>中文</em>阅读</p>
            <p>alpha</p><p>beta</p><p>alpha<br>beta</p>
            <p hidden>中文阅读</p><p style="display:none">中文阅读</p>
            <p style="visibility:hidden">中文阅读</p><p style="content-visibility:hidden">中文阅读</p>
            <script>document.body.dataset.sourceRan='yes'; 中文阅读</script><style>/* 中文阅读 */</style>
            """)
        let chinese = try await find("中文阅读", in: view)
        XCTAssertEqual(chinese, ReaderFindState(count: 2, current: 1))
        let highlighted = try await evaluate("return [...CSS.highlights.get('reader-find')].map(range=>range.toString())", in: view)
        XCTAssertEqual(highlighted as? [String], ["中文阅读", "中文阅读"])
        let emoji = try await find("👩‍💻", in: view)
        XCTAssertEqual(emoji, ReaderFindState(count: 1, current: 1))
        let boundary = try await find("alphabeta", in: view)
        XCTAssertEqual(boundary, ReaderFindState())
        let sourceRan = try await evaluate("return document.body.dataset.sourceRan || 'no'", in: view)
        XCTAssertEqual(sourceRan as? String, "no")
    }

    func testCaseInsensitiveLiteralFindWrapsAndClearsBothHighlights() async throws {
        let view = try await load("<p>Apple apple APPLE [a.*] İstanbul</p>")
        let first = try await find("APPLE", in: view)
        XCTAssertEqual(first, ReaderFindState(count: 3, current: 1))
        let next = try await find("APPLE", step: 1, in: view)
        XCTAssertEqual(next, ReaderFindState(count: 3, current: 2))
        let previous = try await find("APPLE", step: -1, in: view)
        XCTAssertEqual(previous, ReaderFindState(count: 3, current: 1))
        let wrapped = try await find("APPLE", step: -1, in: view)
        XCTAssertEqual(wrapped, ReaderFindState(count: 3, current: 3))
        let wrappedNext = try await find("APPLE", step: 1, in: view)
        XCTAssertEqual(wrappedNext, ReaderFindState(count: 3, current: 1))
        let literal = try await find("[a.*]", in: view)
        XCTAssertEqual(literal, ReaderFindState(count: 1, current: 1))
        let folded = try await find("STANBUL", in: view)
        XCTAssertEqual(folded, ReaderFindState(count: 1, current: 1))
        let foldedText = try await evaluate("return [...CSS.highlights.get('reader-find-current')][0].toString()", in: view)
        XCTAssertEqual(foldedText as? String, "stanbul")
        for query in ["absent", "", " \n\t", String(repeating: "a", count: 257)] {
            _ = try await find("apple", in: view)
            let cleared = try await find(query, in: view)
            XCTAssertEqual(cleared, ReaderFindState())
            try await assertHighlightsCleared(in: view)
        }
        _ = try await find("apple", in: view)
        let explicitlyCleared = try await decodeState("return window.__readerNavigation?.clear()", in: view)
        XCTAssertEqual(explicitlyCleared, ReaderFindState())
        try await assertHighlightsCleared(in: view)
    }

    func testLongPastedLiteralQueryMatchesWithoutTruncation() async throws {
        let query = String(repeating: "阅读👩‍💻", count: 65)
        let view = try await load("<p>\(query)</p><p>\(query)</p>")
        let result = try await find(query, in: view)
        XCTAssertEqual(result, ReaderFindState(count: 2, current: 1))
    }

    func testFindCollapsesRenderedWhitespaceAcrossInlineNodesWithoutChangingOriginalRanges() async throws {
        let view = try await load("""
            <p>hello
                world</p><p>hello <span>
            \t </span> world</p><p style='white-space:nowrap'>hello\t\tworld</p>
            <p style='white-space:pre'>hello  world</p>
            <p style='white-space:pre-wrap'>hello  world</p>
            <p style='white-space:break-spaces'>hello  world</p>
            <p style='white-space:pre-line'>hello \t world</p>
            <p style='white-space:pre-line'>hello 
                world</p>
            <p>mixed <span style='white-space:pre'>  value</span> end</p>
            """)
        let before = try await evaluate("return document.body.innerHTML", in: view) as? String
        let collapsed = try await find("hello world", in: view)
        XCTAssertEqual(collapsed, ReaderFindState(count: 4, current: 1))
        let originalRanges = try await evaluate("return [...(CSS.highlights.get('reader-find') || [])].map(range=>range.toString())", in: view)
        XCTAssertEqual(originalRanges as? [String], ["hello\n    world", "hello \n\t  world", "hello\t\tworld", "hello \t world"])
        let preserved = try await find("hello  world", in: view)
        XCTAssertEqual(preserved, ReaderFindState(count: 3, current: 1))
        let preservedBreak = try await find("hello\nworld", in: view)
        XCTAssertEqual(preservedBreak, ReaderFindState(count: 1, current: 1))
        let mixedBoundary = try await find("mixed   value", in: view)
        XCTAssertEqual(mixedBoundary, ReaderFindState())
        let after = try await evaluate("return document.body.innerHTML", in: view) as? String
        XCTAssertEqual(after, before)
    }

    func testCaseInsensitiveFindFoldsGreekFinalSigmaAndKeepsDottedIOffsets() async throws {
        let view = try await load("<p>ΟΣ ος Οσ οσ</p><p>Ο<span>Σ</span></p><p>İstanbul</p>")
        let lowercase = try await find("ος", in: view)
        XCTAssertEqual(lowercase, ReaderFindState(count: 5, current: 1))
        let ranges = try await evaluate("return [...CSS.highlights.get('reader-find')].map(range=>range.toString())", in: view)
        XCTAssertEqual(ranges as? [String], ["ΟΣ", "ος", "Οσ", "οσ", "ΟΣ"])
        let uppercaseNext = try await find("ΟΣ", step: 1, in: view)
        XCTAssertEqual(uppercaseNext, ReaderFindState(count: 5, current: 2))
        let dottedI = try await find("i\u{0307}", in: view)
        XCTAssertEqual(dottedI, ReaderFindState(count: 1, current: 1))
        let original = try await evaluate("return [...CSS.highlights.get('reader-find-current')][0].toString()", in: view)
        XCTAssertEqual(original as? String, "İ")
    }

    func testOutlineUsesVisibleActualHeadingsAndRevealsTheirDocumentPositions() async throws {
        let view = try await load("""
            <h1>  First <em>heading</em> </h1><h2 hidden>Hidden</h2>
            <h3 style="visibility:hidden">Invisible</h3><h4>   </h4>
            <p>Ordinary text</p>
            \(String(repeating: "<p style='height:45px'>Long article</p>", count: 35))
            <h6>最后一节 👩‍💻</h6>
            """)
        let outlineResult = try await evaluate("return window.__readerNavigation?.outline()", in: view)
        let raw = try XCTUnwrap(outlineResult)
        let data = try JSONSerialization.data(withJSONObject: raw)
        let headings = try JSONDecoder().decode([ReaderHeading].self, from: data)
        XCTAssertEqual(headings, [ReaderHeading(index: 0, level: 1, title: "First heading"),
                                  ReaderHeading(index: 1, level: 6, title: "最后一节 👩‍💻")])
        let revealed = try await evaluate("return window.__readerNavigation?.revealHeading(1)", in: view)
        XCTAssertEqual(revealed as? Bool, true)
        let scrolled = try await evaluate("return scrollY>0", in: view)
        XCTAssertEqual(scrolled as? Bool, true)
        let invalid = try await evaluate("return window.__readerNavigation?.revealHeading(99)", in: view)
        XCTAssertEqual(invalid as? Bool, false)
    }

    func testNavigationDoesNotChangeArticleMarkupAnnotationPathsOrNativeSelection() async throws {
        let view = try await load("<h2>Heading</h2><p>Some <span>selected</span> article text.</p><p>article</p>")
        let before = try await evaluate("""
            const text=document.querySelector('span').firstChild;
            const range=document.createRange();range.selectNodeContents(text);
            getSelection().removeAllRanges();getSelection().addRange(range);
            return {html:document.body.innerHTML, selection:getSelection().toString(),
                path:document.evaluate("//*[@id='reader-content']/p[1]/span/text()",document,null,XPathResult.STRING_TYPE,null).stringValue};
            """, in: view) as? [String: String]
        _ = try await find("article", in: view)
        _ = try await find("article", step: 1, in: view)
        _ = try await evaluate("window.__readerNavigation?.outline(); window.__readerNavigation?.revealHeading(0); return window.__readerNavigation?.clear()", in: view)
        let after = try await evaluate("""
            return {html:document.body.innerHTML, selection:getSelection().toString(),
                path:document.evaluate("//*[@id='reader-content']/p[1]/span/text()",document,null,XPathResult.STRING_TYPE,null).stringValue};
            """, in: view) as? [String: String]
        XCTAssertEqual(after, before)
        XCTAssertEqual(after?["selection"], "selected")
    }

    func testFindRebuildsRangesAfterArticleReplacementAndTypographyChanges() async throws {
        let view = try await load("<p>original needle</p>")
        _ = try await find("needle", in: view)
        _ = try await evaluate("document.getElementById('reader-content').outerHTML='<main id=reader-content><h3>Replacement</h3><p>new needle needle</p></main>'; return true", in: view)
        try await assertHighlightsCleared(in: view)
        let replacement = try await find("needle", step: 1, in: view)
        XCTAssertEqual(replacement, ReaderFindState(count: 2, current: 1))
        _ = try await evaluate("document.body.style.fontSize='29px';document.body.style.lineHeight='2';return true", in: view)
        let next = try await find("needle", step: 1, in: view)
        XCTAssertEqual(next, ReaderFindState(count: 2, current: 2))
        let connected = try await evaluate("return [...CSS.highlights.get('reader-find')].every(range=>document.getElementById('reader-content').contains(range.startContainer))", in: view)
        XCTAssertEqual(connected as? Bool, true)
        _ = try await evaluate("document.getElementById('reader-content').innerHTML='<p>changed</p>';return true", in: view)
        let noResults = try await find("needle", step: 1, in: view)
        XCTAssertEqual(noResults, ReaderFindState())
        try await assertHighlightsCleared(in: view)
    }

    func testFindCapturesItsReadingPositionForLaterImageReflow() async throws {
        let view = try await load("""
            <img id='late' width='300' height='20'>
            \(String(repeating: "<p>正文段落，用于检查定位后的阅读位置。</p>", count: 40))
            <p>Find this needle here.</p>
            \(String(repeating: "<p>后续正文段落，提供足够的滚动空间。</p>", count: 30))
            """, withReflow: true)
        _ = try await evaluate("await new Promise(r=>setTimeout(r,120));window.__readerReflow.capturePosition();return true", in: view)
        let found = try await find("needle", in: view)
        XCTAssertEqual(found, ReaderFindState(count: 1, current: 1))
        let before = try await evaluate("return [...CSS.highlights.get('reader-find-current')][0].getBoundingClientRect().top", in: view) as? Double
        let after = try await evaluate("""
            document.getElementById('late').height=420;
            await new Promise(r=>setTimeout(r,180));
            return [...CSS.highlights.get('reader-find-current')][0].getBoundingClientRect().top;
            """, in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(before), 72, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 3)
    }

    func testOutlineAttributeTrackingPreservesFindAcrossReflowStyleChanges() async throws {
        let view = try await load("<h2 style='font-size:24px'>章节</h2><p style='line-height:2'>needle needle</p>", withReflow: true)
        let state = try await find("needle", in: view)
        XCTAssertEqual(state, ReaderFindState(count: 2, current: 1))
        _ = try await evaluate("window.__readerReflow.setEnabled(true);await new Promise(r=>setTimeout(r,80));return true", in: view)
        let count = try await evaluate("return CSS.highlights.get('reader-find')?.size || 0", in: view)
        XCTAssertEqual((count as? NSNumber)?.intValue, 2, "Typography/reflow changes cannot leave a stale find count with no highlights")
        let next = try await find("needle", step: 1, in: view)
        XCTAssertEqual(next, ReaderFindState(count: 2, current: 2))
    }

    func testCurrentSectionTracksScrollJumpAndImageReflowWithoutChangingMarkup() async throws {
        let view = try await load("""
            <img id='late' style='display:block;width:200px;height:20px'>
            <h2>第一节</h2><p style='height:600px'>第一节正文</p>
            <h3>第二节</h3><p style='height:600px'>第二节正文</p>
            <h2>第三节</h2><p style='height:600px'>第三节正文</p>
            """)
        let before = try await evaluate("return document.body.innerHTML", in: view) as? String
        let first = try await evaluate("return window.__readerNavigation?.currentHeading?.() ?? -99", in: view)
        XCTAssertEqual((first as? NSNumber)?.intValue, 0)
        _ = try await evaluate("window.__readerNavigation?.revealHeading(1); return true", in: view)
        let second = try await evaluate("return window.__readerNavigation?.currentHeading?.() ?? -99", in: view)
        XCTAssertEqual((second as? NSNumber)?.intValue, 1)
        let unchanged = try await evaluate("return document.body.innerHTML", in: view) as? String
        XCTAssertEqual(unchanged, before)
        _ = try await evaluate("document.getElementById('late').style.height='900px'; await new Promise(r=>setTimeout(r,80)); return true", in: view)
        let moved = try await evaluate("return window.__readerNavigation?.currentHeading?.() ?? -99", in: view)
        XCTAssertEqual((moved as? NSNumber)?.intValue, 0)
        _ = try await evaluate("window.scrollTo(0,document.documentElement.scrollHeight);return true", in: view)
        let last = try await evaluate("return window.__readerNavigation?.currentHeading?.() ?? -99", in: view)
        XCTAssertEqual((last as? NSNumber)?.intValue, 2)
    }

    func testCurrentSectionIgnoresHiddenHeadingsAndClearsWhenArticleIsReplaced() async throws {
        let view = try await load("<h2 hidden>隐藏</h2><h3>可见</h3><p style='height:800px'>正文</p>")
        let first = try await evaluate("return window.__readerNavigation?.currentHeading?.() ?? -99", in: view)
        XCTAssertEqual((first as? NSNumber)?.intValue, 0)
        _ = try await evaluate("document.getElementById('reader-content').innerHTML='<p>没有目录</p>';return true", in: view)
        let empty = try await evaluate("return window.__readerNavigation?.currentHeading?.() ?? -99", in: view)
        XCTAssertEqual((empty as? NSNumber)?.intValue, -99)
    }

    private func load(_ fragment: String, withReflow: Bool = false) async throws -> WKWebView {
        let loaded = expectation(description: "Navigation article loaded")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if withReflow {
            configuration.userContentController.addUserScript(WKUserScript(source: ReaderReflow.bootstrap,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: ReaderNavigationScript.bootstrap,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 400), configuration: configuration)
        let observer = NavigationLoadObserver { loaded.fulfill() }
        view.navigationDelegate = observer
        view.loadHTMLString("<!doctype html><html><head><meta charset=utf-8></head><body data-reader-unified=false><main id=reader-content>\(fragment)</main></body></html>", baseURL: URL(string: "about:blank"))
        await fulfillment(of: [loaded], timeout: 10)
        view.navigationDelegate = nil
        return view
    }

    private func evaluate(_ script: String, in view: WKWebView, arguments: [String: Any] = [:]) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    private func find(_ query: String, step: Int = 0, in view: WKWebView) async throws -> ReaderFindState {
        try await decodeState("return window.__readerNavigation?.find(query,step)", in: view, arguments: ["query": query, "step": step])
    }

    private func decodeState(_ script: String, in view: WKWebView, arguments: [String: Any] = [:]) async throws -> ReaderFindState {
        let result = try await evaluate(script, in: view, arguments: arguments)
        let raw = try XCTUnwrap(result)
        return try JSONDecoder().decode(ReaderFindState.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private func assertHighlightsCleared(in view: WKWebView) async throws {
        let sizes = try await evaluate("return ['reader-find','reader-find-current'].map(name=>CSS.highlights.get(name)?.size || 0)", in: view)
        XCTAssertEqual(sizes as? [Int], [0, 0])
    }
}

@MainActor
private final class NavigationLoadObserver: NSObject, WKNavigationDelegate {
    let onLoad: () -> Void
    init(onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad() }
}
