import AppKit
import SwiftUI

/// A SwiftUI Button can dispatch its action after NSApp.currentEvent has moved
/// on. Retain modifiers from the event within this list, before it is delivered.
@MainActor final class LibraryListEvents: ObservableObject {
    var modifiers: NSEvent.ModifierFlags = []
}

struct LibraryListEventCapture: NSViewRepresentable {
    let events: LibraryListEvents
    func makeNSView(context: Context) -> ListEventAnchor { ListEventAnchor(events: events) }
    func updateNSView(_ view: ListEventAnchor, context: Context) {}
}

final class ListEventAnchor: NSView {
    private let events: LibraryListEvents
    private var monitor: Any?
    init(events: LibraryListEvents) { self.events = events; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyDown || self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.events.modifiers = event.modifierFlags
            }
            return event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
