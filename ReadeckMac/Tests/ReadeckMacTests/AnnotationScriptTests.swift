import AppKit
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class AnnotationScriptTests: XCTestCase {
    func testSelectionNearEndOfParagraphWithLineBreaksAnchorsToSelectedLine() async throws {
        let text = String(repeating: "这一段文字应当显示在对应的阅读位置。", count: 8)
        let fixture = try await load("<p style='width:500px;line-height:28px'>" + Array(repeating: text, count: 5).joined(separator: "<br>") + "</p>")
        let result = try await fixture.run("""
            const p=document.querySelector('#reader-content p'), t=[...p.childNodes].filter(n=>n.nodeType===3).at(-1);
            t.parentElement.scrollIntoView({block:'start'});
            const range=document.createRange();range.setStart(t,3);range.setEnd(t,t.length);
            const last=Array.from(range.getClientRects()).at(-1);
            scrollBy(0,last.top-innerHeight/2);
            const r=Array.from(range.getClientRects()).at(-1);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true}));
            document.dispatchEvent(new MouseEvent('pointerup',{bubbles:true,clientX:r.right-2,clientY:r.top+r.height/2}));
            return {anchor:window.__readerAnnotations.selection().anchor, top:r.top,bottom:r.bottom};
            """) as? [String: Any]
        let anchor = try XCTUnwrap(result?["anchor"] as? [String: Any])
        XCTAssertEqual(anchor["y"] as! Double, result?["top"] as! Double, accuracy: 1)
    }
    func testSelectionAnchorStaysOnReleaseLine() async throws {
        let fixture = try await load("<p style='width:180px;font-size:18px;line-height:28px'>这是多行选区定位回归测试。选中的文字跨越多行，工具条应位于选区外侧。</p>")
        let result = try await fixture.run("""
            const p=document.querySelector('p'); const node=p.firstChild;
            const range=document.createRange();range.selectNodeContents(p);
            getSelection().removeAllRanges();getSelection().addRange(range);
            const rects=Array.from(range.getClientRects()).filter(r=>r.width>0&&r.height>0);
            const last=rects.at(-1), x=last.right-2,y=last.top+last.height/2;
            document.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true,clientX:rects[0].left+1,clientY:rects[0].top+2}));
            document.dispatchEvent(new MouseEvent('pointerup',{bubbles:true,clientX:x,clientY:y}));
            return {anchor:window.__readerAnnotations.selection().anchor,top:rects[0].top,bottom:last.bottom,x,y};
            """) as? [String: Any]
        let anchor = try XCTUnwrap(result?["anchor"] as? [String: Any])
        XCTAssertEqual(anchor["width"] as? Double, 1)
        XCTAssertEqual(anchor["x"] as! Double, result?["x"] as! Double, accuracy: 1)
        XCTAssertEqual(anchor["y"] as! Double, result?["top"] as! Double, accuracy: 1)
        XCTAssertEqual((anchor["y"] as! Double) + (anchor["height"] as! Double), result?["bottom"] as! Double, accuracy: 1)
        XCTAssertNotNil(anchor["pointerY"])
    }
    func testReverseSelectionAnchorsToReleaseLine() async throws {
        let fixture = try await load("<p style='width:180px;font-size:18px;line-height:28px'>这是多行选区定位回归测试。选中的文字跨越多行，工具条应位于选区外侧。</p>")
        let result = try await fixture.run("""
            const node=document.querySelector('p').firstChild;
            getSelection().setBaseAndExtent(node,node.length,node,0);
            const rects=Array.from(getSelection().getRangeAt(0).getClientRects()).filter(r=>r.width>0&&r.height>0);
            const first=rects[0], x=first.left+2, y=first.top+first.height/2;
            document.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true}));
            document.dispatchEvent(new MouseEvent('pointerup',{bubbles:true,clientX:x,clientY:y}));
            return {anchor:window.__readerAnnotations.selection().anchor,top:first.top,bottom:first.bottom};
            """) as? [String: Any]
        let anchor = try XCTUnwrap(result?["anchor"] as? [String: Any])
        XCTAssertEqual(anchor["y"] as! Double, result?["top"] as! Double, accuracy: 1)
        XCTAssertEqual(anchor["preferredSide"] as? String, "above")
    }
    func testSelectionUsesSourceRelativePathsAndUnicodeScalarOffsetsInBothDirections() async throws {
        let fixture = try await load("<p>A😀中<strong>文😺 end</strong> tail</p><p>next Ω</p>")
        let result = try await fixture.run("""
            const first=document.querySelector('#reader-content p').firstChild;
            const last=document.querySelector('#reader-content strong').firstChild;
            getSelection().setBaseAndExtent(last,3,first,1);
            return window.__readerAnnotations?.selection() || null;
            """) as? [String: Any]
        XCTAssertEqual(result?["start_selector"] as? String, "p[1]")
        XCTAssertEqual(result?["start_offset"] as? Int, 1)
        XCTAssertEqual(result?["end_selector"] as? String, "p[1]/strong[1]")
        XCTAssertEqual(result?["end_offset"] as? Int, 2)
        XCTAssertEqual(result?["text"] as? String, "😀中文😺")
    }

    func testElementBoundariesAndServerWrappersResolveAgainstCleanSource() async throws {
        let fixture = try await load("Lead😀<p>A<rd-annotation data-annotation-id-value='old'>😀<strong>中</strong></rd-annotation>Z<rd-annotation data-annotation-note title='note'>✎</rd-annotation></p>")
        let result = try await fixture.run("""
            const root=document.getElementById('reader-content');
            const p=root.querySelector('p');
            const range=document.createRange(); range.selectNodeContents(p);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            const paragraph=window.__readerAnnotations?.selection() || null;
            range.setStart(root.firstChild,4); range.setEnd(root.firstChild,6);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            return {paragraph, direct:window.__readerAnnotations?.selection() || null,
                    wrappers:root.querySelectorAll('rd-annotation').length, text:p.textContent};
            """) as? [String: Any]
        let paragraph = result?["paragraph"] as? [String: Any]
        XCTAssertEqual(paragraph?["start_selector"] as? String, "p[1]")
        XCTAssertEqual(paragraph?["start_offset"] as? Int, 0)
        XCTAssertEqual(paragraph?["end_selector"] as? String, "p[1]")
        XCTAssertEqual(paragraph?["end_offset"] as? Int, 4)
        XCTAssertEqual(paragraph?["text"] as? String, "A😀中Z")
        let direct = result?["direct"] as? [String: Any]
        XCTAssertEqual(direct?["start_selector"] as? String, ".")
        XCTAssertEqual(direct?["start_offset"] as? Int, 4)
        XCTAssertEqual(direct?["end_selector"] as? String, ".")
        XCTAssertEqual(direct?["end_offset"] as? Int, 5)
        XCTAssertEqual(direct?["text"] as? String, "😀")
        XCTAssertEqual(result?["wrappers"] as? Int, 0)
        XCTAssertEqual(result?["text"] as? String, "A😀中Z")
    }

    func testRenderResolvesCrossElementRangesAndOverlapWithoutChangingSourceOrLayout() async throws {
        let fixture = try await load("<p>A😀中<strong>文😺</strong> tail</p><p>second</p>")
        let items: [[String: Any]] = [
            ["id": "one", "start_selector": "p[1]", "start_offset": 1,
             "end_selector": "p[1]/strong[1]", "end_offset": 2, "color": "yellow", "note": "note"],
            ["id": "two", "start_selector": "p[1]/strong[1]", "start_offset": 0,
             "end_selector": "p[2]", "end_offset": 3, "color": "blue"],
            ["id": "unsafe", "start_selector": "../p[1]", "start_offset": 0,
             "end_selector": "p[1]", "end_offset": 1, "color": "red"],
            ["id": "invalid", "start_selector": "p[1]", "start_offset": -1,
             "end_selector": "p[1]", "end_offset": 999, "color": "red"]
        ]
        let result = try await fixture.run("""
            const root=document.getElementById('reader-content');
            const before=root.innerHTML;
            const bounds=()=>Array.from(root.querySelectorAll('*')).map(n=>{
                const r=n.getBoundingClientRect(); return [r.x,r.y,r.width,r.height];
            });
            const layout=JSON.stringify(bounds());
            window.__readerAnnotations?.render(items);
            const drawn=Array.from(CSS.highlights?.values() || []).flatMap(h=>Array.from(h).map(r=>r.toString()));
            window.__readerAnnotations?.render(items);
            const painted=CSS.highlights.size;
            const cleared=window.__readerAnnotations?.render([]);
            const remaining=CSS.highlights.size;
            const p=root.querySelector('p'); const range=document.createRange();
            range.setStart(p.firstChild,1); range.setEnd(p.querySelector('strong').firstChild,3);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            return {drawn, painted, cleared, remaining, unchanged:root.innerHTML===before, sameLayout:JSON.stringify(bounds())===layout,
                    selection:window.__readerAnnotations?.selection() || null};
            """, arguments: ["items": items]) as? [String: Any]
        let drawn = result?["drawn"] as? [String] ?? []
        XCTAssertTrue(drawn.contains("😀中文😺"))
        XCTAssertTrue(drawn.contains("文😺 tailsec"))
        XCTAssertFalse(drawn.contains("A"))
        XCTAssertEqual(result?["painted"] as? Int, 3)
        XCTAssertEqual(result?["cleared"] as? Int, 0)
        XCTAssertEqual(result?["remaining"] as? Int, 0)
        XCTAssertEqual(result?["unchanged"] as? Bool, true)
        XCTAssertEqual(result?["sameLayout"] as? Bool, true)
        let selection = result?["selection"] as? [String: Any]
        XCTAssertEqual(selection?["start_selector"] as? String, "p[1]")
        XCTAssertEqual(selection?["end_selector"] as? String, "p[1]/strong[1]")
        XCTAssertEqual(selection?["end_offset"] as? Int, 2)
    }

    func testElementEndAtNextParagraphIsClampedToSelectedText() async throws {
        let fixture = try await load("<p>one 😀</p><p>two</p>")
        let result = try await fixture.run("""
            const paragraphs=document.querySelectorAll('#reader-content p');
            const range=document.createRange();
            range.setStart(paragraphs[0].firstChild,4); range.setEnd(paragraphs[1],0);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            return window.__readerAnnotations.selection();
            """) as? [String: Any]
        XCTAssertEqual(result?["start_selector"] as? String, "p[1]")
        XCTAssertEqual(result?["start_offset"] as? Int, 4)
        XCTAssertEqual(result?["end_selector"] as? String, "p[1]")
        XCTAssertEqual(result?["end_offset"] as? Int, 5)
        XCTAssertEqual(result?["text"] as? String, "😀")
    }

    func testSelectionRejectsOutsideArticleCollapsedAndScriptNodes() async throws {
        let fixture = try await load("<p>article</p><script>source</script><style>body{color:red}</style>")
        let result = try await fixture.run("""
            const root=document.getElementById('reader-content');
            // WebKit removes parsed scripts when source JavaScript is disabled.
            const inert=document.createElement('script'); inert.type='application/json';
            inert.textContent='source'; root.appendChild(inert);
            const select=node=>{ const range=document.createRange(); range.selectNodeContents(node);
                getSelection().removeAllRanges(); getSelection().addRange(range);
                return window.__readerAnnotations?.selection() || null; };
            const outside=select(document.getElementById('outside'));
            const script=select(root.querySelector('script'));
            const style=select(root.querySelector('style'));
            getSelection().collapse(root.querySelector('p').firstChild,2);
            return {outside:outside===null,script:script===null,style:style===null,
                    collapsed:window.__readerAnnotations?.selection() === null};
            """) as? [String: Any]
        for key in ["outside", "script", "style", "collapsed"] { XCTAssertEqual(result?[key] as? Bool, true) }
    }

    func testIsolatedBridgePostsSelectionAndTapWhileArticleScriptsStayDisabled() async throws {
        let selected = expectation(description: "Selection reaches native handler")
        let tapped = expectation(description: "Highlight tap reaches native handler")
        let cleared = expectation(description: "Cleared selection reaches native handler")
        let fixture = try await load("<script>document.body.dataset.sourceRan='yes'</script><p>Hello 😀 world</p>")
        fixture.messages.onMessage = { name, body in
            if name == "annotationSelection", let selection = body as? [String: Any], selection["text"] as? String == "Hello" { selected.fulfill() }
            if name == "annotationTap", (body as? [String: Any])?["id"] as? String == "one" { tapped.fulfill() }
            if name == "annotationSelection", body is NSNull { cleared.fulfill() }
        }
        let result = try await fixture.run("""
            const p=document.querySelector('#reader-content p');
            const range=document.createRange(); range.setStart(p.firstChild,0); range.setEnd(p.firstChild,5);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            await new Promise(resolve=>setTimeout(resolve,20));
            window.__readerAnnotations?.render([{id:'one',start_selector:'p[1]',start_offset:0,end_selector:'p[1]',end_offset:5,color:'green'}]);
            getSelection().removeAllRanges();
            const rect=range.getClientRects()[0];
            p.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:rect.x+rect.width/2,clientY:rect.y+rect.height/2}));
            return document.body.dataset.sourceRan || 'no';
            """)
        XCTAssertEqual(result as? String, "no")
        await fulfillment(of: [selected, tapped, cleared], timeout: 5)
        let pageWorld = try await fixture.webView.callAsyncJavaScript("return typeof window.__readerAnnotations", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(pageWorld as? String, "undefined")
    }

    func testSelectionHasVisibleAnchorAndRevealDoesNotMutateServerPaths() async throws {
        let fixture = try await load("<p>中文 selection context</p><p>next paragraph</p>")
        let result = try await fixture.run("""
            const p=document.querySelector('#reader-content p');
            const before=document.getElementById('reader-content').innerHTML;
            const range=document.createRange();range.setStart(p.firstChild,0);range.setEnd(p.firstChild,2);
            getSelection().removeAllRanges();getSelection().addRange(range);
            const selection=window.__readerAnnotations.selection();
            window.__readerAnnotations.render([{id:'one',start_selector:'p[1]',start_offset:0,end_selector:'p[1]',end_offset:2,color:'yellow'}]);
            const revealed=window.__readerAnnotations.reveal?.('one') || false;
            return {anchor:selection.anchor || null,revealed,unchanged:before===document.getElementById('reader-content').innerHTML};
            """) as? [String: Any]
        let anchor = try XCTUnwrap(result?["anchor"] as? [String: Any])
        XCTAssertGreaterThan(anchor["width"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(anchor["height"] as? Double ?? 0, 0)
        XCTAssertEqual(result?["revealed"] as? Bool, true)
        XCTAssertEqual(result?["unchanged"] as? Bool, true)
    }


    func testSelectionPaintIsClippedToTextAcrossParagraphsAndClearsWithoutChangingDOM() async throws {
        let fixture = try await load("<p>开头的一段文字，用于测试选区边界。</p><p>第二段<strong>包含强调文字</strong>和末尾内容。</p><p>第三段结束。</p>")
        let result = try await fixture.run("""
            const root=document.getElementById('reader-content');
            root.style.cssText='box-sizing:border-box;width:300px;margin:0 auto;padding:0 28px;font:18px/2 sans-serif';
            root.querySelectorAll('p').forEach(p=>p.style.margin='0 0 45px');
            const before=root.innerHTML;
            const paragraphs=root.querySelectorAll('p');
            const range=document.createRange();
            range.setStart(paragraphs[0].firstChild,3);range.setEnd(paragraphs[2].firstChild,3);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('pointerdown'));
            document.dispatchEvent(new Event('selectionchange'));
            const paint=CSS.highlights.get('reader-selection');
            const ranges=Array.from(paint || []);
            const textOnly=ranges.every(r=>r.startContainer===r.endContainer && r.startContainer.nodeType===Node.TEXT_NODE);
            const content=root.getBoundingClientRect();
            const rects=ranges.flatMap(r=>Array.from(r.getClientRects()));
            const clipped=rects.every(r=>r.left>=content.left+27 && r.right<=content.right-27);
            const nativeColor=getComputedStyle(paragraphs[0],'::selection').backgroundColor;
            const text=range.toString();
            const nativeCopy=getSelection().toString();
            const joined=ranges.map(r=>r.toString()).join('');
            const geometry=window.__readerAnnotations.selection();
            getSelection().collapse(paragraphs[0].firstChild,0);
            document.dispatchEvent(new Event('selectionchange'));
            return {painted:ranges.length,textOnly,clipped,nativeColor,text,joined,nativeCopy,
                cleared:!CSS.highlights.has('reader-selection'),unchanged:root.innerHTML===before,anchor:geometry.anchor};
            """) as? [String: Any]
        XCTAssertGreaterThan(result?["painted"] as? Int ?? 0, 2)
        XCTAssertEqual(result?["textOnly"] as? Bool, true)
        XCTAssertEqual(result?["clipped"] as? Bool, true)
        XCTAssertEqual(result?["nativeColor"] as? String, "rgba(0, 0, 0, 0)")
        XCTAssertEqual(result?["text"] as? String, result?["joined"] as? String)
        XCTAssertTrue((result?["nativeCopy"] as? String ?? "").contains("第二段包含强调文字"))
        XCTAssertEqual(result?["cleared"] as? Bool, true)
        XCTAssertEqual(result?["unchanged"] as? Bool, true)
        XCTAssertNotNil(result?["anchor"])
    }


    func testSelectAllDocumentClampsPaintToArticleAndKeepsServerOffsets() async throws {
        let fixture = try await load("<p>正文😀</p><p>结尾</p>")
        let result = try await fixture.run("""
            const range=document.createRange();range.selectNodeContents(document.body);
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            const selected=window.__readerAnnotations.selection();
            return {selected,paint:Array.from(CSS.highlights.get('reader-selection') || []).map(r=>r.toString()).join('')};
            """) as? [String: Any]
        let selected = result?["selected"] as? [String: Any]
        XCTAssertEqual(selected?["start_selector"] as? String, "p[1]")
        XCTAssertEqual(selected?["end_selector"] as? String, "p[2]")
        XCTAssertEqual(selected?["end_offset"] as? Int, 2)
        XCTAssertEqual(result?["paint"] as? String, "正文😀结尾")
    }

    private func load(_ article: String) async throws -> AnnotationFixture {
        let loaded = expectation(description: "Annotation fixture loaded")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let messages = AnnotationMessageObserver()
        configuration.userContentController.add(messages, contentWorld: .defaultClient, name: "annotationSelection")
        configuration.userContentController.add(messages, contentWorld: .defaultClient, name: "annotationTap")
        configuration.userContentController.addUserScript(WKUserScript(source: AnnotationScript.bootstrap,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 400), configuration: configuration)
        let navigation = AnnotationLoadObserver { loaded.fulfill() }
        webView.navigationDelegate = navigation
        let fixture = AnnotationFixture(webView: webView, navigation: navigation, messages: messages)
        webView.loadHTMLString("<html><head><meta charset='utf-8'></head><body><main id='reader-content'>\(article)</main><p id='outside'>outside</p></body></html>", baseURL: URL(string: "about:blank"))
        await fulfillment(of: [loaded], timeout: 10)
        return fixture
    }
}

@MainActor
private final class AnnotationFixture {
    let webView: WKWebView
    let navigation: AnnotationLoadObserver
    let messages: AnnotationMessageObserver
    init(webView: WKWebView, navigation: AnnotationLoadObserver, messages: AnnotationMessageObserver) {
        self.webView = webView; self.navigation = navigation; self.messages = messages
    }
    func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }
}

@MainActor
private final class AnnotationLoadObserver: NSObject, WKNavigationDelegate {
    let onLoad: () -> Void
    init(onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad() }
}

@MainActor
private final class AnnotationMessageObserver: NSObject, WKScriptMessageHandler {
    var onMessage: ((String, Any) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message.name, message.body)
    }
}
