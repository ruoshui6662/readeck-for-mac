import Foundation

struct CaptureJob: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable {
        case queued, importing, capturing, needsInteraction, ready, uploading, uncertain, verifying, complete, failed, cancelled
        var title: String {
            let key: String = switch self {
            case .queued: "等待采集"
            case .importing: "导入网页文件"
            case .capturing: "采集正文与图片"
            case .needsInteraction: "需要完成网页验证"
            case .ready: "等待上传"
            case .uploading: "上传到 NAS"
            case .uncertain: "确认上传结果"
            case .verifying: "验证 NAS 归档"
            case .complete: "已保存到 NAS"
            case .failed: "采集暂停"
            case .cancelled: "已取消"
            }
            return AppLanguage.text(key)
        }
    }
    var id = UUID().uuidString
    var url: String
    /// Source-only acquisition parameters. Never used as the NAS source URL.
    var requestURL: String? = nil
    var title: String
    var labels: [String]
    var created = Date()
    var stage: Stage = .queued
    var attemptedAt: Date?
    var bookmarkID: String?
    var revision: String?
    var packageGeneration: String?
    var preparationID: String?
    var recaptureRequested: Bool?
    var resourceReport: CaptureResourceReport?
    var message: String?
    var blocksTaxonomyChanges: Bool { attemptedAt != nil && bookmarkID == nil && stage != .complete && stage != .cancelled }
}
