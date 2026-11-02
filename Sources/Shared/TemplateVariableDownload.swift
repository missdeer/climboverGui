import Foundation

struct VariableDownloadProgress: Sendable {
    let receivedBytes: Int64
    let totalBytes: Int64?
}

final class TemplateVariableDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let report: (@Sendable (VariableDownloadProgress) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var data = Data()
    private var failure: Error?

    init(report: (@Sendable (VariableDownloadProgress) -> Void)?) { self.report = report }

    func load(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let activeTask = task
        lock.unlock()
        activeTask?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        report?(VariableDownloadProgress(receivedBytes: 0,
            totalBytes: response.expectedContentLength > 0 ? response.expectedContentLength : nil))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard data.count + chunk.count <= RemoteTemplateVariables.maximumDownloadBytes else {
            failure = ControlError("单份变量内容不能超过 30 MB。")
            dataTask.cancel()
            return
        }
        data.append(chunk)
        let expected = dataTask.response?.expectedContentLength ?? -1
        report?(VariableDownloadProgress(receivedBytes: Int64(data.count), totalBytes: expected > 0 ? expected : nil))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error = failure ?? error { pending?.resume(throwing: error) }
        else if let response = task.response { pending?.resume(returning: (data, response)) }
        else { pending?.resume(throwing: URLError(.badServerResponse)) }
    }
}

