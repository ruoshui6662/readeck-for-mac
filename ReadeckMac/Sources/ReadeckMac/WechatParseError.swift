import Foundation

/// 微信文章解析/上传过程中的错误
enum WechatParseError: LocalizedError, Sendable {
    case invalidURL
    case networkError(Error)
    /// 遇到验证码、403、付费等阻塞情况，应提示用户在浏览器打开原网页
    case blocked(reason: String)
    case parseError(String)
    case noContent
    case interactionRequired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的文章链接。"
        case let .networkError(error):
            return "网络错误：\(error.localizedDescription)"
        case let .blocked(reason):
            return "无法解析微信公众号文章：\(reason)。请在浏览器打开原网页。"
        case let .parseError(message):
            return "解析失败：\(message)。"
        case .noContent:
            return "未找到文章正文。"
        case .interactionRequired:
            return "需要在采集窗口中完成网页验证，或当前文章类型暂不支持。"
        }
    }

    /// 是否为阻塞类错误（应提示打开原网页）
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    static func captureMessage(for error: Error, site: CaptureSite = .wechat) -> String {
        let name = site == .wechat ? "微信" : site.title
        if let capture = error as? CaptureError { return capture.localizedDescription }
        if let parse = error as? WechatParseError {
            if case .networkError = parse { return "\(name)原文加载失败，请检查网络后重新采集。" }
            return parse.localizedDescription
        }
        if let network = error as? URLError {
            if network.code == .timedOut { return "\(name)原文加载超时，请稍后重新采集。" }
            return "\(name)原文加载失败，请检查网络后重新采集。"
        }
        return "\(name)采集未完成，请打开原文核对后重试。"
    }
}
