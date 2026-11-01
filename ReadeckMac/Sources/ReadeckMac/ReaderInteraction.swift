import AppKit
import SwiftUI
import WebKit

/// Owns the WebKit view; transient controls never alter its scrolling hierarchy.
final class ReaderContainerView: NSView {
    let webView: WKWebView
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Viewport geometry is transient UI state, never part of the server annotation.
struct SelectionAnchor: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var viewportWidth: Double? = nil
    var viewportHeight: Double? = nil
    var pointerX: Double? = nil
    var pointerY: Double? = nil
    var preferredSide: String? = nil

    /// CSS always uses a top-left viewport. Prefer the recorded native release
    /// point as a screen-space reference, avoiding WebKit/SwiftUI view transforms.
    func screenRect(in viewport: CGRect, pointer: CGPoint?) -> CGRect? {
        let source = CGSize(width: viewportWidth ?? viewport.width, height: viewportHeight ?? viewport.height)
        guard let visible = rect(in: source, flipped: true),
              [viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy(\.isFinite),
              viewport.width > 0, viewport.height > 0 else { return nil }
        let sx = viewport.width / source.width, sy = viewport.height / source.height
        var left = viewport.minX + visible.minX * sx
        var top = viewport.maxY - visible.minY * sy
        if let pointer, let pointerX, let pointerY,
           [pointer.x, pointer.y, pointerX, pointerY].allSatisfy(\.isFinite), viewport.contains(pointer),
           pointerX >= 0, pointerX <= source.width, pointerY >= 0, pointerY <= source.height,
           hypot(pointer.x - (viewport.minX + pointerX * sx),
                 pointer.y - (viewport.maxY - pointerY * sy)) <= 24 {
            left = pointer.x + (visible.minX - pointerX) * sx
            top = pointer.y + (pointerY - visible.minY) * sy
        }
        let screen = CGRect(x: left, y: top-visible.height*sy, width: max(1, visible.width*sx), height: visible.height*sy)
        let clipped = screen.intersection(viewport)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    func rect(in size: CGSize, flipped: Bool) -> CGRect? {
        guard [x, y, width, height, size.width, size.height].allSatisfy(\.isFinite),
              width > 0, height > 0, size.width > 0, size.height > 0 else { return nil }
        let visible = CGRect(x: x, y: y, width: width, height: height)
            .intersection(CGRect(origin: .zero, size: size))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(x: visible.minX, y: flipped ? visible.minY : size.height - visible.maxY,
                      width: visible.width, height: visible.height)
    }
}

enum ReaderSelectionAction {
    case highlight(String), note, copy
}

struct AnnotationRevealRequest: Equatable {
    let token = UUID()
    let annotationID: String
}

struct SelectionToolbarView: View {
    let onAction: (ReaderSelectionAction) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach(AnnotationColorPicker.colors, id: \.0) { item in
                Button { onAction(.highlight(item.0)) } label: {
                    Circle().fill(item.2).frame(width: 19, height: 19)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                }.buttonStyle(.plain).help(AppLanguage.text("\(item.1)划线")).accessibilityLabel(AppLanguage.text("\(item.1)划线"))
            }
            Divider().frame(height: 20)
            Button { onAction(.note) } label: { Label("写批注", systemImage: AppSymbol.edit.rawValue) }
                .buttonStyle(.plain)
            Button { onAction(.copy) } label: { Image(systemName: AppSymbol.copy.rawValue) }
                .buttonStyle(.plain).help("复制").accessibilityLabel("复制")
        }.padding(.horizontal, 14).padding(.vertical, 11).fixedSize()
            .background(.regularMaterial, in: Capsule())
    }
}

/// A non-activating child panel positioned in screen coordinates, avoiding
/// NSPopover's automatic anchor repositioning inside nested SwiftUI windows.
@MainActor
final class SelectionToolbarPanel {
    let contentViewController: NSViewController?
    private let panel: NSPanel
    var isShown: Bool { panel.isVisible }

    init(parent: NSWindow, anchor: NSRect, viewport: NSRect, preferBelow: Bool, content: NSViewController) {
        contentViewController = content
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.contentViewController = content
        content.view.layoutSubtreeIfNeeded()
        let size = content.view.fittingSize
        let bounds = viewport.intersection(parent.screen?.visibleFrame ?? viewport)
        let x = min(max(anchor.midX - size.width / 2, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - size.width - 4))
        let above = anchor.maxY + 6
        let below = anchor.minY - size.height - 6
        let useBelow = preferBelow ? below >= bounds.minY : above + size.height > bounds.maxY && below >= bounds.minY
        let y = useBelow ? below : min(max(above, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
    }
}
