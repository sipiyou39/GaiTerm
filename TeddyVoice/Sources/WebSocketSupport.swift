@preconcurrency import Foundation

typealias RealtimeBinaryAudioHandler = @Sendable (Data, ContinuousClock.Instant) -> Void

final class ConnectionGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func advance() -> Int {
        lock.withLock {
            generation += 1
            return generation
        }
    }

    func matches(_ candidate: Int) -> Bool {
        lock.withLock { generation == candidate }
    }
}

final class RealtimeURLSessionDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let onOpen: @Sendable (String?) -> Void
    private let onClose: @Sendable (URLSessionWebSocketTask.CloseCode, String?) -> Void
    private let onComplete: @Sendable (Int?, Error?) -> Void

    init(
        onOpen: @escaping @Sendable (String?) -> Void,
        onClose: @escaping @Sendable (URLSessionWebSocketTask.CloseCode, String?) -> Void,
        onComplete: @escaping @Sendable (Int?, Error?) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen(`protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose(closeCode, reason.flatMap { String(data: $0, encoding: .utf8) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete((task.response as? HTTPURLResponse)?.statusCode, error)
    }
}
