import Foundation

enum ConnectionDiagnostics {
    static func shouldRetry(_ error: Error) -> Bool {
        if error is SyncDeadlineError { return true }
        if error is CancellationError || error is NetworkAccessError { return false }
        if let network = error as? URLError {
            return [.timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                    .networkConnectionLost, .dnsLookupFailed].contains(network.code)
        }
        if case let APIError.status(code, _) = error { return code == 408 || code == 429 || code >= 500 }
        return false
    }

    static func mustStopRound(_ error: Error) -> Bool {
        if error is CancellationError || error is NetworkAccessError || error is SyncDeadlineError { return true }
        if error is URLError { return true }
        if case let APIError.status(code, _) = error { return code == 401 || code == 403 || code == 408 || code == 429 || code >= 500 }
        return false
    }

    static func message(for error: Error) -> String {
        if let access = error as? NetworkAccessError { return access.localizedDescription }
        if let api = error as? APIError {
            switch api {
            case .status(401, _): return "API Token 无效或已过期，请重新检查令牌。"
            case .status(403, _): return "API Token 缺少访问收藏所需的权限。"
            case .status(404, _): return "Readeck 未找到请求的资源，请检查服务端地址或收藏状态。"
            case let .status(code, _): return "Readeck 请求失败（HTTP \(code)）。"
            case .invalidResponse: return "Readeck 返回了无效响应。"
            }
        }
        if let network = error as? URLError {
            switch network.code {
            case .timedOut: return "NAS 响应超时，请稍后重试。"
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .dnsLookupFailed:
                return "无法连接到 NAS。请检查网络和服务端地址。"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
                return "HTTPS 证书校验失败，请检查 NAS 证书。"
            default: break
            }
        }
        return error.localizedDescription
    }
}
