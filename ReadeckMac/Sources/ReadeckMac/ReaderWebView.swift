import AppKit
import SwiftUI
import WebKit

struct ReaderWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    let style: ReaderStyle
    let initialProgress: Int
    let onProgress: (Int) -> Void
    var annotations: [BookmarkAnnotation] = []
    var onSelection: (AnnotationSelection?) -> Void = { _ in }
    var onAnnotationTap: (String) -> Void = { _ in }
    var onSelectionAction: (AnnotationSelection, ReaderSelectionAction) -> Void = { _, _ in }
    var revealRequest: AnnotationRevealRequest?
    var selectionResetID: UUID?
    var navigationRequest: ReaderNavigationRequest?
    var onOutline: ([ReaderHeading]) -> Void = { _ in }
    var onCurrentHeading: (Int?) -> Void = { _ in }
    var onFindState: (ReaderFindState) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ReaderContainerView {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let script = """
        (() => {
          let lastGesture = 0;
          let timer;
          const markGesture = () => { lastGesture = Date.now(); };
          const send = () => {
            if (window.__readerAdjusting || Date.now() - lastGesture > 1800) return;
            const max = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            window.webkit.messageHandlers.progress.postMessage(Math.min(100, Math.max(0, Math.round(window.scrollY / max * 100))));
          };
          window.addEventListener('wheel', markGesture, {passive:true});
          window.addEventListener('pointerdown', markGesture, {passive:true});
          window.addEventListener('pointermove', e => { if(e.buttons) markGesture(); }, {passive:true});
          window.addEventListener('keydown', e => {
            if(['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(e.key)) markGesture();
          });
          window.addEventListener('scroll', () => {
            if(window.__readerAdjusting || Date.now()-lastGesture>1800) return;
            clearTimeout(timer); timer=setTimeout(send,800);
          }, {passive:true});
        })();
        """
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "readerOutline")
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "progress")
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "annotationSelection")
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "annotationTap")
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "annotationContext")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: AnnotationScript.bootstrap, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: ReaderNavigationScript.bootstrap, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        let container = ReaderContainerView(webView: webView)
        context.coordinator.webView = webView
        context.coordinator.trackPointer(in: webView)
        context.coordinator.load(html: html, baseURL: baseURL, style: style, in: webView)
        return container
    }

    func updateNSView(_ container: ReaderContainerView, context: Context) {
        let webView = container.webView
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.currentHTML != html {
            coordinator.load(html: html, baseURL: baseURL, style: style, in: webView)
        } else {
            coordinator.updateStyle(style, in: webView)
            coordinator.updateAnnotations(annotations, in: webView)
            coordinator.updateInteraction(in: webView)
            coordinator.updateNavigation(in: webView)
        }
    }

    static func dismantleNSView(_ container: ReaderContainerView, coordinator: Coordinator) {
        let view = container.webView
        coordinator.styleTask?.cancel()
        coordinator.annotationTask?.cancel()
        coordinator.navigationTask?.cancel()
        coordinator.pendingReport?.cancel()
        coordinator.invalidateNavigation()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "readerOutline", contentWorld: .defaultClient)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "progress", contentWorld: .defaultClient)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "annotationSelection", contentWorld: .defaultClient)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "annotationTap", contentWorld: .defaultClient)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "annotationContext", contentWorld: .defaultClient)
        coordinator.selectionPopover?.close()
        if let monitor = coordinator.pointerMonitor { NSEvent.removeMonitor(monitor); coordinator.pointerMonitor = nil }
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReaderWebView
        weak var webView: WKWebView?
        var selectionPopover: SelectionToolbarPanel?
        var pointerMonitor: Any?
        private var pointerRelease: (point: NSPoint, time: TimeInterval)?
        private var suppressedSelection: AnnotationSelection?
        private var menuSelection: AnnotationSelection?
        private var lastReveal: UUID?
        private var lastSelectionReset: UUID?
        var currentHTML = ""
        var currentStyle: ReaderStyle?
        private var requestedStyle: ReaderStyle?
        var styleTask: Task<Void, Never>?
        var annotationTask: Task<Void, Never>?
        var navigationTask: Task<Void, Never>?
        private var lastNavigationRequest: UUID?
        private var requestedAnnotations: [BookmarkAnnotation]?
        private var documentReady = false
        private weak var reflowController: WKUserContentController?
        var pendingReport: DispatchWorkItem?
        private var progress: ReaderProgressAccumulator
        private var documentID = UUID().uuidString
        private var styleRevision = 0

        init(_ parent: ReaderWebView) {
            self.parent = parent
            progress = ReaderProgressAccumulator(initial: parent.initialProgress)
        }

        func trackPointer(in webView: WKWebView) {
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseDown, .keyDown]) { [weak self, weak webView] event in
                guard let self, let webView, let window = webView.window, event.window === window else { return event }
                if event.type == .keyDown { self.pointerRelease = nil }
                else {
                    let point = window.convertPoint(toScreen: event.locationInWindow)
                    let viewport = window.convertToScreen(webView.convert(webView.bounds, to: nil))
                    self.pointerRelease = viewport.contains(point) ? (point, ProcessInfo.processInfo.systemUptime) : nil
                }
                return event
            }
        }

        func load(html: String, baseURL: URL, style: ReaderStyle, in webView: WKWebView) {
            selectionPopover?.close()
            suppressedSelection = nil
            styleTask?.cancel()
            annotationTask?.cancel()
            navigationTask?.cancel()
            lastNavigationRequest = nil
            requestedAnnotations = nil
            documentReady = false
            pendingReport?.cancel()
            pendingReport = nil
            progress = ReaderProgressAccumulator(initial: parent.initialProgress)
            currentHTML = html
            currentStyle = style
            requestedStyle = style
            documentID = UUID().uuidString
            let controller = webView.configuration.userContentController
            if reflowController !== controller {
                controller.addUserScript(WKUserScript(source: ReaderReflow.bootstrap, injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true, in: .defaultClient))
                reflowController = controller
            }
            let document = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file: http: https:; style-src 'unsafe-inline'; script-src 'none';">
            <style id="reader-style">\(style.css)</style></head>
            <body data-reader-document="\(documentID)" data-reader-unified="\(style.unifiedLayout)"><main id="reader-content">\(html)</main></body></html>
            """
            webView.loadHTMLString(document, baseURL: baseURL)
        }

        func updateStyle(_ style: ReaderStyle, in webView: WKWebView) {
            guard requestedStyle != style else { return }
            requestedStyle = style
            selectionPopover?.close()
            styleTask?.cancel()
            styleTask = Task { @MainActor in
                guard !Task.isCancelled, requestedStyle == style else { return }
                try? await applyStyle(style, in: webView)
            }
        }

        func updateAnnotations(_ items: [BookmarkAnnotation], in webView: WKWebView) {
            guard requestedAnnotations != items else { return }
            requestedAnnotations = items
            guard documentReady else { return }
            annotationTask?.cancel()
            let identity = documentID
            annotationTask = Task { @MainActor in
                guard !Task.isCancelled, requestedAnnotations == items else { return }
                do {
                    let data = try JSONEncoder().encode(items)
                    let json = String(decoding: data, as: UTF8.self)
                    let rendered = try await webView.callAsyncJavaScript("""
                        if(document.body.dataset.readerDocument!==documentID || !window.__readerAnnotations) return false;
                        window.__readerAnnotations.render(JSON.parse(items)); return true;
                        """, arguments: ["items": json, "documentID": identity], in: nil, contentWorld: .defaultClient)
                    if rendered as? Bool != true, identity == documentID, requestedAnnotations == items {
                        requestedAnnotations = nil
                    }
                } catch {
                    if identity == documentID, requestedAnnotations == items { requestedAnnotations = nil }
                }
            }
        }

        func applyStyle(_ style: ReaderStyle, in webView: WKWebView) async throws {
            styleRevision += 1
            let revision = styleRevision
            let result = try await webView.callAsyncJavaScript("""
                if(document.body.dataset.readerDocument!==documentID || !document.getElementById('reader-style')) return false;
                if((window.__readerStyleRevision || 0)>revision) return false;
                window.__readerStyleRevision=revision;
                window.__readerAdjusting=true;
                const layoutChange=window.__readerReflow?.beginStyleChange();
                const nodes=Array.from(document.querySelectorAll('#reader-content p,#reader-content li,#reader-content h1,#reader-content h2,#reader-content h3'));
                const anchor=nodes.find(node=>node.getBoundingClientRect().bottom>0);
                const offset=anchor ? anchor.getBoundingClientRect().top : 0;
                document.getElementById('reader-style').textContent=css;
                window.__readerReflow?.setEnabled(unified);
                await new Promise(resolve=>{ requestAnimationFrame(resolve); setTimeout(resolve,50); });
                if(window.__readerStyleRevision!==revision) return false;
                if(layoutChange) window.__readerReflow.finishStyleChange(layoutChange);
                else if(anchor) window.scrollBy(0,anchor.getBoundingClientRect().top-offset);
                setTimeout(()=>{ if(window.__readerStyleRevision===revision) window.__readerAdjusting=false; },20);
                return true;
                """, arguments: ["css": style.css, "unified": style.unifiedLayout, "documentID": documentID, "revision": revision],
                in: nil, contentWorld: .defaultClient)
            if result as? Bool == true, !Task.isCancelled, revision == styleRevision { currentStyle = style }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Annotation initialization must survive cancellation of typography updates.
            documentReady = true
            requestedAnnotations = nil
            updateAnnotations(parent.annotations, in: webView)
            styleTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                try? await applyStyle(parent.style, in: webView)
                guard !Task.isCancelled else { return }
                let restored = min(max(parent.initialProgress, 0), 100)
                if restored > 0 {
                    _ = try? await webView.callAsyncJavaScript("window.scrollTo(0,(document.documentElement.scrollHeight-window.innerHeight)*progress/100);window.__readerReflow?.capturePosition();return true",
                                                               arguments: ["progress": restored], in: nil, contentWorld: .defaultClient)
                }
                guard !Task.isCancelled else { return }
                updateNavigation(in: webView, force: true)
            }
        }

        func invalidateNavigation() {
            documentReady = false
            documentID = UUID().uuidString
        }

        func updateNavigation(in webView: WKWebView, force: Bool = false) {
            guard documentReady, force || parent.navigationRequest?.id != lastNavigationRequest else { return }
            let request = parent.navigationRequest
            lastNavigationRequest = request?.id
            let owner = documentID
            navigationTask?.cancel()
            navigationTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let raw = try await webView.callAsyncJavaScript("""
                        if(document.body.dataset.readerDocument!==owner) return null;
                        return window.__readerNavigation?.outline() ?? [];
                        """, arguments: ["owner": owner], in: nil, contentWorld: .defaultClient)
                    try Task.checkCancellation()
                    guard owner == documentID, let raw else { return }
                    let outline = try JSONDecoder().decode([ReaderHeading].self, from: JSONSerialization.data(withJSONObject: raw))
                    parent.onOutline(outline)
                    let active = try await webView.callAsyncJavaScript("return window.__readerNavigation?.currentHeading() ?? null", arguments: [:], in: nil, contentWorld: .defaultClient)
                    try Task.checkCancellation()
                    guard owner == documentID else { return }
                    parent.onCurrentHeading((active as? NSNumber)?.intValue)
                    guard let request else { return }
                    switch request.action {
                    case let .find(query, step):
                        let raw = try await webView.callAsyncJavaScript("""
                            if(document.body.dataset.readerDocument!==owner) return null;
                            return window.__readerNavigation?.find(query, step) ?? {count:0,current:0};
                            """, arguments: ["owner": owner, "query": query, "step": step], in: nil, contentWorld: .defaultClient)
                        try Task.checkCancellation()
                        guard owner == documentID, parent.navigationRequest?.id == request.id, let raw else { return }
                        parent.onFindState(try JSONDecoder().decode(ReaderFindState.self, from: JSONSerialization.data(withJSONObject: raw)))
                    case let .heading(index):
                        _ = try await webView.callAsyncJavaScript("""
                            if(document.body.dataset.readerDocument!==owner) return false;
                            return window.__readerNavigation?.revealHeading(index) ?? false;
                            """, arguments: ["owner": owner, "index": index], in: nil, contentWorld: .defaultClient)
                        try Task.checkCancellation()
                        guard owner == documentID, parent.navigationRequest?.id == request.id else { return }
                        if let value = try await webView.callAsyncJavaScript("return Math.round(window.scrollY/Math.max(1,document.documentElement.scrollHeight-window.innerHeight)*100)", arguments: [:], in: nil, contentWorld: .defaultClient) as? NSNumber {
                            guard !Task.isCancelled, owner == documentID else { return }
                            parent.onProgress(min(100, max(0, value.intValue)))
                        }
                    }
                } catch { /* Cancelled or replaced documents cannot update navigation UI. */ }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.fragment != nil, url.deletingLastPathComponent() == parent.baseURL.deletingLastPathComponent() {
                    decisionHandler(.allow)
                } else {
                    if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                    decisionHandler(.cancel)
                }
            } else { decisionHandler(.allow) }
        }

        func updateInteraction(in webView: WKWebView) {
            guard documentReady else { return }
            if lastSelectionReset != parent.selectionResetID {
                lastSelectionReset = parent.selectionResetID
                selectionPopover?.close()
                Task { @MainActor in
                    _ = try? await webView.callAsyncJavaScript("getSelection().removeAllRanges()", arguments: [:], in: nil, contentWorld: .defaultClient)
                }
            }
            if let request = parent.revealRequest, lastReveal != request.token {
                lastReveal = request.token
                selectionPopover?.close()
                Task { @MainActor in
                    _ = try? await webView.callAsyncJavaScript("return window.__readerAnnotations?.reveal(id)", arguments: ["id": request.annotationID], in: nil, contentWorld: .defaultClient)
                }
            }
        }

        private func takeAction(_ selection: AnnotationSelection, _ action: ReaderSelectionAction) {
            suppressedSelection = selection
            selectionPopover?.close()
            parent.onSelectionAction(selection, action)
        }

        private func showSelection(_ selected: AnnotationSelection, screenRect: NSRect, side: String?, in webView: WKWebView) {
            selectionPopover?.close()
            guard let window = webView.window else { return }
            let viewport = window.convertToScreen(webView.convert(webView.bounds, to: nil))
            let above = viewport.maxY - screenRect.maxY
            let below = screenRect.minY - viewport.minY
            let preferBelow = side == "below" ? below >= 70 || above < 70 : above < 70 && below >= 70
            let content = NSHostingController(rootView: SelectionToolbarView { [weak self] action in
                self?.takeAction(selected, action)
            })
            selectionPopover = SelectionToolbarPanel(parent: window, anchor: screenRect, viewport: viewport,
                                                      preferBelow: preferBelow, content: content)
        }

        private func showContextMenu(_ selected: AnnotationSelection, rect: NSRect, in webView: WKWebView) {
            selectionPopover?.close()
            suppressedSelection = selected
            menuSelection = selected
            let menu = NSMenu()
            for item in AnnotationColorPicker.colors {
                let entry = NSMenuItem(title: AppLanguage.text("\(item.1)划线"), action: #selector(menuHighlight(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = item.0
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let note = NSMenuItem(title: NSLocalizedString("写批注", comment: ""), action: #selector(menuNote), keyEquivalent: "")
            note.target = self; menu.addItem(note)
            let copy = NSMenuItem(title: NSLocalizedString("复制", comment: ""), action: #selector(menuCopy), keyEquivalent: "")
            copy.target = self; menu.addItem(copy)
            menu.popUp(positioning: nil, at: rect.origin, in: webView)
        }
        @objc private func menuHighlight(_ sender: NSMenuItem) {
            if let selection = menuSelection, let color = sender.representedObject as? String { takeAction(selection, .highlight(color)) }
        }
        @objc private func menuNote() { if let selection = menuSelection { takeAction(selection, .note) } }
        @objc private func menuCopy() { if let selection = menuSelection { takeAction(selection, .copy) } }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "readerOutline" {
                guard documentReady, message.frameInfo.isMainFrame,
                      let body = message.body as? [String: Any], body["documentID"] as? String == documentID,
                      let raw = body["headings"], let data = try? JSONSerialization.data(withJSONObject: raw),
                      let headings = try? JSONDecoder().decode([ReaderHeading].self, from: data) else { return }
                let current = (body["current"] as? NSNumber)?.intValue
                parent.onOutline(headings)
                parent.onCurrentHeading(current.flatMap { index in headings.contains(where: { $0.index == index }) ? index : nil })
                return
            }
            if message.name == "annotationSelection" || message.name == "annotationContext" {
                guard let body = message.body as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: body),
                      let selected = try? JSONDecoder().decode(AnnotationSelection.self, from: data) else {
                    selectionPopover?.close()
                    parent.onSelection(nil)
                    suppressedSelection = nil
                    return
                }
                parent.onSelection(selected)
                guard let anchorBody = body["anchor"] as? [String: Any],
                      let anchorData = try? JSONSerialization.data(withJSONObject: anchorBody),
                      let anchor = try? JSONDecoder().decode(SelectionAnchor.self, from: anchorData),
                      let webView, let window = webView.window else { selectionPopover?.close(); return }
                let viewport = window.convertToScreen(webView.convert(webView.bounds, to: nil))
                let pointer = pointerRelease.flatMap { ProcessInfo.processInfo.systemUptime-$0.time < 1.5 ? $0.point : nil }
                guard let screenRect = anchor.screenRect(in: viewport, pointer: pointer) else { selectionPopover?.close(); return }
                if message.name == "annotationContext" {
                    // Context menus use the same native screen reference as the toolbar.
                    let point = webView.convert(window.convertPoint(fromScreen: screenRect.origin), from: nil)
                    showContextMenu(selected, rect: NSRect(origin: point, size: screenRect.size), in: webView)
                } else if suppressedSelection != selected {
                    showSelection(selected, screenRect: screenRect, side: anchor.preferredSide, in: webView)
                }
                return
            }
            if message.name == "annotationTap" {
                if let body = message.body as? [String: Any], let id = body["id"] as? String { parent.onAnnotationTap(id) }
                return
            }
            guard let value = message.body as? Int else { return }
            progress.record(value)
            pendingReport?.cancel()
            let report = DispatchWorkItem { [weak self] in
                guard let self, let value = self.progress.flush() else { return }
                self.parent.onProgress(value)
            }
            pendingReport = report
            DispatchQueue.main.asyncAfter(deadline: .now()+0.5, execute: report)
        }
    }
}
