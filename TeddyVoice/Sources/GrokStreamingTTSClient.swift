@preconcurrency import Foundation
import OSLog

@MainActor
protocol GrokStreamingTTSClientDelegate: AnyObject {
    func streamingTTSClientDidOpen(at timestamp: ContinuousClock.Instant)
    func streamingTTSClientReceivedAudio(_ data: Data, at timestamp: ContinuousClock.Instant)
    func streamingTTSClientDidFinishAudio()
    func streamingTTSClientDidClearAudio()
    func streamingTTSClientDidLog(_ message: String)
    func streamingTTSClientDidFail(_ message: String)
}

struct GrokTTSConfiguration: Sendable, Equatable {
    static let pricePerMillionCharactersUSD = 15.0

    let voice: String
    let speed: Double
    var latencyOptimization = 0
}

@MainActor
final class GrokStreamingTTSClient {
    weak var delegate: GrokStreamingTTSClientDelegate?

    private let sender = TTSTextSendQueue()
    private let binaryAudioHandler: RealtimeBinaryAudioHandler
    private let connectionGate = ConnectionGenerationGate()
    private let logger = Logger(
        subsystem: "com.sipiyou.teddycli",
        category: "tts-streaming"
    )
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionDelegate: RealtimeURLSessionDelegate?
    private var receiveTask: Task<Void, Never>?
    private var activeConfiguration: GrokTTSConfiguration?
    private var isIntentionalDisconnect = false
    private(set) var isReady = false

    init(binaryAudioHandler: @escaping RealtimeBinaryAudioHandler) {
        self.binaryAudioHandler = binaryAudioHandler
    }

    @discardableResult
    func connect(apiKey: String, configuration: GrokTTSConfiguration) -> Bool {
        if activeConfiguration == configuration,
           webSocketTask != nil,
           (isReady || session != nil)
        {
            return false
        }

        disconnect()
        let generation = connectionGate.advance()
        activeConfiguration = configuration
        isIntentionalDisconnect = false
        isReady = false

        var components = URLComponents(string: "wss://api.x.ai/v1/tts")!
        components.queryItems = [
            URLQueryItem(name: "language", value: "fr"),
            URLQueryItem(name: "voice", value: configuration.voice),
            URLQueryItem(name: "codec", value: "pcm"),
            URLQueryItem(name: "sample_rate", value: String(TeddyAudioFormat.sampleRate)),
            URLQueryItem(name: "speed", value: String(format: "%.2f", configuration.speed)),
            URLQueryItem(
                name: "optimize_streaming_latency",
                value: String(configuration.latencyOptimization)
            ),
            URLQueryItem(name: "text_normalization", value: "false"),
        ]
        guard let url = components.url else {
            delegate?.streamingTTSClientDidFail("URL TTS xAI invalide.")
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.networkServiceType = .voice
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let urlDelegate = RealtimeURLSessionDelegate(
            onOpen: { [weak self] _ in
                Task { @MainActor in self?.didOpen(generation: generation) }
            },
            onClose: { [weak self] code, reason in
                Task { @MainActor in
                    self?.didClose(code: code, reason: reason, generation: generation)
                }
            },
            onComplete: { [weak self] statusCode, error in
                Task { @MainActor in
                    self?.didComplete(statusCode: statusCode, error: error, generation: generation)
                }
            }
        )
        sessionDelegate = urlDelegate
        let urlSession = URLSession(configuration: .ephemeral, delegate: urlDelegate, delegateQueue: nil)
        session = urlSession
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        sender.install(task: task) { [weak self] message in
            Task { @MainActor in self?.delegate?.streamingTTSClientDidFail(message) }
        }
        task.resume()

        let binaryAudioHandler = self.binaryAudioHandler
        receiveTask = Task.detached(priority: .high) { [weak self, weak task] in
            guard let self, let task else { return }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard self.connectionGate.matches(generation) else { return }
                    let receivedAt = ContinuousClock.now
                    switch message {
                    case .data(let data):
                        // PCM is normally wrapped in audio.delta JSON, but accepting
                        // binary frames keeps the client compatible with either transport.
                        binaryAudioHandler(data, receivedAt)
                        await self.notifyAudio(data, at: receivedAt, generation: generation)
                    case .string(let text):
                        await self.handleJSON(text, receivedAt: receivedAt, generation: generation)
                    @unknown default:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await self.receiveFailed(error, generation: generation)
            }
        }
        delegate?.streamingTTSClientDidLog("Connexion TTS streaming xAI…")
        return true
    }

    nonisolated func beginUtterance() {
        sender.beginUtterance()
    }

    nonisolated func enqueueTextDelta(_ delta: String) {
        sender.enqueueTextDelta(delta)
    }

    nonisolated func finishUtterance() {
        sender.finishUtterance()
    }

    nonisolated func cancelUtterance() {
        sender.cancelUtterance()
    }

    func disconnect() {
        _ = connectionGate.advance()
        isIntentionalDisconnect = true
        isReady = false
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegate = nil
        activeConfiguration = nil
        sender.reset()
    }

    private func didOpen(generation: Int) {
        guard connectionGate.matches(generation) else { return }
        isReady = true
        sender.markReady(replacements: SpokenFrenchPronunciation.ttsReplacements)
        let latencyOptimization = activeConfiguration?.latencyOptimization ?? 0
        logger.info("TTS WebSocket opened with latency optimization \(latencyOptimization, privacy: .public)")
        delegate?.streamingTTSClientDidOpen(at: .now)
        delegate?.streamingTTSClientDidLog(
            "TTS prêt — PCM 24 kHz, profil mesuré \(latencyOptimization)."
        )
    }

    private func didClose(
        code: URLSessionWebSocketTask.CloseCode,
        reason: String?,
        generation: Int
    ) {
        guard connectionGate.matches(generation), !isIntentionalDisconnect else { return }
        isReady = false
        delegate?.streamingTTSClientDidFail(
            "WebSocket TTS fermé (\(code.rawValue))\(reason.map { ": \($0)" } ?? ".")"
        )
    }

    private func didComplete(statusCode: Int?, error: Error?, generation: Int) {
        guard connectionGate.matches(generation), !isIntentionalDisconnect, let error else { return }
        isReady = false
        let status = statusCode.map { " HTTP \($0)" } ?? ""
        delegate?.streamingTTSClientDidFail("Connexion TTS xAI\(status) : \(error.localizedDescription)")
    }

    private func notifyAudio(_ data: Data, at timestamp: ContinuousClock.Instant, generation: Int) {
        guard connectionGate.matches(generation) else { return }
        delegate?.streamingTTSClientReceivedAudio(data, at: timestamp)
    }

    private func handleJSON(
        _ text: String,
        receivedAt: ContinuousClock.Instant,
        generation: Int
    ) {
        guard connectionGate.matches(generation),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "audio.delta":
            if let delta = json["delta"] as? String,
               let audio = Data(base64Encoded: delta),
               !audio.isEmpty
            {
                binaryAudioHandler(audio, receivedAt)
                delegate?.streamingTTSClientReceivedAudio(audio, at: receivedAt)
            }
        case "audio.done":
            sender.markAudioFinished()
            delegate?.streamingTTSClientDidFinishAudio()
        case "audio.clear":
            sender.markAudioFinished()
            delegate?.streamingTTSClientDidClearAudio()
        case "error":
            let nested = json["error"] as? [String: Any]
            let message = (json["message"] as? String)
                ?? (nested?["message"] as? String)
                ?? "Erreur TTS xAI inconnue."
            delegate?.streamingTTSClientDidFail(message)
        default:
            delegate?.streamingTTSClientDidLog("TTS ← \(type)")
        }
    }

    private func receiveFailed(_ error: Error, generation: Int) {
        guard connectionGate.matches(generation), !isIntentionalDisconnect else { return }
        isReady = false
        delegate?.streamingTTSClientDidFail("Réception TTS WebSocket : \(error.localizedDescription)")
    }
}

private final class TTSTextSendQueue: @unchecked Sendable {
    private enum PendingEvent {
        case text(String)
        case done
    }

    private let queue = DispatchQueue(
        label: "com.sipiyou.teddycli.tts-send",
        qos: .userInteractive
    )
    private var task: URLSessionWebSocketTask?
    private var isReady = false
    private var pending: [PendingEvent] = []
    private var utteranceIsOpen = false
    private var acceptsText = false
    private var onError: (@Sendable (String) -> Void)?

    func install(
        task: URLSessionWebSocketTask,
        onError: @escaping @Sendable (String) -> Void
    ) {
        queue.sync {
            self.task = task
            self.onError = onError
            isReady = false
            pending.removeAll(keepingCapacity: true)
            utteranceIsOpen = false
            acceptsText = false
        }
    }

    func markReady(replacements: [String: String]) {
        queue.async { [weak self] in
            guard let self, let task else { return }
            isReady = true
            send(
                ["type": "session.update", "replace": replacements],
                with: task
            )
            let events = pending
            pending.removeAll(keepingCapacity: true)
            for event in events { send(event, with: task) }
        }
    }

    func beginUtterance() {
        queue.async { [weak self] in
            guard let self else { return }
            pending.removeAll(keepingCapacity: true)
            if utteranceIsOpen, isReady, let task {
                send(["type": "text.clear"], with: task)
            }
            utteranceIsOpen = true
            acceptsText = true
        }
    }

    func enqueueTextDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, utteranceIsOpen, acceptsText else { return }
            let event = PendingEvent.text(delta)
            guard isReady, let task else {
                pending.append(event)
                return
            }
            send(event, with: task)
        }
    }

    func finishUtterance() {
        queue.async { [weak self] in
            guard let self, utteranceIsOpen, acceptsText else { return }
            acceptsText = false
            let event = PendingEvent.done
            guard isReady, let task else {
                pending.append(event)
                return
            }
            send(event, with: task)
        }
    }

    func cancelUtterance() {
        queue.async { [weak self] in
            guard let self else { return }
            pending.removeAll(keepingCapacity: true)
            let hadOpenUtterance = utteranceIsOpen
            utteranceIsOpen = false
            acceptsText = false
            guard hadOpenUtterance, isReady, let task else { return }
            send(["type": "text.clear"], with: task)
        }
    }

    func markAudioFinished() {
        queue.async { [weak self] in
            self?.utteranceIsOpen = false
            self?.acceptsText = false
        }
    }

    func reset() {
        queue.sync {
            task = nil
            isReady = false
            pending.removeAll(keepingCapacity: false)
            utteranceIsOpen = false
            acceptsText = false
            onError = nil
        }
    }

    private func send(_ event: PendingEvent, with task: URLSessionWebSocketTask) {
        switch event {
        case .text(let delta):
            send(["type": "text.delta", "delta": delta], with: task)
        case .done:
            send(["type": "text.done"], with: task)
        }
    }

    private func send(_ value: [String: Any], with task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return }
        let onError = self.onError
        task.send(.string(text)) { error in
            if let error { onError?("Envoi TTS WebSocket : \(error.localizedDescription)") }
        }
    }
}
