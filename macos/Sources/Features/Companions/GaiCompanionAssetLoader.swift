#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO

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

    /// Allows a debug tool to retry after changing the environment or replacing files.
    func invalidate() {
        atlases.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
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
