import Foundation

enum CaptureResourceRole: String, Codable, Sendable { case bodyImage, bodyBackground, unknownWidget }

struct CaptureResourceIssue: Codable, Sendable, Equatable {
    enum Reason: String, Codable, Sendable { case archiveMissing, decodeUnsupported, limitExceeded, loadFailed, timedOut, scopeMismatch }
    let role: CaptureResourceRole
    let position: Int
    let sourceHost: String?
    let reason: Reason
    let nodeID: String?
    var attempts: Int = 1

    init(role: CaptureResourceRole, position: Int, source: URL?, reason: Reason, attempts: Int = 1, nodeID: String? = nil) {
        self.role = role; self.position = position; self.reason = reason; self.attempts = attempts
        self.sourceHost = source?.host?.lowercased()
        let parts = nodeID?.split(separator: "-") ?? []
        self.nodeID = parts.count == 2 && (parts[0] == "image" || parts[0] == "background") && Int(parts[1]).map({ (0..<100).contains($0) }) == true ? nodeID : nil
    }
    var message: String {
        if reason == .timedOut && position == 0 { return "正文仍在变化，未能在限定时间内稳定，请重新采集。" }
        if reason == .scopeMismatch { return "正文资源范围发生变化，请重新采集。" }
        let kind = role == .bodyBackground ? "背景图片" : "正文图片"
        let detail: String = switch reason {
        case .archiveMissing: "归档中没有图片数据"
        case .decodeUnsupported: "图片数据无法解码或格式不受支持"
        case .limitExceeded: "图片超过大小上限"
        case .loadFailed: "图片加载失败"
        case .timedOut: "图片等待超时"
        case .scopeMismatch: "资源范围不一致"
        }
        return "\(kind) \(position)：\(detail)；来源 \(sourceHost ?? "内嵌或本地资源")"
    }
}

struct CaptureResourceReport: Codable, Sendable, Equatable {
    struct Readiness: Codable, Sendable, Equatable {
        let settled: Bool
        let failedImages: Int
        let pendingImages: Int
        let milliseconds: Int
    }
    let policyVersion: Int
    let discoveredImages: Int
    let archivedImages: Int
    let omittedImages: Int
    let normalizedWidgets: Int
    let issues: [CaptureResourceIssue]
    var readiness: Readiness? = nil
}
