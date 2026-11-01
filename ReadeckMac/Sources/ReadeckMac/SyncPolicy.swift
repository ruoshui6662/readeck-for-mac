import Foundation

struct SyncPolicy {
    var fullSyncTimeout: TimeInterval = 45
    var captureTimeout: TimeInterval = 20
    var retryIntervals: [TimeInterval] = [5, 10, 20, 40, 60]

    func retryDelay(attempt: Int) -> TimeInterval {
        let intervals = retryIntervals.isEmpty ? [60] : retryIntervals
        return intervals[min(max(0, attempt), intervals.count - 1)]
    }
}

enum SyncDeadlineError: LocalizedError {
    case exceeded
    var errorDescription: String? { "本轮同步等待过久，已停止并保留本机更改，将自动重试。" }
}

enum SyncDeadline {
    static func run<T>(seconds: TimeInterval,
                       operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SyncDeadlineError.exceeded
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

enum NetworkAccessError: LocalizedError {
    case localNetworkDenied
    var errorDescription: String? {
        "macOS 阻止了局域网访问。请在“系统设置 → 隐私与安全性 → 本地网络”允许 Readeck Mac；若已开启，可关闭后重新开启，再重试。"
    }
}
