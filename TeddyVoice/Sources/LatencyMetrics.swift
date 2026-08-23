import Foundation

struct LatencyMetrics: Sendable, Equatable {
    var connectionMilliseconds: Double?
    var releaseToTranscriptionMilliseconds: Double?
    var releaseToFirstTokenMilliseconds: Double?
    var releaseToResponseMilliseconds: Double?
    var releaseToFirstAudioMilliseconds: Double?
    var releaseToPlaybackMilliseconds: Double?
    var lastCaptureMilliseconds: Double?

    var responseToFirstAudioMilliseconds: Double? {
        guard let releaseToResponseMilliseconds,
              let releaseToFirstAudioMilliseconds
        else { return nil }
        return max(0, releaseToFirstAudioMilliseconds - releaseToResponseMilliseconds)
    }

    var firstPacketToPlaybackMilliseconds: Double? {
        guard let releaseToFirstAudioMilliseconds,
              let releaseToPlaybackMilliseconds
        else { return nil }
        return max(0, releaseToPlaybackMilliseconds - releaseToFirstAudioMilliseconds)
    }

    mutating func resetTurn() {
        releaseToTranscriptionMilliseconds = nil
        releaseToFirstTokenMilliseconds = nil
        releaseToResponseMilliseconds = nil
        releaseToFirstAudioMilliseconds = nil
        releaseToPlaybackMilliseconds = nil
        lastCaptureMilliseconds = nil
    }
}

extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
