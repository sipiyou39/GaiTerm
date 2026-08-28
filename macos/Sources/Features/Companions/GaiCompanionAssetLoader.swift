#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Compact alpha-only representation of one rendered sprite frame.
///
/// Pointer tracking samples this mask instead of the transparent AppKit panel,
/// so moving across empty pixels around a doudou never counts as hovering it.
/// Keeping one byte per source pixel makes the hot path a single indexed read.
struct GaiCompanionAlphaMask: Equatable {
    let width: Int
    let height: Int
    private let alpha: [UInt8]

    init?(image: CGImage) {
        guard image.width > 0,
              image.height > 0,
              image.bitsPerComponent == 8,
              image.bitsPerPixel.isMultiple(of: 8),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }

        let bytesPerPixel = image.bitsPerPixel / 8
        let conceptualAlphaOffset: Int
        switch image.alphaInfo {
        case .premultipliedLast, .last:
            conceptualAlphaOffset = bytesPerPixel - 1
        case .premultipliedFirst, .first:
            conceptualAlphaOffset = 0
        case .alphaOnly:
            conceptualAlphaOffset = 0
        case .none, .noneSkipFirst, .noneSkipLast:
            return nil
        @unknown default:
            return nil
        }

        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let alphaOffset = if bytesPerPixel > 1,
                             byteOrder == .byteOrder32Little {
            bytesPerPixel - 1 - conceptualAlphaOffset
        } else {
            conceptualAlphaOffset
        }

        var alpha = [UInt8](repeating: 0, count: image.width * image.height)
        for row in 0..<image.height {
            let sourceRow = bytes + row * image.bytesPerRow
            let destinationRow = row * image.width
            for column in 0..<image.width {
                alpha[destinationRow + column] = sourceRow[
                    column * bytesPerPixel + alphaOffset]
            }
        }

        width = image.width
        height = image.height
        self.alpha = alpha
    }

    /// Coordinates use the image convention: `(0, 0)` is the top-left and
    /// `(1, 1)` is just beyond the bottom-right edge.
    func contains(
        normalizedX: CGFloat,
        normalizedY: CGFloat,
        threshold: UInt8 = 24
    ) -> Bool {
        guard normalizedX >= 0,
              normalizedX < 1,
              normalizedY >= 0,
              normalizedY < 1 else { return false }
        let column = min(Int(normalizedX * CGFloat(width)), width - 1)
        let row = min(Int(normalizedY * CGFloat(height)), height - 1)
        return alpha[row * width + column] >= threshold
    }
}

/// Resolves and caches the checked-in atlases packaged with every macOS build.
/// A local atlas pack may still be tested with
/// `GAITERM_COMPANION_ASSETS_DIR=/path/to/companions`.
@MainActor
final class GaiCompanionAtlasCache {
    static let shared = GaiCompanionAtlasCache()

    static let assetsDirectoryEnvironmentKey = "GAITERM_COMPANION_ASSETS_DIR"

    private struct FrameKey: Hashable {
        let colorway: GaiCompanionColorway
        let row: Int
        let column: Int
    }

    private var atlases: [GaiCompanionColorway: CGImage] = [:]
    private var frames: [FrameKey: CGImage] = [:]
    private var alphaMasks: [FrameKey: GaiCompanionAlphaMask] = [:]
    private var attemptedColorways: Set<GaiCompanionColorway> = []

    private init() {}

    /// Returns a validated 1536×1872 atlas, or `nil` so the view can render its fallback.
    func atlas(for colorway: GaiCompanionColorway) -> CGImage? {
        if let cached = atlases[colorway] {
            return cached
        }
        guard attemptedColorways.insert(colorway).inserted else {
            return nil
        }

        for root in Self.candidateAssetDirectories() {
            let url = root
                .appendingPathComponent(colorway.rawValue, isDirectory: true)
                .appendingPathComponent("spritesheet.webp", isDirectory: false)
            guard let image = Self.decodeAtlas(at: url) else { continue }
            atlases[colorway] = image
            return image
        }

        return nil
    }

    /// Crops lazily and shares decoded frame images between every visible companion.
    func frame(
        for colorway: GaiCompanionColorway,
        atlas: CGImage,
        row: Int,
        column: Int
    ) -> CGImage? {
        guard (0 ..< GaiCompanionAtlas.rows).contains(row),
              (0 ..< GaiCompanionAtlas.columns).contains(column)
        else { return nil }

        let key = FrameKey(colorway: colorway, row: row, column: column)
        if let cached = frames[key] {
            return cached
        }

        let crop = CGRect(
            x: column * GaiCompanionAtlas.cellWidth,
            y: row * GaiCompanionAtlas.cellHeight,
            width: GaiCompanionAtlas.cellWidth,
            height: GaiCompanionAtlas.cellHeight)
        guard let frame = atlas.cropping(to: crop) else { return nil }
        frames[key] = frame
        return frame
    }

    /// Builds an alpha mask only once for every lazily cropped animation cell.
    func alphaMask(
        for colorway: GaiCompanionColorway,
        frame: CGImage,
        row: Int,
        column: Int
    ) -> GaiCompanionAlphaMask? {
        let key = FrameKey(colorway: colorway, row: row, column: column)
        if let cached = alphaMasks[key] {
            return cached
        }
        guard let mask = GaiCompanionAlphaMask(image: frame) else { return nil }
        alphaMasks[key] = mask
        return mask
    }

    /// Allows a debug tool to retry after changing the environment or replacing files.
    func invalidate() {
        atlases.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        alphaMasks.removeAll(keepingCapacity: true)
        attemptedColorways.removeAll(keepingCapacity: true)
    }

    static func candidateAssetDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Companions", isDirectory: true))
        }
        if let override = environment[assetsDirectoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded = NSString(string: override).expandingTildeInPath
            let overrideURL = URL(fileURLWithPath: expanded, isDirectory: true)
            candidates.append(overrideURL)
            if overrideURL.lastPathComponent != "companions" {
                candidates.append(overrideURL.appendingPathComponent("companions", isDirectory: true))
            }
        }
        var seenPaths: Set<String> = []
        return candidates.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private static func decodeAtlas(at url: URL) -> CGImage? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == GaiCompanionAtlas.width,
              image.height == GaiCompanionAtlas.height
        else { return nil }

        return image
    }
}
#endif
