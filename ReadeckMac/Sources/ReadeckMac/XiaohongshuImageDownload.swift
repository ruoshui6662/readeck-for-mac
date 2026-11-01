import Foundation

enum XiaohongshuImageDownload {
    static func request(for url: URL, source: URL) throws -> URLRequest {
        guard let safe = XiaohongshuImport.imageURL(url.absoluteString),
              let origin = try? CaptureSourceURL(source.absoluteString), origin.site == .xiaohongshu else { throw CaptureError.invalidPackage }
        var request = URLRequest(url: safe, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("https://\(origin.canonical.host!)/", forHTTPHeaderField: "Referer")
        return request
    }

    static func supplement(_ original: XiaohongshuImport.Prepared,
                           fetch: (@Sendable (URL) async throws -> Data)? = nil) async throws -> XiaohongshuImport.Prepared {
        var result = original
        let missing = Array(Set(original.images.filter { original.resources[$0.absoluteString] == nil }))
        let get: @Sendable (URL) async throws -> Data = fetch ?? { url in
            let request = try request(for: url, source: original.source.canonical)
            return try await SourceImageTransfer().load(request)
        }
        for start in stride(from: 0, to: missing.count, by: 3) {
            try Task.checkCancellation()
            let batch = missing[start..<min(start + 3, missing.count)]
            let values = try await withThrowingTaskGroup(of: (URL, Data?).self) { group in
                for url in batch { group.addTask {
                    do { return (url, try await get(url)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (url, nil) }
                } }
                var values: [(URL, Data?)] = []
                for try await value in group { values.append(value) }
                return values
            }
            for (url, data) in values {
                guard let data, data.count <= CaptureLimits().maximumImageBytes else { continue }
                result.resources[url.absoluteString] = data
            }
            guard result.resources.values.reduce(0, { $0 + $1.count }) <= CaptureLimits().maximumTotalImageBytes else {
                throw WechatParseError.parseError("图集总大小超过32 MiB上限，已停止补图。")
            }
        }
        try Task.checkCancellation()
        return result
    }
}

/// Source-only ephemeral transfer. State is protected by a lock because URLSession
/// callbacks and task cancellation arrive on different queues. Rejects redirects
/// and streams at most the existing per-image budget into memory.
private final class SourceImageTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var cancelled = false

    func load(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
                config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                lock.lock()
                if cancelled {
                    lock.unlock(); session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation; self.session = session; self.task = task
                lock.unlock(); task.resume()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= CaptureLimits().maximumImageBytes,
              response.mimeType?.lowercased().hasPrefix("image/") == true else {
            completionHandler(.cancel); finish(.failure(CaptureError.invalidPackage)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let oversized = bytes.count + data.count > CaptureLimits().maximumImageBytes
        if !oversized { bytes.append(data) }
        lock.unlock()
        if oversized { finish(.failure(CaptureError.invalidPackage)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let data = bytes; lock.unlock()
        if let error { finish(.failure(error)) } else { finish(.success(data)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); cancelled = true
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil; task = nil
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
}
