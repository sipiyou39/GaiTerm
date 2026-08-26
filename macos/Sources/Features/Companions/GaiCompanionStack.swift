#if os(macOS)
import AppKit
import Foundation

enum GaiCompanionStackMode: String, CaseIterable, Identifiable, Sendable {
    case organicGrid = "organic-grid"
    case freeform = "freeform"

    var id: String { rawValue }

    static func current(in userDefaults: UserDefaults) -> Self {
        guard let rawValue = userDefaults.string(
            forKey: GaiPreferenceKey.companionStackMode),
            let mode = Self(rawValue: rawValue) else { return .organicGrid }
        return mode
    }
}

struct GaiCompanionHubPlacement: Codable, Equatable, Sendable {
    static let persistenceKey = "gai.companion.hub-placement.v1"

    var normalizedPosition: GaiCompanionNormalizedPosition
    var displayID: String?

    init(
        normalizedPosition: GaiCompanionNormalizedPosition,
        displayID: String?
    ) {
        self.normalizedPosition = normalizedPosition
        let cleaned = displayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayID = cleaned?.isEmpty == false ? cleaned : nil
    }

    init?(userDefaults: UserDefaults) {
        guard let data = userDefaults.data(forKey: Self.persistenceKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self.init(
            normalizedPosition: decoded.normalizedPosition,
            displayID: decoded.displayID)
    }

    @discardableResult
    func persist(to userDefaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        userDefaults.set(data, forKey: Self.persistenceKey)
        return true
    }
}

/// One persistent cell in the companion constellation. The coordinate system
/// is intentionally abstract: the stack chooses its screen orientation every
/// time it opens, so a shape survives display and Dock changes.
struct GaiCompanionStackCoordinate: Codable, Equatable, Hashable, Sendable {
    var column: Int
    var row: Int

    static let origin = Self(column: 0, row: 0)

    init(column: Int, row: Int) {
        self.column = min(max(column, -64), 64)
        self.row = min(max(row, -64), 64)
    }

    var neighbours: [Self] {
        [
            Self(column: column + 1, row: row),
            Self(column: column - 1, row: row),
            Self(column: column, row: row + 1),
            Self(column: column, row: row - 1),
        ]
    }
}

/// One of the eight rigid symmetries of a square. Trying all of them lets the
/// constellation bloom into available space without moving its free anchor.
enum GaiCompanionStackOrientation: Int, CaseIterable, Equatable, Sendable {
    case identity
    case mirrorX
    case mirrorY
    case rotate180
    case transpose
    case transposeMirrorX
    case transposeMirrorY
    case transposeRotate180

    func applying(to coordinate: GaiCompanionStackCoordinate) -> GaiCompanionStackCoordinate {
        let x = coordinate.column
        let y = coordinate.row
        return switch self {
        case .identity: .init(column: x, row: y)
        case .mirrorX: .init(column: -x, row: y)
        case .mirrorY: .init(column: x, row: -y)
        case .rotate180: .init(column: -x, row: -y)
        case .transpose: .init(column: y, row: x)
        case .transposeMirrorX: .init(column: -y, row: x)
        case .transposeMirrorY: .init(column: y, row: -x)
        case .transposeRotate180: .init(column: -y, row: -x)
        }
    }

    func removing(from coordinate: GaiCompanionStackCoordinate) -> GaiCompanionStackCoordinate {
        let x = coordinate.column
        let y = coordinate.row
        return switch self {
        case .identity: .init(column: x, row: y)
        case .mirrorX: .init(column: -x, row: y)
        case .mirrorY: .init(column: x, row: -y)
        case .rotate180: .init(column: -x, row: -y)
        case .transpose: .init(column: y, row: x)
        case .transposeMirrorX: .init(column: y, row: -x)
        case .transposeMirrorY: .init(column: -y, row: x)
        case .transposeRotate180: .init(column: -y, row: -x)
        }
    }
}

struct GaiCompanionStackResolvedLayout: Equatable {
    let orientation: GaiCompanionStackOrientation
    let anchorCenter: CGPoint
    let cellSize: CGSize
    let frames: [UUID: NSRect]

    func coordinate(
        nearest screenPoint: CGPoint,
        anchorCoordinate: GaiCompanionStackCoordinate
    ) -> GaiCompanionStackCoordinate {
        let oriented = GaiCompanionStackCoordinate(
            column: Int(((screenPoint.x - anchorCenter.x) / max(cellSize.width, 1)).rounded()),
            row: Int(((screenPoint.y - anchorCenter.y) / max(cellSize.height, 1)).rounded()))
        let relative = orientation.removing(from: oriented)
        return GaiCompanionStackCoordinate(
            column: anchorCoordinate.column + relative.column,
            row: anchorCoordinate.row + relative.row)
    }
}

enum GaiCompanionStackLayout {
    // Panel bounds include generous transparent drag space. Organic cells use
    // the mascot's visual footprint instead: five points of air around a
    // standard sprite horizontally, and just enough vertical pitch for the
    // name badge plus the three quick actions above a selected mascot.
    private static let horizontalPitchRatio = CGFloat(122)
        / CGFloat(GaiCompanionVisualMetrics.basePanelWidth)
    private static let verticalPitchRatio = CGFloat(160)
        / CGFloat(GaiCompanionVisualMetrics.basePanelHeight)

    /// A compact, always-connected seed shape used for old agents and new
    /// hires. It fills a near-square block from the anchor corner.
    static func defaultCoordinates(count: Int) -> [GaiCompanionStackCoordinate] {
        guard count > 0 else { return [] }
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        return (0..<count).map { index in
            GaiCompanionStackCoordinate(
                column: index % columns,
                row: index / columns)
        }
    }

    static func firstAvailableConnectedCoordinate(
        occupied: Set<GaiCompanionStackCoordinate>
    ) -> GaiCompanionStackCoordinate {
        guard !occupied.isEmpty else { return .origin }
        let frontier = Array(occupied).sorted(by: coordinateOrder)
        var visited = occupied
        var index = 0
        while index < frontier.count {
            let coordinate = frontier[index]
            index += 1
            for neighbour in coordinate.neighbours.sorted(by: coordinateOrder) {
                if occupied.contains(neighbour) { continue }
                if visited.insert(neighbour).inserted { return neighbour }
            }
        }
        return .origin
    }

    static func isConnected(_ coordinates: Set<GaiCompanionStackCoordinate>) -> Bool {
        guard let first = coordinates.first else { return true }
        var visited: Set<GaiCompanionStackCoordinate> = [first]
        var frontier = [first]
        var index = 0
        while index < frontier.count {
            let coordinate = frontier[index]
            index += 1
            for neighbour in coordinate.neighbours
                where coordinates.contains(neighbour) && visited.insert(neighbour).inserted {
                frontier.append(neighbour)
            }
        }
        return visited.count == coordinates.count
    }

    static func canMove(
        from source: GaiCompanionStackCoordinate,
        to destination: GaiCompanionStackCoordinate,
        occupied: Set<GaiCompanionStackCoordinate>
    ) -> Bool {
        guard source != destination,
              occupied.contains(source),
              !occupied.contains(destination) else { return false }
        var result = occupied
        result.remove(source)
        result.insert(destination)
        return isConnected(result)
    }

    static func resolve(
        ids: [UUID],
        coordinates: [UUID: GaiCompanionStackCoordinate],
        sizes: [UUID: CGSize],
        anchorID: UUID,
        anchorFrame: NSRect,
        workArea: NSRect,
        preferredOrientation: GaiCompanionStackOrientation? = nil
    ) -> GaiCompanionStackResolvedLayout {
        let maximumWidth = ids.compactMap { sizes[$0]?.width }.max() ?? anchorFrame.width
        let maximumHeight = ids.compactMap { sizes[$0]?.height }.max() ?? anchorFrame.height
        let cellSize = CGSize(
            width: max(1, maximumWidth * horizontalPitchRatio),
            height: max(1, maximumHeight * verticalPitchRatio))
        let anchorCoordinate = coordinates[anchorID] ?? .origin
        let orientations = preferredOrientation.map { [$0] }
            ?? GaiCompanionStackOrientation.allCases

        let candidates = orientations.map { orientation -> (GaiCompanionStackOrientation, [UUID: NSRect], CGFloat) in
            let rawFrames = frames(
                ids: ids,
                coordinates: coordinates,
                sizes: sizes,
                anchorCoordinate: anchorCoordinate,
                anchorCenter: CGPoint(x: anchorFrame.midX, y: anchorFrame.midY),
                cellSize: cellSize,
                orientation: orientation)
            let overflow = rawFrames.values.reduce(CGFloat.zero) { result, frame in
                result
                    + squared(max(0, workArea.minX - frame.minX))
                    + squared(max(0, frame.maxX - workArea.maxX))
                    + squared(max(0, workArea.minY - frame.minY))
                    + squared(max(0, frame.maxY - workArea.maxY))
            }
            return (orientation, rawFrames, overflow)
        }
        let selected = candidates.min { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            return lhs.0.rawValue < rhs.0.rawValue
        } ?? (.identity, [:], 0)

        // The representative is a physical desktop object chosen by the user.
        // Its position wins over fitting the constellation: orientations are
        // tried to minimise overflow, but expansion never translates the
        // anchor away from the Dock, a screen edge or a hand-picked alignment.
        let resolvedFrames = selected.1
        let resolvedAnchor = resolvedFrames[anchorID] ?? anchorFrame
        return GaiCompanionStackResolvedLayout(
            orientation: selected.0,
            anchorCenter: CGPoint(x: resolvedAnchor.midX, y: resolvedAnchor.midY),
            cellSize: cellSize,
            frames: resolvedFrames)
    }

    private static func frames(
        ids: [UUID],
        coordinates: [UUID: GaiCompanionStackCoordinate],
        sizes: [UUID: CGSize],
        anchorCoordinate: GaiCompanionStackCoordinate,
        anchorCenter: CGPoint,
        cellSize: CGSize,
        orientation: GaiCompanionStackOrientation
    ) -> [UUID: NSRect] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            let coordinate = coordinates[id] ?? anchorCoordinate
            let relative = GaiCompanionStackCoordinate(
                column: coordinate.column - anchorCoordinate.column,
                row: coordinate.row - anchorCoordinate.row)
            let oriented = orientation.applying(to: relative)
            let size = sizes[id] ?? .zero
            let center = CGPoint(
                x: anchorCenter.x + CGFloat(oriented.column) * cellSize.width,
                y: anchorCenter.y + CGFloat(oriented.row) * cellSize.height)
            return (id, NSRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height))
        })
    }

    private static func squared(_ value: CGFloat) -> CGFloat { value * value }

    private static func coordinateOrder(
        _ lhs: GaiCompanionStackCoordinate,
        _ rhs: GaiCompanionStackCoordinate
    ) -> Bool {
        let lhsDistance = abs(lhs.column) + abs(lhs.row)
        let rhsDistance = abs(rhs.column) + abs(rhs.row)
        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.column < rhs.column
    }
}
#endif
