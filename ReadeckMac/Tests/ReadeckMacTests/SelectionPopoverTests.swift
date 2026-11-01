import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class SelectionPopoverTests: XCTestCase {
    func testOptionalActualArticleGeometry() async throws {
        guard let path = ProcessInfo.processInfo.environment["READECK_SELECTION_FIXTURE"],
              let phrase = ProcessInfo.processInfo.environment["READECK_SELECTION_PHRASE"], !phrase.isEmpty else { throw XCTSkip("opt-in fixture") }
        _ = NSApplication.shared
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let reader = ReaderWebView(html: html, baseURL: URL(string: "about:blank")!, style: .standard, initialProgress: 0, onProgress: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HStack(spacing: 0) { Text("目录").frame(width: 230); reader })
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func find(_ view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap(find).first }
        var web: WKWebView?
        for _ in 0..<300 { web = window.contentView.flatMap(find); if let w = web, !w.isLoading, w.url != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        let w = try XCTUnwrap(web)
        let coordinator = try XCTUnwrap(w.navigationDelegate as? ReaderWebView.Coordinator)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await w.callAsyncJavaScript("""
            const p=[...document.querySelectorAll('#reader-content p')].find(p=>p.textContent.includes(phrase));
            const walker=document.createTreeWalker(p,NodeFilter.SHOW_TEXT);let node;while(walker.nextNode()){if(walker.currentNode.data.includes(phrase)){node=walker.currentNode;break;}}
            const start=Math.max(0,node.data.indexOf(phrase)-5), range=document.createRange();
            range.setStart(node,start);range.setEnd(node,node.length);
            p.scrollIntoView({block:'center'});await new Promise(r=>setTimeout(r,100));
            getSelection().removeAllRanges();getSelection().addRange(range);
            const end=[...range.getClientRects()].at(-1);
            document.dispatchEvent(new MouseEvent('pointerdown',{bubbles:true}));
            document.dispatchEvent(new MouseEvent('pointerup',{bubbles:true,clientX:end.right-1,clientY:end.top+end.height/2}));
            """, arguments: ["phrase": phrase], in: nil, contentWorld: .defaultClient)
        for _ in 0..<100 {
            if coordinator.selectionPopover?.isShown == true {
                try await Task.sleep(for: .milliseconds(500))
                let value = try await w.callAsyncJavaScript("""
                    const s=getSelection(),a=window.__readerAnnotations.selection().anchor,r=s.getRangeAt(0), boxes=[...r.getClientRects()];
                    return {a, start:boxes[0]?.toJSON(), end:boxes.at(-1)?.toJSON(), viewport:[innerWidth,innerHeight]};
                    """, arguments: [:], in: nil, contentWorld: .defaultClient)
                let result = try XCTUnwrap(value as? [String: Any])
                let anchorData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(result["a"]))
                let geometry = try JSONDecoder().decode(SelectionAnchor.self, from: anchorData)
                let viewport = window.convertToScreen(w.convert(w.bounds, to: nil))
                let anchorScreen = try XCTUnwrap(geometry.screenRect(in: viewport, pointer: nil))
                let popup = try XCTUnwrap(coordinator.selectionPopover?.contentViewController?.view.window?.frame)
                let gap = max(anchorScreen.minY-popup.maxY, popup.minY-anchorScreen.maxY, 0)
                XCTAssertLessThanOrEqual(gap, 24, "Popover must stay near the actual article selection after scrolling")
                return
            }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTFail("No interactive selection")
    }
    func testNativePopoverStaysBesideSelectedTextNearBottomOfReader() async throws {
        _ = NSApplication.shared
        let paragraph = String(repeating: "这是用于核对划线工具条位置的正文，选中文字后工具条应贴近选区。", count: 5)
        let html = (0..<20).map { "<p data-index='\($0)'>\(paragraph)</p>" }.joined()
        let reader = ReaderWebView(html: html, baseURL: URL(string: "about:blank")!, style: .standard, initialProgress: 0, onProgress: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Selection Position QA"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NavigationSplitView {
            Text("资料库").frame(minWidth: 200)
        } detail: {
            HStack(spacing: 0) { Text("目录").frame(width: 180); reader }.safeAreaInset(edge: .bottom) { Text("分类与标签").padding(12) }
                .toolbar { ToolbarItem(placement: .principal) { Text("阅读测试") } }
        })
        window.orderFront(nil)
        defer { window.close() }
        func find(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(find).first
        }
        var found: WKWebView?
        for _ in 0..<200 {
            found = window.contentView.flatMap(find)
            if let web = found, !web.isLoading, web.url != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let web = try XCTUnwrap(found)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? ReaderWebView.Coordinator)
        try await Task.sleep(for: .milliseconds(180))
        let geometry = try await web.callAsyncJavaScript("""
            const p=document.querySelectorAll('#reader-content p')[4];
            const text=p.firstChild;
            const range=document.createRange();range.setStart(text,0);range.setEnd(text,70);
            const start=range.getBoundingClientRect();
            scrollBy(0,start.top-innerHeight*0.72);
            await new Promise(resolve=>setTimeout(resolve,50));
            getSelection().removeAllRanges();getSelection().addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            const r=range.getClientRects()[0];
            return {x:r.x,y:r.y,width:r.width,height:r.height,viewportWidth:innerWidth,viewportHeight:innerHeight};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Double]
        let rect = try XCTUnwrap(geometry)
        for _ in 0..<100 {
            if coordinator.selectionPopover?.isShown == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let popover = try XCTUnwrap(coordinator.selectionPopover)
        let popoverWindow = try XCTUnwrap(popover.contentViewController?.view.window)
        let css = CGRect(x: rect["x"]!, y: rect["y"]!, width: rect["width"]!, height: rect["height"]!)
        // Derive screen coordinates from the rendered viewport, independently of SelectionAnchor.
        let viewRect = CGRect(x: css.minX, y: web.isFlipped ? css.minY : web.bounds.height-css.maxY, width: css.width, height: css.height)
        let viewportScreen = window.convertToScreen(web.convert(web.bounds, to: nil))
        let selectedScreen = CGRect(x: viewportScreen.minX+css.minX, y: viewportScreen.maxY-css.maxY, width: css.width, height: css.height)
        let gap = max(selectedScreen.minY-popoverWindow.frame.maxY, popoverWindow.frame.minY-selectedScreen.maxY, 0)
        print("SELECTION_POSITION css=\(css) viewportScreen=\(viewportScreen) viewRect=\(viewRect) flipped=\(web.isFlipped) viewport=\(rect["viewportHeight"]!) viewHeight=\(web.bounds.height) selection=\(selectedScreen) popup=\(popoverWindow.frame) gap=\(gap)")
        XCTAssertLessThanOrEqual(gap, 24, "Popover must stay close to the selected line")
        XCTAssertFalse(popoverWindow.frame.insetBy(dx: 8, dy: 12).intersects(selectedScreen), "Toolbar must not cover selected text")
        _ = try await web.callAsyncJavaScript("const value=window.__readerAnnotations.selection();value.anchor=null;window.webkit.messageHandlers.annotationSelection.postMessage(value);", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(coordinator.selectionPopover?.isShown == true, "Invalid/new geometry must dismiss an old toolbar")
        popover.close()
    }
}
