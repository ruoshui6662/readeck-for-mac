import AppKit
import Network

enum ConnectionEvent {
    case activated, woke, networkAvailable
}

enum ConnectionEvents {
    @MainActor
    static func live() -> AsyncStream<ConnectionEvent> {
        AsyncStream { continuation in
            let workspaceCenter = NSWorkspace.shared.notificationCenter
            let wake = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                     object: nil, queue: .main) { _ in
                continuation.yield(.woke)
            }
            let activate = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { _ in
                continuation.yield(.activated)
            }
            let monitor = NWPathMonitor()
            var previous: NWPath.Status?
            monitor.pathUpdateHandler = { path in
                if previous != nil, previous != .satisfied, path.status == .satisfied {
                    continuation.yield(.networkAvailable)
                }
                previous = path.status
            }
            monitor.start(queue: DispatchQueue(label: "org.readck.connection-events"))
            continuation.onTermination = { _ in
                monitor.cancel()
                workspaceCenter.removeObserver(wake)
                NotificationCenter.default.removeObserver(activate)
            }
        }
    }
}
