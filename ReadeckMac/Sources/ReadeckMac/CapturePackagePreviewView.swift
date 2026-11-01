import SwiftUI
import WebKit

struct CapturePackagePreviewView: View {
    let preview: CapturePackagePreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本机采集预览").font(.headline)
                    Text("仅供核对内容；NAS 验证完成后可在资料库阅读和批注。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            CapturePreviewWebView(preview: preview)
        }.frame(minWidth: 620, idealWidth: 780, minHeight: 480, idealHeight: 650)
    }
}

private struct CapturePreviewWebView: NSViewRepresentable {
    let preview: CapturePackagePreview
    func makeCoordinator() -> Coordinator { Coordinator(preview) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "readeck-preview")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: preview.url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil; coordinator.preview = nil
    }
    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
        var preview: CapturePackagePreview?
        init(_ preview: CapturePackagePreview) { self.preview = preview }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url, let resource = preview?.resource(for: url) else {
                task.didFailWithError(URLError(.resourceUnavailable)); return
            }
            task.didReceive(URLResponse(url: url, mimeType: resource.mime, expectedContentLength: resource.data.count, textEncodingName: resource.mime == "text/html" ? "utf-8" : nil))
            task.didReceive(resource.data); task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url == preview?.url && action.targetFrame?.isMainFrame != false ? .allow : .cancel)
        }
    }
}
