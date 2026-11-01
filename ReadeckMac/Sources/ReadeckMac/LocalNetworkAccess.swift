import Foundation
import Network

enum LocalNetworkAccess {
    static func isDenied(for url: URL) async -> Bool {
        guard let host = url.host,
              let rawPort = UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            Probe(host: host, port: port, continuation: continuation).start()
        }
    }

    private final class Probe: @unchecked Sendable {
        private let connection: NWConnection
        private let continuation: CheckedContinuation<Bool, Never>
        private let lock = NSLock()
        private var finished = false

        init(host: String, port: NWEndpoint.Port, continuation: CheckedContinuation<Bool, Never>) {
            connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            self.continuation = continuation
        }

        func start() {
            connection.stateUpdateHandler = { [self] state in
                let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                switch state {
                case .ready, .failed, .waiting: finish(denied)
                default: if denied { finish(true) }
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                finish(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
            }
        }

        private func finish(_ denied: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: denied)
        }
    }
}
