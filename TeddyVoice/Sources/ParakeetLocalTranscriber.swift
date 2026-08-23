@preconcurrency import FluidAudio
import Foundation
import OSLog

struct ParakeetTranscription: Sendable, Equatable {
    let text: String
    let inferenceMilliseconds: Double
}

enum ParakeetLocalError: LocalizedError {
    case modelMissing(String)
    case emptyAudio
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path):
            "Le modèle Parakeet local est introuvable dans le cache existant : \(path)"
        case .emptyAudio:
            "Parakeet n’a reçu aucun échantillon audio."
        case .emptyTranscript:
            "Parakeet n’a reconnu aucun texte."
        }
    }
}

/// Owns the already-installed Parakeet model and keeps its manager hot in RAM.
/// It deliberately has no download path: Teddy CLI reuses FluidAudio's shared
/// global cache instead of creating an application-specific duplicate.
actor ParakeetLocalTranscriber {
    static let sourceSampleRate = 24_000
    static let modelSampleRate = 16_000

    private let logger = Logger(
        subsystem: "com.sipiyou.teddycli",
        category: "parakeet"
    )
    private var manager: AsrManager?
    private var preparationTask: Task<AsrManager, Error>?

    var isReady: Bool { manager != nil }

    func prepare() async throws {
        _ = try await preparedManager()
    }

    func transcribe(pcm16At24kHz audio: Data) async throws -> ParakeetTranscription {
        guard !audio.isEmpty else { throw ParakeetLocalError.emptyAudio }
        let manager = try await preparedManager()
        try Task.checkCancellation()

        let samples = Self.resamplePCM16From24kHzTo16kHz(audio)
        guard !samples.isEmpty else { throw ParakeetLocalError.emptyAudio }

        let startedAt = ContinuousClock.now
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState,
            language: .french
        )
        try Task.checkCancellation()

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParakeetLocalError.emptyTranscript }
        let elapsed = startedAt.duration(to: .now).milliseconds
        logger.info(
            "Parakeet local ready in \(elapsed, privacy: .public)ms for \(Double(samples.count) / 16_000, privacy: .public)s"
        )
        return ParakeetTranscription(text: text, inferenceMilliseconds: elapsed)
    }

    private func preparedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let preparationTask { return try await preparationTask.value }

        let cacheDirectory = AsrModels.defaultCacheDirectory(for: .v3)
        guard AsrModels.modelsExist(
            at: cacheDirectory,
            version: .v3,
            encoderPrecision: .int8
        ) else {
            throw ParakeetLocalError.modelMissing(cacheDirectory.path)
        }

        logger.info("Loading Parakeet strictly from FluidAudio's shared cache: \(cacheDirectory.path, privacy: .public)")
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.load(
                from: cacheDirectory,
                version: .v3,
                encoderPrecision: .int8
            )
            return AsrManager(config: .default, models: models)
        }
        preparationTask = task

        do {
            let loaded = try await task.value
            manager = loaded
            preparationTask = nil
            logger.info("Parakeet model is hot in memory")
            return loaded
        } catch {
            preparationTask = nil
            throw error
        }
    }

    static func resamplePCM16From24kHzTo16kHz(_ data: Data) -> [Float] {
        let sourceCount = data.count / MemoryLayout<Int16>.size
        guard sourceCount > 1 else { return [] }
        let outputCount = Int((Double(sourceCount) * 2 / 3).rounded(.down))
        guard outputCount > 0 else { return [] }

        return data.withUnsafeBytes { rawBuffer -> [Float] in
            let source = rawBuffer.bindMemory(to: Int16.self)
            var output = [Float]()
            output.reserveCapacity(outputCount)

            for outputIndex in 0 ..< outputCount {
                let sourcePosition = Double(outputIndex) * 1.5
                let lowerIndex = min(Int(sourcePosition), sourceCount - 1)
                let upperIndex = min(lowerIndex + 1, sourceCount - 1)
                let fraction = Float(sourcePosition - Double(lowerIndex))
                let lower = Float(Int16(littleEndian: source[lowerIndex])) / 32_768
                let upper = Float(Int16(littleEndian: source[upperIndex])) / 32_768
                output.append(lower + (upper - lower) * fraction)
            }
            return output
        }
    }
}
