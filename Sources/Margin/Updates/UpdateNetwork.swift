import Foundation
import MarginKit

/// The updater's two network requests (spec §14.3): GitHub's latest release, and the release's zip. Both use an ephemeral
/// session (no cookies, no cache, nothing kept), send only `Margin/<version>` as the user agent, and go only to https
/// addresses (DEBUG and bench builds also accept a local feed for testing: `file://` or `http://127.0.0.1`).
enum UpdateNetwork {
    static var userAgent: String { "Margin/\(UpdateController.currentVersionString)" }

    static func isAllowed(_ url: URL) -> Bool {
        #if DEBUG || MARGIN_BENCH
        if url.isFileURL || (url.scheme == "http" && url.host == "127.0.0.1") { return true }
        #endif
        return url.scheme == "https"
    }

    private static func configuration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// `GET …/releases/latest`, decoded. Throws `UpdateError` (or `CancellationError`).
    nonisolated static func latestRelease(from url: URL) async throws -> GitHubRelease {
        guard isAllowed(url) else { throw UpdateError.offline("not an https address") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: configuration(requestTimeout: 20, resourceTimeout: 40))
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw UpdateError.offline(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse,
           let error = UpdateCheck.error(forStatus: http.statusCode,
                                         rateLimitRemaining: http.value(forHTTPHeaderField: "X-RateLimit-Remaining")) {
            throw error
        }
        // The real answer is about 15 KB; anything near this isn't one.
        guard data.count < 4_000_000 else { throw UpdateError.unreadableAnswer }
        do {
            return try GitHubRelease.decode(data)
        } catch {
            throw UpdateError.unreadableAnswer
        }
    }

    /// Downloads `url` to `destination`, reporting progress (bytes so far, bytes expected or -1) on a background queue.
    /// Throws `UpdateError.download` (or `CancellationError` when the task is cancelled).
    nonisolated static func download(_ url: URL, to destination: URL,
                                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard isAllowed(url) else { throw UpdateError.download("not an https address") }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let download = Download(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration(requestTimeout: 60, resourceTimeout: 15 * 60),
                                 delegate: download, delegateQueue: nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                download.start(session.downloadTask(with: request), continuation: continuation)
            }
        } onCancel: {
            download.cancel()
        }
    }

    /// The delegate behind `download`: it moves the file into place before URLSession deletes it, follows only https
    /// redirects (GitHub sends the zip from another host), and finishes the continuation once.
    private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let progress: @Sendable (Int64, Int64) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        private var failure: (any Error)?

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, any Error>) {
            let cancelled = lock.withLock {
                self.task = task
                self.continuation = continuation
                return self.cancelled
            }
            if cancelled { task.cancel() } else { task.resume() }
        }

        func cancel() {
            let task = lock.withLock {
                cancelled = true
                return self.task
            }
            task?.cancel()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url.map(UpdateNetwork.isAllowed) == true ? request : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lock.withLock { failure = UpdateError.download("HTTP \(http.statusCode)") }
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                lock.withLock { failure = UpdateError.download(error.localizedDescription) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            session.finishTasksAndInvalidate()
            let (continuation, failure, cancelled) = lock.withLock {
                let c = self.continuation
                self.continuation = nil
                return (c, self.failure, self.cancelled)
            }
            if cancelled || (error as? URLError)?.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else if let error {
                continuation?.resume(throwing: UpdateError.download(error.localizedDescription))
            } else if let failure {
                continuation?.resume(throwing: failure)
            } else {
                continuation?.resume()
            }
        }
    }
}
