import AppKit
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class WechatReadinessDiagnosticsTests: XCTestCase {
    func testPublicPageReadinessMutationCounts() async throws {
        guard ProcessInfo.processInfo.environment["READECK_WECHAT_DIAGNOSTICS"] == "1" else { throw XCTSkip("Read-only public page diagnostics are opt-in") }
        _ = NSApplication.shared
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 840, height: 620), configuration: config)
        let observer = DiagnosticNavigation()
        web.navigationDelegate = observer
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        for slug in ["RazPke1But77c6Z2yQrxoQ", "b5MLwlXYtcaTHourmrhkZw"] {
            observer.finished = false
            web.load(URLRequest(url: URL(string: "https://mp.weixin.qq.com/s/" + slug)!, timeoutInterval: 30))
            var hasRoot = false
            for _ in 0..<300 {
                if let value = try? await web.callAsyncJavaScript("return !!document.querySelector('#js_content')", arguments: [:], in: nil, contentWorld: .defaultClient),
                   (value as? Bool) == true { hasRoot = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard hasRoot else { XCTFail("Article root did not appear within 30 seconds"); continue }
            let script = """
                const root=document.querySelector('#js_content');
                if(!root)return {error:'missing article root'};
                const counts={};
                const watch=new MutationObserver(changes=>{for(const m of changes){
                  const name=m.type==='attributes'?m.attributeName:m.type;
                  counts[name]=(counts[name]||0)+1;
                }});
                watch.observe(root,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['src','srcset','data-src','style','class']});
                try { await (async()=>{
                """ + WechatCaptureReadiness.script + """
                })();
                const summary=JSON.parse(root.getAttribute('data-readeck-readiness')||'{}');
                return {counts,summary,images:root.querySelectorAll('img').length};
                } finally {watch.disconnect();}
                """
            let result = try await web.callAsyncJavaScript(script, arguments: ["normalized": "", "readinessOptions": ["stableMS": 800, "maximumMS": 10000]], in: nil, contentWorld: .defaultClient)
            print("WECHAT_READINESS_DIAGNOSTIC", slug, result ?? "no result")
        }
    }
}

@MainActor
private final class DiagnosticNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = true }
}
