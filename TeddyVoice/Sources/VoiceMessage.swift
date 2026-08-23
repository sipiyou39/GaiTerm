import Foundation

struct VoiceMessage: Identifiable, Codable, Sendable, Equatable {
    enum Sender: String, Codable, Sendable, Equatable {
        case user
        case teddy
    }

    enum Phase: String, Codable, Sendable, Equatable {
        case sent
        case buffering
        case playing
        case ready
        case interrupted
    }

    let id: UUID
    let sender: Sender
    let createdAt: Date
    var transcript: String
    var durationSeconds: Double
    var waveform: [Double]
    var phase: Phase

    init(
        id: UUID = UUID(),
        sender: Sender,
        createdAt: Date = .now,
        transcript: String = "",
        durationSeconds: Double = 0,
        waveform: [Double] = [],
        phase: Phase
    ) {
        self.id = id
        self.sender = sender
        self.createdAt = createdAt
        self.transcript = transcript
        self.durationSeconds = durationSeconds
        self.waveform = waveform
        self.phase = phase
    }
}

enum VoiceWaveform {
    static let maximumVisibleSamples = 72

    static func peakLevel(inPCM16 data: Data) -> Double {
        var peakMagnitude = 0
        data.withUnsafeBytes { bytes in
            for sample in bytes.bindMemory(to: Int16.self) {
                let value = Int(Int16(littleEndian: sample))
                let magnitude = value == Int(Int16.min) ? Int(Int16.max) : abs(value)
                peakMagnitude = max(peakMagnitude, magnitude)
            }
        }
        return Double(peakMagnitude) / Double(Int16.max)
    }

    static func appending(_ level: Double, to samples: [Double]) -> [Double] {
        appending(contentsOf: [level], to: samples)
    }

    static func appending(contentsOf levels: [Double], to samples: [Double]) -> [Double] {
        var result = samples
        result.append(contentsOf: levels.map { $0.teddyClamped(to: 0 ... 1) })
        if result.count > maximumVisibleSamples {
            result = compacted(result, targetCount: maximumVisibleSamples)
        }
        return result
    }

    /// Builds a time-accurate, perceptually scaled envelope. Network packets do
    /// not have uniform durations, so one bar per packet produces a misleading
    /// and visually crude waveform. Every returned bar represents the same
    /// amount of audio instead.
    static func displaySamples(
        inPCM16 data: Data,
        targetCount: Int = maximumVisibleSamples
    ) -> [Double] {
        guard targetCount > 0 else { return [] }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }

        var energy = Array(repeating: 0.0, count: targetCount)
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for bucket in 0 ..< targetCount {
                let lower = bucket * sampleCount / targetCount
                let upper = max(lower + 1, (bucket + 1) * sampleCount / targetCount)
                let safeUpper = min(upper, sampleCount)
                let stride = max(1, (safeUpper - lower) / 256)
                var squaredSum = 0.0
                var measured = 0
                var index = lower
                while index < safeUpper {
                    let value = Double(Int16(littleEndian: samples[index])) / 32_768
                    squaredSum += value * value
                    measured += 1
                    index += stride
                }
                energy[bucket] = measured > 0 ? sqrt(squaredSum / Double(measured)) : 0
            }
        }

        let sortedEnergy = energy.sorted()
        let referenceIndex = min(
            sortedEnergy.count - 1,
            Int(Double(sortedEnergy.count - 1) * 0.92)
        )
        let reference = max(0.012, sortedEnergy[referenceIndex])
        let normalized = energy.map { value in
            pow(min(1, value / reference), 0.58)
        }

        return normalized.indices.map { index in
            let previous = normalized[max(0, index - 1)]
            let current = normalized[index]
            let next = normalized[min(normalized.count - 1, index + 1)]
            return (previous * 0.18 + current * 0.64 + next * 0.18)
                .teddyClamped(to: 0 ... 1)
        }
    }

    static func compacted(_ samples: [Double], targetCount: Int = maximumVisibleSamples) -> [Double] {
        guard targetCount > 0, samples.count > targetCount else { return samples }

        var result: [Double] = []
        result.reserveCapacity(targetCount)
        for bucket in 0 ..< targetCount {
            let lowerBound = bucket * samples.count / targetCount
            let upperBound = max(lowerBound + 1, (bucket + 1) * samples.count / targetCount)
            result.append(samples[lowerBound ..< min(upperBound, samples.count)].max() ?? 0)
        }
        return result
    }
}

final class VoiceTurnAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var isRecording = false
    private var audio = Data()

    func begin(reservingSeconds: Int = 30) {
        lock.withLock {
            audio.removeAll(keepingCapacity: true)
            audio.reserveCapacity(TeddyAudioFormat.pcm16MonoBytesPerSecond * reservingSeconds)
            isRecording = true
        }
    }

    func append(_ data: Data) {
        lock.withLock {
            guard isRecording else { return }
            audio.append(data)
        }
    }

    func finish() -> Data {
        lock.withLock {
            isRecording = false
            return audio
        }
    }

    func cancel() {
        lock.withLock {
            isRecording = false
            audio.removeAll(keepingCapacity: true)
        }
    }
}

private extension Double {
    func teddyClamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
