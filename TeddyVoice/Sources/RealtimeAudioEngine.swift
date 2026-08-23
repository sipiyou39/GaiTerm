@preconcurrency import AVFoundation
import Foundation
import OSLog

typealias MicrophonePCMHandler = @Sendable (Data) -> Void

enum TeddyAudioFormat {
    static let sampleRate = 24_000
    static let pcm16MonoBytesPerSecond = sampleRate * MemoryLayout<Int16>.size
}

struct MicrophoneCaptureSummary: Sendable, Equatable {
    let chunkCount: Int
    let byteCount: Int

    var durationMilliseconds: Double {
        Double(byteCount) / Double(TeddyAudioFormat.pcm16MonoBytesPerSecond) * 1_000
    }
}

@MainActor
final class RealtimeAudioEngine {
    private let playbackScheduler: AudioPlaybackScheduler
    private var engine: AVAudioEngine?
    private var microphoneProcessor: MicrophonePCMProcessor?
    private var tapInstalled = false

    var isRunning: Bool { engine?.isRunning == true }

    init(playbackScheduler: AudioPlaybackScheduler) {
        self.playbackScheduler = playbackScheduler
    }

    func start(echoCancellation: Bool, onMicrophonePCM: @escaping MicrophonePCMHandler) throws -> [String] {
        stop()
        var log: [String] = []

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackScheduler.format)

        let input = engine.inputNode
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.isVoiceProcessingAGCEnabled = true
                input.isVoiceProcessingBypassed = false
                log.append("Annulation d’écho et AGC activés.")
            } catch {
                log.append("Annulation d’écho indisponible : \(error.localizedDescription)")
            }
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let captureFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: hardwareFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              )
        else {
            throw RealtimeAudioError.noMicrophoneFormat
        }
        let processor = MicrophonePCMProcessor(
            inputSampleRate: captureFormat.sampleRate,
            handler: onMicrophonePCM
        )
        microphoneProcessor = processor

        // Keep the realtime callback outside MainActor isolation: Core Audio invokes it on its own queue.
        AudioTapInstaller.install(on: input, format: captureFormat, processor: processor)
        tapInstalled = true

        do {
            // Prime enough render capacity for the larger binary chunks emitted at
            // the beginning of an xAI response. 960 frames was only 40 ms and could
            // force an allocation while the first words were already playing.
            // xAI often emits chunks larger than one second. Reserve enough render
            // capacity up front so a large chunk never forces the player to grow
            // its resources while speech is already audible.
            player.prepare(withFrameCount: 131_072)
            engine.prepare()
            try engine.start()
            playbackScheduler.install(player)
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            microphoneProcessor = nil
            throw error
        }

        self.engine = engine
        log.append("Micro Float32 mono \(Int(captureFormat.sampleRate)) Hz → PCM16 24 kHz binaire.")
        return log
    }

    func stop() {
        guard let engine else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        playbackScheduler.removePlayer()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        microphoneProcessor = nil
        self.engine = nil
    }

    func beginCapture() {
        microphoneProcessor?.beginCapture()
    }

    @discardableResult
    func endCapture() -> MicrophoneCaptureSummary {
        microphoneProcessor?.endCapture()
            ?? MicrophoneCaptureSummary(chunkCount: 0, byteCount: 0)
    }

    func setPlaybackStartedHandler(_ handler: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        playbackScheduler.setPlaybackStartedHandler(handler)
    }

    func setPlaybackFinishedHandler(_ handler: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        playbackScheduler.setPlaybackFinishedHandler(handler)
    }

    func beginPlaybackResponse(startImmediately: Bool = false) {
        playbackScheduler.beginResponse(startImmediately: startImmediately)
    }

    func interruptPlaybackAndDiscard() {
        playbackScheduler.interruptAndDiscard()
    }

    func finishPlaybackResponse() -> ContinuousClock.Instant? {
        playbackScheduler.finishResponse()
    }

    @discardableResult
    func playArchivedPCM16(
        _ data: Data,
        onFinished: @escaping @Sendable () -> Void
    ) -> Bool {
        playbackScheduler.playArchivedPCM16(data, onFinished: onFinished)
    }
}

final class AudioPlaybackScheduler: @unchecked Sendable {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(TeddyAudioFormat.sampleRate),
        channels: 1,
        interleaved: false
    )!

    private let queue = DispatchQueue(
        label: "com.sipiyou.teddycli.audio-playback",
        qos: .userInteractive
    )
    private let logger = Logger(
        subsystem: "com.sipiyou.teddycli",
        category: "audio-playback"
    )
    private var player: AVAudioPlayerNode?
    private var acceptsAudio = false
    private var bufferPolicy = PlaybackJitterBufferPolicy()
    private var responseGeneration = 0
    private var playbackStartedHandler: (@Sendable (ContinuousClock.Instant) -> Void)?
    private var playbackFinishedHandler: (@Sendable (ContinuousClock.Instant) -> Void)?
    private var responsePlaybackStartedAt: ContinuousClock.Instant?
    private var scheduledResponseFrames = 0
    private var completionSentinelScheduled = false

    var format: AVAudioFormat { Self.format }

    func setPlaybackStartedHandler(_ handler: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        queue.sync { playbackStartedHandler = handler }
    }

    func setPlaybackFinishedHandler(_ handler: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        queue.sync { playbackFinishedHandler = handler }
    }

    func install(_ player: AVAudioPlayerNode) {
        queue.sync {
            self.player = player
            acceptsAudio = false
            responseGeneration &+= 1
            responsePlaybackStartedAt = nil
            scheduledResponseFrames = 0
            completionSentinelScheduled = false
            bufferPolicy.interrupt()
        }
    }

    func removePlayer() {
        queue.sync {
            player?.stop()
            player = nil
            acceptsAudio = false
            responseGeneration &+= 1
            responsePlaybackStartedAt = nil
            scheduledResponseFrames = 0
            completionSentinelScheduled = false
            bufferPolicy.interrupt()
        }
    }

    func schedulePCM16(
        _ data: Data,
        receivedAt: ContinuousClock.Instant = .now
    ) {
        queue.async { [weak self] in
            guard let self, acceptsAudio, let player else { return }
            let sampleCount = data.count / MemoryLayout<Int16>.size
            guard sampleCount > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: Self.format,
                      frameCapacity: AVAudioFrameCount(sampleCount)
                  ),
                  let destination = buffer.floatChannelData?[0]
            else { return }

            buffer.frameLength = AVAudioFrameCount(sampleCount)
            let isFirstBuffer = bufferPolicy.packetCount == 0
            let shouldStart = bufferPolicy.append(
                frameCount: sampleCount,
                receivedAt: receivedAt
            )
            data.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for index in 0 ..< sampleCount {
                    destination[index] = Float(Int16(littleEndian: samples[index])) / 32_768
                }
            }

            if bufferPolicy.usesImmediateStart {
                // Immediate speech deliberately accepts that the network can briefly
                // run dry. A tiny ramp on both edges turns such a starvation into a
                // clean micro-pause instead of the crack/cut produced by a non-zero
                // PCM discontinuity. At 2.5 ms it stays inaudible on contiguous chunks.
                let fadeFrameCount = min(sampleCount / 2, 60)
                for index in 0 ..< fadeFrameCount {
                    let gain = Float(index + 1) / Float(fadeFrameCount)
                    destination[index] *= gain
                    destination[sampleCount - index - 1] *= gain
                }
            } else if isFirstBuffer {
                let fadeFrameCount = min(sampleCount, 120)
                for index in 0 ..< fadeFrameCount {
                    destination[index] *= Float(index + 1) / Float(fadeFrameCount)
                }
            }

            player.scheduleBuffer(buffer)
            scheduledResponseFrames += sampleCount
            if bufferPolicy.lastAppendDetectedUnderflow {
                logger.error(
                    "Audio starvation detected after playback start; gap=\(self.bufferPolicy.latestGapMilliseconds, privacy: .public)ms"
                )
            }
            if shouldStart {
                logger.info(
                    "Stable playback start buffer=\(self.bufferPolicy.bufferedMilliseconds, privacy: .public)ms ratio=\(self.bufferPolicy.productionRatio, privacy: .public) maxGap=\(self.bufferPolicy.maximumGapMilliseconds, privacy: .public)ms"
                )
                startPlayerIfNeeded(player)
            }
        }
    }

    func playArchivedPCM16(
        _ data: Data,
        onFinished: @escaping @Sendable () -> Void
    ) -> Bool {
        queue.sync {
            guard let player else { return false }
            let sampleCount = data.count / MemoryLayout<Int16>.size
            guard sampleCount > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: Self.format,
                      frameCapacity: AVAudioFrameCount(sampleCount)
                  ),
                  let destination = buffer.floatChannelData?[0]
            else { return false }

            buffer.frameLength = AVAudioFrameCount(sampleCount)
            data.withUnsafeBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for index in 0 ..< sampleCount {
                    destination[index] = Float(Int16(littleEndian: samples[index])) / 32_768
                }
            }

            let fadeFrameCount = min(sampleCount / 2, 120)
            if fadeFrameCount > 0 {
                for index in 0 ..< fadeFrameCount {
                    let gain = Float(index + 1) / Float(fadeFrameCount)
                    destination[index] *= gain
                    destination[sampleCount - index - 1] *= gain
                }
            }

            acceptsAudio = false
            player.stop()
            responseGeneration &+= 1
            let archiveGeneration = responseGeneration
            responsePlaybackStartedAt = nil
            scheduledResponseFrames = 0
            completionSentinelScheduled = false
            bufferPolicy.interrupt()

            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                queue.async {
                    guard self.responseGeneration == archiveGeneration else { return }
                    onFinished()
                }
            }
            player.play()
            return true
        }
    }

    func beginResponse(startImmediately: Bool = false) {
        queue.sync {
            acceptsAudio = true
            responseGeneration &+= 1
            responsePlaybackStartedAt = nil
            scheduledResponseFrames = 0
            completionSentinelScheduled = false
            bufferPolicy.beginResponse(startImmediately: startImmediately)
        }
    }

    func finishResponse() -> ContinuousClock.Instant? {
        queue.sync {
            guard let player else { return responsePlaybackStartedAt }
            if bufferPolicy.finishResponse() {
                logger.notice(
                    "Playback waited for complete response buffer=\(self.bufferPolicy.bufferedMilliseconds, privacy: .public)ms ratio=\(self.bufferPolicy.productionRatio, privacy: .public) maxGap=\(self.bufferPolicy.maximumGapMilliseconds, privacy: .public)ms"
                )
                startPlayerIfNeeded(player)
            }
            scheduleResponseCompletionIfNeeded(player)
            return responsePlaybackStartedAt
        }
    }

    func interruptAndDiscard() {
        queue.sync {
            acceptsAudio = false
            // stop() also removes every buffer already scheduled on the node.
            player?.stop()
            responseGeneration &+= 1
            responsePlaybackStartedAt = nil
            scheduledResponseFrames = 0
            completionSentinelScheduled = false
            bufferPolicy.interrupt()
            // stop() discards scheduled speech. Re-prime the node immediately so
            // the following answer does not pay a cold allocation on its first word.
            player?.prepare(withFrameCount: 131_072)
        }
    }

    private func scheduleResponseCompletionIfNeeded(_ player: AVAudioPlayerNode) {
        guard !completionSentinelScheduled else { return }
        completionSentinelScheduled = true
        let generation = responseGeneration

        guard scheduledResponseFrames > 0 else {
            acceptsAudio = false
            let handler = playbackFinishedHandler
            queue.async {
                handler?(ContinuousClock.now)
            }
            return
        }

        // A silent one-frame sentinel is queued after the final speech buffer.
        // Its dataPlayedBack callback marks the audible end, unlike response.done
        // which only means that xAI has finished sending bytes.
        guard let sentinel = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 1),
              let channel = sentinel.floatChannelData?[0]
        else { return }
        sentinel.frameLength = 1
        channel[0] = 0

        player.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            queue.async {
                guard self.responseGeneration == generation else { return }
                self.acceptsAudio = false
                self.scheduledResponseFrames = 0
                self.completionSentinelScheduled = false
                self.bufferPolicy.interrupt()
                // Keep the already allocated player node warm without rendering
                // silence forever between two push-to-talk turns.
                self.player?.pause()
                self.playbackFinishedHandler?(ContinuousClock.now)
            }
        }
    }

    private func startPlayerIfNeeded(_ player: AVAudioPlayerNode) {
        guard !player.isPlaying else { return }
        player.play()
        let startedAt = ContinuousClock.now
        bufferPolicy.playbackDidStart(at: startedAt)
        responsePlaybackStartedAt = startedAt
        playbackStartedHandler?(startedAt)
    }
}

struct PlaybackJitterBufferPolicy: Sendable, Equatable {
    // Five packets represent roughly 2.7–3.9 seconds in the current xAI
    // cadence. Observing that much of the stream catches the long generation
    // stalls that commonly occur around packets 4 and 5, while normal responses
    // still start around one second after their first audio packet.
    static let minimumPacketCount = 5
    static let minimumBufferedMilliseconds = 2_700.0
    static let minimumProductionRatio = 1.65

    private(set) var receivedFrames = 0
    private(set) var packetCount = 0
    private(set) var hasStarted = false
    private(set) var latestGapMilliseconds = 0.0
    private(set) var maximumGapMilliseconds = 0.0
    private(set) var underflowCount = 0
    private(set) var lastAppendDetectedUnderflow = false
    private var isResponseFinished = false
    private var firstPacketReceivedAt: ContinuousClock.Instant?
    private var lastPacketReceivedAt: ContinuousClock.Instant?
    private var playbackStartedAt: ContinuousClock.Instant?
    private var lastUnderflowAt: ContinuousClock.Instant?
    private var startsImmediately = false

    mutating func beginResponse(startImmediately: Bool = false) {
        receivedFrames = 0
        packetCount = 0
        hasStarted = false
        latestGapMilliseconds = 0
        maximumGapMilliseconds = 0
        underflowCount = 0
        lastAppendDetectedUnderflow = false
        isResponseFinished = false
        firstPacketReceivedAt = nil
        lastPacketReceivedAt = nil
        playbackStartedAt = nil
        lastUnderflowAt = nil
        startsImmediately = startImmediately
    }

    mutating func append(
        frameCount: Int,
        receivedAt: ContinuousClock.Instant = .now
    ) -> Bool {
        guard frameCount > 0 else { return false }
        lastAppendDetectedUnderflow = false

        if hasStarted, estimatedReserveMilliseconds(at: receivedAt) <= 0 {
            let isNewStarvation: Bool
            if let lastUnderflowAt {
                isNewStarvation = lastUnderflowAt.duration(to: receivedAt).milliseconds > 50
            } else {
                isNewStarvation = true
            }
            if isNewStarvation {
                underflowCount += 1
                lastAppendDetectedUnderflow = true
                lastUnderflowAt = receivedAt
            }
        }

        receivedFrames += frameCount
        packetCount += 1
        if let lastPacketReceivedAt {
            latestGapMilliseconds = max(
                0,
                lastPacketReceivedAt.duration(to: receivedAt).milliseconds
            )
            maximumGapMilliseconds = max(maximumGapMilliseconds, latestGapMilliseconds)
        } else {
            firstPacketReceivedAt = receivedAt
        }
        lastPacketReceivedAt = receivedAt
        return startIfReady()
    }

    mutating func playbackDidStart(at timestamp: ContinuousClock.Instant) {
        playbackStartedAt = timestamp
    }

    mutating func finishResponse() -> Bool {
        isResponseFinished = true
        return startIfReady()
    }

    mutating func interrupt() {
        beginResponse()
    }

    private mutating func startIfReady() -> Bool {
        guard !hasStarted,
              receivedFrames > 0
        else { return false }

        if !startsImmediately, !isResponseFinished {
            guard packetCount >= Self.minimumPacketCount,
                  bufferedMilliseconds >= Self.minimumBufferedMilliseconds,
                  productionRatio >= Self.minimumProductionRatio
            else { return false }
        }
        hasStarted = true
        return true
    }

    var bufferedMilliseconds: Double {
        Double(receivedFrames) / Double(TeddyAudioFormat.sampleRate) * 1_000
    }

    var usesImmediateStart: Bool { startsImmediately }

    var productionRatio: Double {
        guard let firstPacketReceivedAt, let lastPacketReceivedAt else { return 0 }
        let elapsed = firstPacketReceivedAt.duration(to: lastPacketReceivedAt).milliseconds
        if elapsed <= 0 { return .infinity }
        return bufferedMilliseconds / elapsed
    }

    func estimatedReserveMilliseconds(at timestamp: ContinuousClock.Instant) -> Double {
        guard let playbackStartedAt else { return bufferedMilliseconds }
        return bufferedMilliseconds
            - playbackStartedAt.duration(to: timestamp).milliseconds
    }
}

private enum AudioTapInstaller {
    // About 15 ms at the common 48 kHz hardware rate. The actual callback size is device-dependent.
    static func install(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        processor: MicrophonePCMProcessor
    ) {
        input.installTap(onBus: 0, bufferSize: 720, format: format) { buffer, _ in
            processor.process(buffer)
        }
    }
}

private final class MicrophonePCMProcessor: @unchecked Sendable {
    private let sourceFramesPerOutputFrame: Double
    private let handler: MicrophonePCMHandler
    private let lock = NSLock()
    private var isCapturing = false
    private var capturedChunkCount = 0
    private var capturedByteCount = 0
    private var nextSourceFrame = 0.0

    init(inputSampleRate: Double, handler: @escaping MicrophonePCMHandler) {
        sourceFramesPerOutputFrame = inputSampleRate / Double(TeddyAudioFormat.sampleRate)
        self.handler = handler
    }

    func beginCapture() {
        lock.withLock {
            capturedChunkCount = 0
            capturedByteCount = 0
            nextSourceFrame = 0
            isCapturing = true
        }
    }

    func endCapture() -> MicrophoneCaptureSummary {
        lock.withLock {
            isCapturing = false
            return MicrophoneCaptureSummary(
                chunkCount: capturedChunkCount,
                byteCount: capturedByteCount
            )
        }
    }

    func process(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            // The audio engine stays warm, but an idle tap exits here: no conversion,
            // allocation or network data exists outside an explicit PTT gesture.
            guard isCapturing,
                  input.frameLength > 0,
                  let source = input.floatChannelData?[0]
            else { return }

            let sourceFrameCount = Int(input.frameLength)
            var output: [Int16] = []
            output.reserveCapacity(Int(ceil(Double(sourceFrameCount) / sourceFramesPerOutputFrame)))

            while nextSourceFrame < Double(sourceFrameCount) {
                let index = min(Int(nextSourceFrame), sourceFrameCount - 1)
                let sample = max(-1, min(1, source[index]))
                let scaled = sample < 0 ? sample * 32_768 : sample * 32_767
                output.append(Int16(scaled.rounded()))
                nextSourceFrame += sourceFramesPerOutputFrame
            }
            nextSourceFrame -= Double(sourceFrameCount)

            guard !output.isEmpty else { return }
            output.withUnsafeBytes {
                let data = Data($0)
                capturedChunkCount += 1
                capturedByteCount += data.count
                // endCapture() takes the same lock, so commit can never overtake
                // the final audio frame in the WebSocket send queue.
                handler(data)
            }
        }
    }
}

enum RealtimeAudioError: LocalizedError {
    case noMicrophoneFormat

    var errorDescription: String? {
        switch self {
        case .noMicrophoneFormat: "Aucun format microphone utilisable n’est disponible."
        }
    }
}
