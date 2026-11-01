import AppKit
import WebKit

/// This is the only view that executes source scripts. No NAS credentials enter it.
@MainActor
final class ArticleCaptureSession: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let web: WKWebView
    private let window: NSWindow
    private let status = NSTextField(labelWithString: "正在加载正文和图片…")
    private var continuation: CheckedContinuation<Data, Error>?
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var extracting = false
    private var source: CaptureSourceURL?
    var onInteraction: (() -> Void)?
    var onProgress: ((CaptureResourceReport) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 840, height: 620), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        web.navigationDelegate = self
        window.delegate = self; window.isReleasedWhenClosed = false
        window.title = "微信文章采集"
        let resume = NSButton(title: "完成验证，继续采集", target: self, action: #selector(resumeCapture))
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelCapture))
        let buttons = NSStackView(views: [status, resume, cancel]); buttons.spacing = 12
        let stack = NSStackView(views: [web, buttons]); stack.orientation = .vertical; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        window.contentView = stack
        web.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        buttons.heightAnchor.constraint(equalToConstant: 28).isActive = true
        window.center()
    }

    func capture(_ source: CaptureSourceURL, interactive: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let initialURL = try await BilibiliLegacyResolver.resolve(source)
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.source = source
                self.window.title = source.site.title + "采集"
                if interactive { self.show() }
                web.load(URLRequest(url: initialURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45))
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(.failure(WechatParseError.parseError("采集等待超时，可从任务中重新采集。")))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }

    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func resumeCapture() { extract() }
    @objc private func cancelCapture() { finish(.failure(CancellationError())) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelCapture(); return true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { extract() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false {
            guard source?.allowsNavigation(to: url) == true else { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }

    private func extract() {
        guard continuation != nil, !extracting else { return }
        extracting = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.extracting = false }
            do {
                if let source = self.source, source.site != .wechat {
                    let data = try await SiteCaptureAdapter.capture(web: self.web, source: source, progress: self.onProgress)
                    try Task.checkCancellation()
                    self.finish(.success(data)); return
                }
                let template = try await self.web.callAsyncJavaScript(Self.templateScript, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                var normalized = ""
                if let template, let type = template["type"] as? Int, [8, 10].contains(type) {
                    normalized = try WechatTemplateAdapter.html(type: type, html: template["html"] as? String ?? "",
                        text: template["text"] as? String ?? "", pictures: template["pictures"] as? [String] ?? [])
                }
                var previousReport: CaptureResourceReport?
                let data = try await WechatCaptureRecovery.run { round in
                    if round > 0 {
                        _ = try await self.web.callAsyncJavaScript(WechatCaptureRecovery.retryScript, arguments: ["ids": previousReport?.issues.compactMap(\.nodeID) ?? []], in: nil, contentWorld: .defaultClient)
                    }
                    let found = try await self.web.callAsyncJavaScript(Self.prepareScript, arguments: ["normalized": round == 0 ? normalized : "", "captureAttempt": round + 1], in: nil, contentWorld: .defaultClient) as? Bool ?? false
                    try Task.checkCancellation()
                    guard found else { throw WechatParseError.interactionRequired }
                    // Some WeChat templates publish the cover in page state instead of OG metadata.
                    _ = try? await self.web.callAsyncJavaScript(Self.coverMetadataScript, arguments: [:], in: nil, contentWorld: .page)
                    // Optional preview image: failure must never block body capture.
                    _ = try? await self.web.callAsyncJavaScript(Self.coverProbeScript, arguments: [:], in: nil, contentWorld: .defaultClient)
                    let archive: Data = try await withCheckedThrowingContinuation { continuation in
                        self.web.createWebArchiveData { continuation.resume(with: $0) }
                    }
                    let source = try CaptureSourceURL(self.web.url?.absoluteString ?? "")
                    let report = try await Task.detached {
                        try WechatArticleParser.extract(archive: archive, source: source, packageID: "probe").resourceReport
                    }.value
                    previousReport = report
                    if let report { self.onProgress?(report) }
                    return (archive, report)
                }
                try Task.checkCancellation()
                self.finish(.success(data))
            } catch WechatParseError.interactionRequired {
                guard self.continuation != nil else { return }
                self.status.stringValue = "请完成网页验证后继续；暂不支持的文章可取消。"
                self.onInteraction?(); self.show()
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); operation?.cancel()
        web.callAsyncJavaScript("globalThis.__readeckCaptureAbort=true;", arguments: [:], in: nil, in: .defaultClient, completionHandler: { _ in })
        web.stopLoading(); window.orderOut(nil)
        continuation.resume(with: result)
    }

    static let prepareScript = WechatCaptureReadiness.script

    private static let coverMetadataScript = #"""
    if(document.querySelector('meta[property="og:image"]')?.content)return true;
    const candidate=typeof msg_cdn_url==='string'?msg_cdn_url:'';
    let url;try{url=new URL(candidate,document.baseURI)}catch{return false}
    if(url.protocol!=='https:' || !['mmbiz.qpic.cn','mmbiz.qlogo.cn'].includes(url.hostname.toLowerCase()) || url.username || url.password)return false;
    const meta=document.createElement('meta');meta.setAttribute('property','og:image');meta.content=url.href;document.head.append(meta);return true;
    """#

    private static let coverProbeScript = #"""
    const src=document.querySelector('meta[property="og:image"]')?.content || document.querySelector('meta[name="twitter:image"]')?.content;
    if(!src)return false;
    let url;try{url=new URL(src,document.baseURI)}catch{return false}
    if(url.protocol!=='https:' || !['mmbiz.qpic.cn','mmbiz.qlogo.cn'].includes(url.hostname.toLowerCase()) || url.username || url.password)return false;
    let img=document.getElementById('readeck-optional-cover');
    if(!img){img=document.createElement('img');img.id='readeck-optional-cover';img.style.cssText='position:fixed;left:-10000px;width:1px;height:1px';document.body.appendChild(img);img.src=url.href;}
    if(!img.complete)await new Promise(resolve=>{const timer=setTimeout(resolve,2000);img.addEventListener('load',()=>{clearTimeout(timer);resolve()},{once:true});img.addEventListener('error',()=>{clearTimeout(timer);resolve()},{once:true})});
    return img.complete && img.naturalWidth>0;
    """#

    private static let templateScript = #"""
    const d=window.cgiDataNew;
    if(!d || ![8,10].includes(Number(d.item_show_type))) return null;
    if(String(d.content_noencode||'').length>8000000 || String(d.text_page_info?.content_noencode||'').length>8000000) throw new Error('正文超过大小上限');
    return {type:Number(d.item_show_type), html:String(d.content_noencode||''),
      text:String(d.text_page_info?.content_noencode||''),
      pictures:(Array.isArray(d.picture_page_info_list)?d.picture_page_info_list:[]).slice(0,101).map(i=>String(i.cdn_url||''))};
    """#
}

// Compatibility for existing WeChat capture tests and scripts.
typealias WechatCaptureSession = ArticleCaptureSession
