#if os(macOS)
import Foundation

/// Rendering metadata for the persisted colorway model.
extension GaiCompanionColorway: Identifiable {
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aurore: "Aurore"
        case .blue: "Blue"
        case .purple: "Purple"
        case .black: "Black"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .red: "Red"
        case .gray: "Gray"
        case .white: "White"
        }
    }

    var palette: GaiCompanionPalette {
        switch self {
        case .aurore: .init(shadowRGB: 0x3CA995, baseRGB: 0x83CF8C, lightRGB: 0xF2BE4F)
        case .blue: .init(shadowRGB: 0x2945A6, baseRGB: 0x5277EC, lightRGB: 0x91C8FF)
        case .purple: .init(shadowRGB: 0x6035A8, baseRGB: 0x9460E2, lightRGB: 0xD8A5FF)
        case .black: .init(shadowRGB: 0x090C12, baseRGB: 0x202631, lightRGB: 0x657085)
        case .yellow: .init(shadowRGB: 0x9A6500, baseRGB: 0xE8B817, lightRGB: 0xFFF397)
        case .orange: .init(shadowRGB: 0xBB4C16, baseRGB: 0xF27B25, lightRGB: 0xFFD159)
        case .red: .init(shadowRGB: 0x791323, baseRGB: 0xD52F3F, lightRGB: 0xFF776D)
        case .gray: .init(shadowRGB: 0x2F374C, baseRGB: 0x64708B, lightRGB: 0xBBC5D8)
        case .white: .init(shadowRGB: 0x748196, baseRGB: 0xDDE4EF, lightRGB: 0xFFFFFF)
        }
    }
}

/// RGB values used by the asset-free fallback and future companion controls.
struct GaiCompanionPalette: Equatable, Sendable {
    let shadowRGB: UInt32
    let baseRGB: UInt32
    let lightRGB: UInt32
}

/// Animation rows mirror the development atlas contract in GaiWork.
enum GaiCompanionAnimation: String, CaseIterable, Identifiable, Sendable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case thinking
    case working
    case ready

    var id: String { rawValue }

    var definition: GaiCompanionAnimationDefinition {
        switch self {
        case .idle:
            .init(row: 0, frameDurationsMilliseconds: [1680, 660, 660, 840, 840, 1920], loops: true)
        case .runningRight:
            .init(row: 1, frameDurationsMilliseconds: [120, 120, 120, 120, 120, 120, 120, 220], loops: true)
        case .runningLeft:
            .init(row: 2, frameDurationsMilliseconds: [120, 120, 120, 120, 120, 120, 120, 220], loops: true)
        case .waving:
            .init(row: 3, frameDurationsMilliseconds: [140, 140, 140, 280], loops: false)
        case .jumping:
            .init(row: 4, frameDurationsMilliseconds: [140, 140, 140, 140, 280], loops: false)
        case .failed:
            .init(row: 5, frameDurationsMilliseconds: [140, 140, 140, 140, 140, 140, 140, 240], loops: false)
        case .thinking:
            .init(row: 6, frameDurationsMilliseconds: [150, 150, 150, 150, 150, 260], loops: true)
        case .working:
            .init(row: 7, frameDurationsMilliseconds: [120, 120, 120, 120, 120, 220], loops: true)
        case .ready:
            .init(row: 8, frameDurationsMilliseconds: [150, 150, 150, 150, 150, 280], loops: false)
        }
    }

    var reducedMotionFrame: Int {
        switch self {
        case .failed, .ready: definition.frameCount - 1
        default: 0
        }
    }

    /// Attention animations may repeat even though their atlas definition is a
    /// one-shot. A zero delay makes jumping restart on the exact cycle boundary,
    /// matching GaiWork without changing the semantics of the other one-shots.
    var repeatDelayMilliseconds: Int? {
        switch self {
        case .jumping: 0
        default: nil
        }
    }

    func frame(at elapsedSeconds: TimeInterval, reduceMotion: Bool) -> Int {
        if reduceMotion {
            return reducedMotionFrame
        }

        let definition = definition
        let total = definition.durationMilliseconds
        guard total > 0 else { return 0 }

        let elapsedMilliseconds = max(0, elapsedSeconds * 1_000)
        let cursor: Double
        if definition.loops {
            cursor = elapsedMilliseconds.truncatingRemainder(dividingBy: Double(total))
        } else if let repeatDelayMilliseconds {
            let cycleDuration = total + max(0, repeatDelayMilliseconds)
            guard cycleDuration > 0 else { return 0 }
            cursor = elapsedMilliseconds.truncatingRemainder(
                dividingBy: Double(cycleDuration))
            if cursor >= Double(total) {
                return definition.frameCount - 1
            }
        } else if elapsedMilliseconds >= Double(total) {
            return definition.frameCount - 1
        } else {
            cursor = elapsedMilliseconds
        }

        var boundary = 0
        for (frame, duration) in definition.frameDurationsMilliseconds.enumerated() {
            boundary += duration
            if cursor < Double(boundary) {
                return frame
            }
        }

        return definition.frameCount - 1
    }

    /// The exact delay before the rendered atlas cell can change.
    ///
    /// `nil` means the animation is on a persistent frame (or Reduce Motion is
    /// enabled), so a renderer can remain completely dormant until its state is
    /// explicitly refreshed.
    func timeUntilNextFrame(
        at elapsedSeconds: TimeInterval,
        reduceMotion: Bool
    ) -> TimeInterval? {
        guard !reduceMotion else { return nil }

        let definition = definition
        let total = definition.durationMilliseconds
        guard total > 0 else { return nil }

        let elapsedMilliseconds = max(0, elapsedSeconds * 1_000)
        let cursor: Double
        let cycleDuration: Int?

        if definition.loops {
            cycleDuration = total
            cursor = elapsedMilliseconds.truncatingRemainder(dividingBy: Double(total))
        } else if let repeatDelayMilliseconds {
            let duration = total + max(0, repeatDelayMilliseconds)
            guard duration > 0 else { return nil }
            cycleDuration = duration
            cursor = elapsedMilliseconds.truncatingRemainder(dividingBy: Double(duration))
            if cursor >= Double(total) {
                return millisecondsToSeconds(max(1, Double(duration) - cursor))
            }
        } else {
            cycleDuration = nil
            guard elapsedMilliseconds < Double(total) else { return nil }
            cursor = elapsedMilliseconds
        }

        var boundary = 0
        for (frame, duration) in definition.frameDurationsMilliseconds.enumerated() {
            boundary += duration
            guard cursor < Double(boundary) else { continue }

            let isFinalFrame = frame == definition.frameCount - 1
            if cycleDuration == nil, isFinalFrame {
                return nil
            }
            if let cycleDuration, isFinalFrame {
                return millisecondsToSeconds(max(1, Double(cycleDuration) - cursor))
            }
            return millisecondsToSeconds(max(1, Double(boundary) - cursor))
        }

        return nil
    }

    private func millisecondsToSeconds(_ milliseconds: Double) -> TimeInterval {
        milliseconds / 1_000
    }
}

/// Pixel geometry shared by all nine companion atlases.
enum GaiCompanionAtlas {
    static let width = 1_536
    static let height = 1_872
    static let columns = 8
    static let rows = 9
    static let cellWidth = 192
    static let cellHeight = 208

    static var cellAspectRatio: Double {
        Double(cellWidth) / Double(cellHeight)
    }
}

struct GaiCompanionAnimationDefinition: Sendable {
    let row: Int
    let frameDurationsMilliseconds: [Int]
    let loops: Bool

    var frameCount: Int { frameDurationsMilliseconds.count }
    var durationMilliseconds: Int { frameDurationsMilliseconds.reduce(0, +) }
}
#endif
