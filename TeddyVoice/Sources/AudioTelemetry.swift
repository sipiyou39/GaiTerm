import Foundation

final class AudioTelemetry: @unchecked Sendable {
    struct Snapshot: Sendable {
        let peakLevel: Double
    }

    private let lock = NSLock()
    private var peakLevel = 0.0

    func reset() {
        lock.withLock { peakLevel = 0 }
    }

    func recordMicrophone(_ pcm16: Data) {
        var peakMagnitude = 0
        pcm16.withUnsafeBytes { bytes in
            for sample in bytes.bindMemory(to: Int16.self) {
                let magnitude = sample == .min ? Int(Int16.max) : abs(Int(sample))
                peakMagnitude = max(peakMagnitude, magnitude)
            }
        }

        lock.withLock {
            peakLevel = Double(peakMagnitude) / Double(Int16.max)
        }
    }

    func markInputIdle() {
        lock.withLock { peakLevel = 0 }
    }

    func snapshot() -> Snapshot {
        lock.withLock { makeSnapshot() }
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(peakLevel: peakLevel)
    }
}
