#if os(macOS)
import AppKit
import SwiftUI

/// Native development renderer for a companion sprite.
///
/// Atlas files are copied into the Debug bundle. If they cannot be loaded, this
/// view keeps the requested geometry and draws a colorway-aware terminal glyph.
struct GaiCompanionSpriteView: View {
    let colorway: GaiCompanionColorway
    let animation: GaiCompanionAnimation
    let size: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        colorway: GaiCompanionColorway,
        animation: GaiCompanionAnimation,
        size: CGSize
    ) {
        self.colorway = colorway
        self.animation = animation
        self.size = size
    }

    /// Convenience initializer whose argument is the sprite width. The atlas aspect
    /// ratio determines the height, so the mascot is never stretched.
    init(
        colorway: GaiCompanionColorway,
        animation: GaiCompanionAnimation,
        size width: CGFloat
    ) {
        self.init(
            colorway: colorway,
            animation: animation,
            size: CGSize(
                width: width,
                height: width / GaiCompanionAtlas.cellAspectRatio))
    }

    var body: some View {
        Group {
            if let atlas = GaiCompanionAtlasCache.shared.atlas(for: colorway) {
                GaiCompanionSpriteRepresentable(
                    colorway: colorway,
                    animation: animation,
                    atlas: atlas,
                    reduceMotion: reduceMotion)
            } else {
                GaiCompanionFallbackView(colorway: colorway)
            }
        }
        .frame(width: max(1, size.width), height: max(1, size.height))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(colorway.displayName) agent, \(animation.rawValue)")
    }
}

private struct GaiCompanionSpriteRepresentable: NSViewRepresentable {
    let colorway: GaiCompanionColorway
    let animation: GaiCompanionAnimation
    let atlas: CGImage
    let reduceMotion: Bool

    func makeNSView(context: Context) -> GaiCompanionSpriteNSView {
        let view = GaiCompanionSpriteNSView()
        view.configure(
            colorway: colorway,
            animation: animation,
            atlas: atlas,
            reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ view: GaiCompanionSpriteNSView, context: Context) {
        view.configure(
            colorway: colorway,
            animation: animation,
            atlas: atlas,
            reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: GaiCompanionSpriteNSView, coordinator: Void) {
        view.stopAnimating()
    }
}

@MainActor
private final class GaiCompanionSpriteNSView: NSView {
    // Start from a selectable identity color so green can never flash while
    // SwiftUI performs the first coordinator update.
    private var colorway = GaiCompanionColorway.defaultColorway
    private var animation = GaiCompanionAnimation.idle
    private var atlas: CGImage?
    private var reduceMotion = false
    private var animationStartedAt = ProcessInfo.processInfo.systemUptime
    private var displayedRow: Int?
    private var displayedFrame: Int?
    private var clockObservation: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.masksToBounds = false
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        colorway newColorway: GaiCompanionColorway,
        animation newAnimation: GaiCompanionAnimation,
        atlas newAtlas: CGImage,
        reduceMotion newReduceMotion: Bool
    ) {
        let restartsAnimation = animation != newAnimation || colorway != newColorway
        let contentChanged = atlas !== newAtlas
        let motionPreferenceChanged = reduceMotion != newReduceMotion

        colorway = newColorway
        animation = newAnimation
        atlas = newAtlas
        reduceMotion = newReduceMotion

        if restartsAnimation {
            animationStartedAt = ProcessInfo.processInfo.systemUptime
        }
        if restartsAnimation || contentChanged {
            displayedRow = nil
            displayedFrame = nil
        }

        let now = ProcessInfo.processInfo.systemUptime
        _ = render(at: now)
        updateClockSubscription(
            at: now,
            refreshExisting: restartsAnimation || motionPreferenceChanged)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClockSubscription(at: ProcessInfo.processInfo.systemUptime)
    }

    func stopAnimating() {
        guard let clockObservation else { return }
        GaiCompanionAnimationClock.shared.removeObserver(clockObservation)
        self.clockObservation = nil
    }

    private func updateClockSubscription(
        at now: TimeInterval,
        refreshExisting: Bool = true
    ) {
        let needsClock = window != nil && !reduceMotion
        if needsClock, clockObservation == nil {
            clockObservation = GaiCompanionAnimationClock.shared.addObserver { [weak self] now in
                self?.render(at: now)
            }
        } else if needsClock, refreshExisting, let clockObservation {
            GaiCompanionAnimationClock.shared.refreshObserver(clockObservation, at: now)
        } else if !needsClock {
            stopAnimating()
        }
    }

    @discardableResult
    private func render(at now: TimeInterval) -> TimeInterval? {
        guard let atlas else { return nil }
        let definition = animation.definition
        let elapsed = max(0, now - animationStartedAt)
        let frame = animation.frame(
            at: elapsed,
            reduceMotion: reduceMotion)
        if displayedRow != definition.row || displayedFrame != frame {
            displayedRow = definition.row
            displayedFrame = frame
            layer?.contents = GaiCompanionAtlasCache.shared.frame(
                for: colorway,
                atlas: atlas,
                row: definition.row,
                column: frame)
        }

        return animation.timeUntilNextFrame(
            at: elapsed,
            reduceMotion: reduceMotion)
    }
}

/// One shared one-shot scheduler wakes only the sprites whose next manifest frame
/// is due. Persistent frames and Reduce Motion create no timer at all.
@MainActor
private final class GaiCompanionAnimationClock: NSObject {
    static let shared = GaiCompanionAnimationClock()

    typealias Observer = @MainActor (TimeInterval) -> TimeInterval?

    private struct Observation {
        let observer: Observer
        var nextDeadline: TimeInterval?
    }

    private static let minimumDelay: TimeInterval = 0.001

    private var observers: [UUID: Observation] = [:]
    private var timer: Timer?

    func addObserver(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = Observation(observer: observer, nextDeadline: nil)
        refreshObserver(id, at: ProcessInfo.processInfo.systemUptime)
        return id
    }

    func refreshObserver(
        _ id: UUID,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let observer = observers[id]?.observer else { return }
        let delay = observer(now)
        guard observers[id] != nil else { return }
        observers[id]?.nextDeadline = deadline(after: delay, from: now)
        scheduleNextTimer(at: now)
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        scheduleNextTimer(at: ProcessInfo.processInfo.systemUptime)
    }

    private func deadline(after delay: TimeInterval?, from now: TimeInterval) -> TimeInterval? {
        guard let delay, delay.isFinite else { return nil }
        return now + max(Self.minimumDelay, delay)
    }

    private func scheduleNextTimer(at now: TimeInterval) {
        timer?.invalidate()
        timer = nil

        guard let nextDeadline = observers.values.compactMap(\.nextDeadline).min() else {
            return
        }

        let delay = max(Self.minimumDelay, nextDeadline - now)
        let timer = Timer(
            timeInterval: delay,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: false)
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        timer = nil

        let dueObservers: [UUID] = observers.compactMap { id, observation -> UUID? in
            guard let deadline = observation.nextDeadline, deadline <= now else { return nil }
            return id
        }

        for id in dueObservers {
            guard let observer = observers[id]?.observer else { continue }
            let delay = observer(now)
            guard observers[id] != nil else { continue }
            observers[id]?.nextDeadline = deadline(after: delay, from: now)
        }

        scheduleNextTimer(at: now)
    }
}

private struct GaiCompanionFallbackView: View {
    let colorway: GaiCompanionColorway

    private var palette: GaiCompanionPalette { colorway.palette }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(rgb: palette.baseRGB), Color(rgb: palette.shadowRGB)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))

            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(Color(rgb: palette.lightRGB).opacity(0.75), lineWidth: 3)
                .padding(7)

            Image(systemName: "terminal.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(rgb: palette.lightRGB))
                .padding(34)
        }
        .aspectRatio(GaiCompanionAtlas.cellAspectRatio, contentMode: .fit)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
#endif
