#if os(macOS)
import AppKit
import CoreVideo
import GhosttyKit
import QuartzCore
import SwiftUI

/// Space semantics are part of the product, not incidental window defaults.
/// Mascots are system-style overlays that follow every app and every Space;
/// the ordinary creator/settings window belongs only to the Space where the
/// user explicitly asks for it.
enum GaiCompanionSpacePolicy {
    static let floatingOverlay: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .stationary,
        .ignoresCycle,
        .fullScreenAuxiliary,
    ]

    static let onDemandApplicationWindow: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .auxiliary,
        .managed,
        .fullScreenAuxiliary,
    ]
}

private final class GaiCompanionPanel: NSPanel, NSDraggingDestination {
    var acceptsKeyWindow = false
    var onFileDropTargetChanged: ((Bool) -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    override var canBecomeKey: Bool { acceptsKeyWindow }
    override var canBecomeMain: Bool { acceptsKeyWindow }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDropTargetChanged?(false)
    }

    func draggingEnded(_ sender: NSDraggingInfo) {
        onFileDropTargetChanged?(false)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        GaiCompanionFileDropPayload.isAdvertised(on: sender.draggingPasteboard)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = GaiCompanionFileDropPayload.fileURLs(
            from: sender.draggingPasteboard)
        onFileDropTargetChanged?(false)
        guard !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = GaiCompanionFileDropPayload.isAdvertised(
            on: sender.draggingPasteboard)
        onFileDropTargetChanged?(accepted)
        return accepted ? .copy : []
    }
}

/// Transparent panels consume the first click outside a pinned terminal. The
/// click closes Teddy's transient UI and only activates the application below;
/// it is never replayed to a Finder icon, button or editor beneath the pointer.
private final class GaiCompanionDismissShieldView: NSView {
    var onDismiss: ((NSPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) { dismiss(with: event) }
    override func rightMouseDown(with event: NSEvent) { dismiss(with: event) }
    override func otherMouseDown(with event: NSEvent) { dismiss(with: event) }

    private func dismiss(with event: NSEvent) {
        guard let window else { return }
        onDismiss?(window.convertPoint(toScreen: event.locationInWindow))
    }
}

private enum GaiUnderlyingApplicationResolver {
    static func application(at appKitPoint: NSPoint) -> NSRunningApplication? {
        let quartzPoint = quartzPoint(from: appKitPoint)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return finder }

        for window in windows {
            guard let ownerNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerNumber.int32Value != ownPID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(quartzPoint),
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let application = NSRunningApplication(
                      processIdentifier: ownerNumber.int32Value),
                  application.activationPolicy == .regular
            else { continue }
            return application
        }
        return finder
    }

    private static var finder: NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder").first
    }

    private static func quartzPoint(from appKitPoint: NSPoint) -> CGPoint {
        guard let mainScreen = NSScreen.screens.first else { return appKitPoint }
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(
            x: displayBounds.minX + appKitPoint.x - mainScreen.frame.minX,
            y: displayBounds.minY + mainScreen.frame.maxY - appKitPoint.y)
    }
}

private final class GaiCompanionFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private enum GaiCompanionQuickAction: Hashable {
    case home
    case voice
}

private enum GaiCompanionHoverPeekPreference {
    static var isEnabled: Bool {
        let defaults = UserDefaults.ghostty
        guard defaults.object(forKey: GaiPreferenceKey.teddyPeekEnabled) != nil else {
            return true
        }
        return defaults.bool(forKey: GaiPreferenceKey.teddyPeekEnabled)
    }
}

/// A narrow, invisible passage keeps a hover terminal alive while the pointer
/// travels from the mascot to the panel. It never participates in initial hover
/// detection, so transparent pixels around the doudou remain genuinely inert.
enum GaiCompanionHoverBridge {
    static func contains(
        _ point: NSPoint,
        mascotFrame: NSRect,
        terminalFrame: NSRect,
        halfWidth: CGFloat = 11
    ) -> Bool {
        guard !mascotFrame.isEmpty, !terminalFrame.isEmpty else { return false }
        let mascotCenter = NSPoint(x: mascotFrame.midX, y: mascotFrame.midY)
        let terminalPoint = closestPoint(in: terminalFrame, to: mascotCenter)
        let mascotPoint = closestPoint(in: mascotFrame, to: terminalPoint)
        return distanceFromSegment(point, start: mascotPoint, end: terminalPoint)
            <= max(halfWidth, 1)
    }

    static func isProgressing(
        from previous: NSPoint,
        to current: NSPoint,
        terminalFrame: NSRect,
        tolerance: CGFloat = 0.75
    ) -> Bool {
        distance(from: current, to: terminalFrame)
            <= distance(from: previous, to: terminalFrame) + max(tolerance, 0)
    }

    private static func closestPoint(in rect: NSRect, to point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY))
    }

    private static func distanceFromSegment(
        _ point: NSPoint,
        start: NSPoint,
        end: NSPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(max(
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared,
            0), 1)
        let nearest = NSPoint(
            x: start.x + projection * dx,
            y: start.y + projection * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let nearest = closestPoint(in: rect, to: point)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }
}

/// A native, accessibility-visible action which sits above the mascot's
/// SwiftUI renderer. Keeping these controls in AppKit lets ordinary button
/// clicks bypass the custom drag recognizer without adding another panel.
private final class GaiCompanionQuickActionButton: NSButton {
    private let activation: () -> Void
    private let materialView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let symbolView = NSImageView(frame: .zero)
    private var trackingAreaReference: NSTrackingArea?
    private var isPointerInside = false

    init(
        symbol: String,
        accessibilityLabel: String,
        help: String,
        activation: @escaping () -> Void
    ) {
        self.activation = activation
        super.init(frame: .zero)
        image = nil
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        toolTip = help
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.8
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 5
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
        addSubview(materialView)

        tintView.wantsLayer = true
        tintView.layer?.cornerCurve = .continuous
        tintView.layer?.masksToBounds = true
        addSubview(tintView)

        symbolView.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel)
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        addSubview(symbolView)

        setAccessibilityLabel(accessibilityLabel)
        target = self
        action = #selector(activate)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        tintView.frame = bounds
        let cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.cornerRadius = cornerRadius
        materialView.layer?.cornerRadius = cornerRadius
        tintView.layer?.cornerRadius = cornerRadius

        let symbolSide = (min(bounds.width, bounds.height) * 0.50).rounded()
        symbolView.frame = NSRect(
            x: ((bounds.width - symbolSide) / 2).rounded(),
            y: ((bounds.height - symbolSide) / 2).rounded(),
            width: symbolSide,
            height: symbolSide)
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.72
        super.mouseDown(with: event)
        alphaValue = 1
    }

    @objc private func activate() {
        activation()
    }

    private func refreshAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(
            isPointerInside ? 0.38 : 0.28).cgColor
        tintView.layer?.backgroundColor = NSColor.gray.withAlphaComponent(
            isPointerInside ? 0.22 : 0.16).cgColor
        symbolView.contentTintColor = NSColor.white.withAlphaComponent(
            isPointerInside ? 0.96 : 0.86)
    }
}

private final class GaiCompanionDropFeedback: ObservableObject {
    @Published private(set) var isTargeted = false
    @Published private(set) var acceptedFileCount: Int?
    private var feedbackGeneration: UInt64 = 0

    func setTargeted(_ targeted: Bool) {
        guard targeted != isTargeted else { return }
        isTargeted = targeted
        if targeted {
            feedbackGeneration &+= 1
            acceptedFileCount = nil
        }
    }

    func showAccepted(fileCount: Int) {
        guard fileCount > 0 else { return }
        feedbackGeneration &+= 1
        let generation = feedbackGeneration
        isTargeted = false
        acceptedFileCount = fileCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.feedbackGeneration == generation else { return }
            self.acceptedFileCount = nil
        }
    }
}

/// Owns both click recognition and native Window Server dragging for the
/// mascot. Tracking the maximum pointer distance prevents a drag that returns
/// to its starting point from being mistaken for a click.
/// A plain AppKit container owns the drag destination. Keeping registration off
/// `NSHostingView` matters: SwiftUI rebuilds its internal dragging views and can
/// replace registrations made directly on the hosting view.
private final class GaiCompanionDragClickContainerView<Content: View>: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onFileDropTargetChanged: ((Bool) -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    private let hostingView: NSHostingView<Content>
    private var quickActionButtons: [GaiCompanionQuickAction: GaiCompanionQuickActionButton] = [:]
    private var quickActionsAreVisible = false
    private var mascotTrackingArea: NSTrackingArea?
    private weak var cachedSpriteView: GaiCompanionSpriteNSView?
    private var pointerIsInsideMascotSilhouette = false

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        autoresizesSubviews = true
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let mascotTrackingArea {
            removeTrackingArea(mascotTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        mascotTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        updateMascotPointerState(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateMascotPointerState(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setMascotPointerInside(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if quickActionsAreVisible {
            for button in quickActionButtons.values where !button.isHidden {
                let buttonPoint = button.convert(point, from: self)
                if button.bounds.contains(buttonPoint) {
                    return button.hitTest(buttonPoint) ?? button
                }
            }
        }
        return self
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
        layoutQuickActions()
    }

    func configureVoiceAction(onReplayLatestResponse: @escaping () -> Void) {
        guard quickActionButtons.isEmpty else { return }
        let button = GaiCompanionQuickActionButton(
            symbol: "waveform",
            accessibilityLabel: "Lire la dernière réponse",
            help: "Lire vocalement la dernière réponse de la CLI",
            activation: onReplayLatestResponse)
        button.isHidden = true
        button.alphaValue = 0
        quickActionButtons[.voice] = button
        addSubview(button)
        needsLayout = true
    }

    func configureHubAction(onOpenCreator: @escaping () -> Void) {
        guard quickActionButtons.isEmpty else { return }
        let button = GaiCompanionQuickActionButton(
            symbol: "house.fill",
            accessibilityLabel: "Créer des doudous",
            help: "Ouvrir la création de doudous",
            activation: onOpenCreator)
        button.isHidden = true
        button.alphaValue = 0
        quickActionButtons[.home] = button
        addSubview(button)
        needsLayout = true
    }

    func setQuickActionsVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != quickActionsAreVisible else { return }
        quickActionsAreVisible = visible
        let buttons = Array(quickActionButtons.values)
        if visible {
            for button in buttons {
                button.isHidden = false
                button.alphaValue = animated ? 0 : 1
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
            updateTrackingAreas()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.14 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for button in buttons {
                button.animator().alphaValue = visible ? 1 : 0
            }
        } completionHandler: {
            guard !visible else { return }
            for button in buttons {
                button.isHidden = true
            }
            self.updateTrackingAreas()
        }
    }

    private func layoutQuickActions() {
        guard !quickActionButtons.isEmpty else { return }
        let scale = max(
            0.72,
            bounds.width / CGFloat(GaiCompanionVisualMetrics.basePanelWidth))
        let diameter = (28 * scale).rounded()
        let gap = (5 * scale).rounded()
        let orderedActions: [GaiCompanionQuickAction] = quickActionButtons[.home] == nil
            ? [.voice]
            : [.home]
        let totalWidth = diameter * CGFloat(orderedActions.count)
            + gap * CGFloat(orderedActions.count - 1)
        var x = ((bounds.width - totalWidth) / 2).rounded()
        let y = max(3, bounds.height - diameter - 4 * scale).rounded()
        for action in orderedActions {
            quickActionButtons[action]?.frame = NSRect(
                x: x,
                y: y,
                width: diameter,
                height: diameter)
            quickActionButtons[action]?.layer?.cornerRadius = diameter / 2
            x += diameter + gap
        }
    }

    func mascotSilhouetteContains(screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return mascotSilhouetteContains(convert(windowPoint, from: nil))
    }

    func mascotSpriteScreenFrame() -> NSRect? {
        guard let window,
              let spriteView = resolvedSpriteView() else { return nil }
        let windowRect = spriteView.convert(spriteView.bounds, to: nil)
        return window.convertToScreen(windowRect)
    }

    private func updateMascotPointerState(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setMascotPointerInside(mascotSilhouetteContains(point))
    }

    private func setMascotPointerInside(_ inside: Bool) {
        guard inside != pointerIsInsideMascotSilhouette else { return }
        pointerIsInsideMascotSilhouette = inside
        if inside {
            onPointerEntered?()
        } else {
            onPointerExited?()
        }
    }

    private func mascotSilhouetteContains(_ point: NSPoint) -> Bool {
        if let spriteView = resolvedSpriteView() {
            let spritePoint = spriteView.convert(point, from: self)
            return spriteView.containsVisiblePixel(at: spritePoint)
        }

        // The bundled atlases normally make this path unreachable. Retain a
        // close silhouette fallback so a missing development asset cannot
        // restore the old full-panel hover rectangle.
        let scale = bounds.width / CGFloat(GaiCompanionVisualMetrics.basePanelWidth)
        let spriteWidth = CGFloat(GaiCompanionVisualMetrics.baseSpriteWidth) * scale
        let spriteHeight = spriteWidth / CGFloat(GaiCompanionAtlas.cellAspectRatio)
        let spriteRect = NSRect(
            x: bounds.midX - spriteWidth / 2,
            y: 22 * scale,
            width: spriteWidth,
            height: spriteHeight)
        guard spriteRect.contains(point) else { return false }
        let normalizedX = (point.x - spriteRect.midX) / max(spriteRect.width / 2, 1)
        let normalizedY = (point.y - spriteRect.midY) / max(spriteRect.height / 2, 1)
        return normalizedX * normalizedX + normalizedY * normalizedY <= 1
    }

    private func resolvedSpriteView() -> GaiCompanionSpriteNSView? {
        if let cachedSpriteView,
           cachedSpriteView.window === window,
           cachedSpriteView.isDescendant(of: hostingView) {
            return cachedSpriteView
        }
        let result = firstSpriteView(in: hostingView)
        cachedSpriteView = result
        return result
    }

    private func firstSpriteView(in view: NSView) -> GaiCompanionSpriteNSView? {
        if let spriteView = view as? GaiCompanionSpriteNSView {
            return spriteView
        }
        for subview in view.subviews {
            if let result = firstSpriteView(in: subview) {
                return result
            }
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unregisterDraggedTypes()
        guard window != nil else { return }
        registerForDraggedTypes(GaiCompanionFileDropPayload.readableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDropTargetChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onFileDropTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        GaiCompanionFileDropPayload.isAdvertised(on: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = GaiCompanionFileDropPayload.fileURLs(
            from: sender.draggingPasteboard)
        onFileDropTargetChanged?(false)
        guard !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let accepted = GaiCompanionFileDropPayload.isAdvertised(
            on: sender.draggingPasteboard)
        onFileDropTargetChanged?(accepted)
        return accepted ? .copy : []
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let window else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount >= 2 {
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleClick?()
            }
            return
        }

        guard event.clickCount == 1 else {
            super.mouseDown(with: event)
            return
        }

        let startPointer = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var dragOwnsGesture = false
        var mouseUpLocation = startPointer

        while let nextEvent = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            let pointer = NSEvent.mouseLocation
            mouseUpLocation = pointer
            if nextEvent.type == .leftMouseUp {
                break
            }

            let deltaX = pointer.x - startPointer.x
            let deltaY = pointer.y - startPointer.y
            if !dragOwnsGesture, hypot(deltaX, deltaY) >= 2 {
                // Ownership is irreversible for this mouse sequence. Even if
                // the pointer comes back to its exact starting point, mouse-up
                // can no longer toggle or expand the stack.
                dragOwnsGesture = true
                onDragBegan?()
            }
            guard dragOwnsGesture else { continue }
            let origin = NSPoint(
                x: startOrigin.x + deltaX,
                y: startOrigin.y + deltaY)
            if window.frame.origin != origin {
                window.setFrameOrigin(origin)
            }
        }

        if dragOwnsGesture {
            onDragEnded?()
            return
        }

        let endInWindow = window.convertPoint(fromScreen: mouseUpLocation)
        let endInView = convert(endInWindow, from: nil)
        guard bounds.contains(endInView) else { return }
        // A click selects the doudou and pins its compact terminal. A later
        // double-click can still promote the same native surface to maximized.
        onClick?()
    }

}

/// An explicit empty strip in the custom borderless header. It gives AppKit a
/// native Window Server drag without making terminal text or header controls
/// draggable by accident.
private struct GaiCompanionWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard event.buttonNumber == 0, let window else {
                super.mouseDown(with: event)
                return
            }
            window.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {}
}

@available(macOS 14.0, *)
private final class GaiCompanionViewDisplayLinkDriver: NSObject {
    private let onFrame: (CFTimeInterval) -> Void
    private var displayLink: CADisplayLink?

    init(view: NSView, onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
        super.init()

        let displayLink = view.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:)))
        // Apple classifies a large, fast spatial transition as a high-impact
        // animation. Ask ProMotion for its native range; the system clamps this
        // automatically on 60 Hz displays and under power or thermal pressure.
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        // Advance against the frame that is about to be presented, not the one
        // AppKit has just finished. This removes one refresh of input latency.
        onFrame(displayLink.targetTimestamp)
    }
}

/// Display-synchronised main-thread ticks. On modern macOS the clock is created
/// by the visible AppKit view itself, so it follows the actual screen (including
/// 120 Hz ProMotion and moves between displays). macOS 13 keeps the coalesced
/// CoreVideo fallback.
final class GaiCompanionDisplayLink {
    private let onFrame: (CFTimeInterval) -> Void
    private let frameSource: DispatchSourceUserDataAdd
    private var displayLink: CVDisplayLink?
    private var viewDisplayLinkDriver: AnyObject?
    private var fallbackTimer: DispatchSourceTimer?
    private var running = false

    init(onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
        frameSource = DispatchSource.makeUserDataAddSource(queue: .main)
        frameSource.setEventHandler { [weak self] in
            self?.onFrame(CACurrentMediaTime())
        }
        frameSource.resume()

        var createdLink: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&createdLink) == kCVReturnSuccess,
           let createdLink {
            displayLink = createdLink
            CVDisplayLinkSetOutputCallback(
                createdLink,
                { _, _, _, _, _, context in
                    guard let context else { return kCVReturnError }
                    let owner = Unmanaged<GaiCompanionDisplayLink>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    owner.frameSource.add(data: 1)
                    return kCVReturnSuccess
                },
                Unmanaged.passUnretained(self).toOpaque())
        }
    }

    deinit {
        stop()
        frameSource.cancel()
    }

    func start(synchronizedTo view: NSView? = nil) {
        guard !running else { return }
        running = true
        if #available(macOS 14.0, *), let view, view.window != nil {
            viewDisplayLinkDriver = GaiCompanionViewDisplayLinkDriver(
                view: view,
                onFrame: onFrame)
            return
        }
        if let displayLink {
            CVDisplayLinkStart(displayLink)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(8_333_333),
            leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.frameSource.add(data: 1)
        }
        fallbackTimer = timer
        timer.resume()
    }

    func stop() {
        guard running else { return }
        running = false
        if #available(macOS 14.0, *),
           let driver = viewDisplayLinkDriver as? GaiCompanionViewDisplayLinkDriver {
            driver.invalidate()
        }
        viewDisplayLinkDriver = nil
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }
}

/// Deterministic FLIP transition used only when the preview changes side.
/// Offsets stay relative to the moving companion so AppKit remains the sole
/// owner of ordinary drag motion. There is deliberately no velocity state.
private struct GaiCompanionPlacementTransition {
    let terminalFrom: CGPoint
    let terminalTo: CGPoint
    let startedAt: CFTimeInterval
}

/// Matches GaiWork's `cubic-bezier(0.16, 1, 0.3, 1)`. The x component is
/// inverted before evaluating y, and the result is strictly bounded so the
/// transition can never overshoot its destination.
private enum GaiCompanionPlacementTiming {
    static func value(at progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }

        var lower: CGFloat = 0
        var upper: CGFloat = 1
        var parameter = progress
        for _ in 0..<14 {
            let estimatedX = cubic(parameter, firstControlPoint: 0.16, secondControlPoint: 0.3)
            if estimatedX < progress {
                lower = parameter
            } else {
                upper = parameter
            }
            parameter = (lower + upper) / 2
        }

        return min(
            max(cubic(parameter, firstControlPoint: 1, secondControlPoint: 1), 0),
            1)
    }

    private static func cubic(
        _ parameter: CGFloat,
        firstControlPoint: CGFloat,
        secondControlPoint: CGFloat
    ) -> CGFloat {
        let inverse = 1 - parameter
        return 3 * inverse * inverse * parameter * firstControlPoint
            + 3 * inverse * parameter * parameter * secondControlPoint
            + parameter * parameter * parameter
    }
}

final class GaiCompanionHubState: ObservableObject {
    @Published var companionCount = 0
    @Published var isExpanded = false
    @Published var isHovered = false
    @Published var scalePercent = GaiCompanionScalePercent.standard
}

final class GaiCompanionHubPanelController: NSObject, NSWindowDelegate {
    let companionPanel: NSPanel

    private let hubID: UUID
    private let state: GaiCompanionHubState
    private weak var manager: GaiCompanionManager?
    private weak var hostView: GaiCompanionDragClickContainerView<GaiCompanionHubView>?
    private var applyingFrame = false
    private var previousFrame: NSRect?

    init(
        hubID: UUID,
        state: GaiCompanionHubState,
        manager: GaiCompanionManager
    ) {
        self.hubID = hubID
        self.state = state
        self.manager = manager

        let panel = GaiCompanionPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: GaiCompanionVisualMetrics.basePanelWidth,
                height: GaiCompanionVisualMetrics.basePanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = NSWindow.Level(
            rawValue: GaiFloatingPanels.overlayLevel.rawValue + 1)
        panel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.identifier = NSUserInterfaceItemIdentifier(
            "gai.companion.hub.\(hubID.uuidString)")
        companionPanel = panel

        super.init()
        panel.delegate = self

        let root = GaiCompanionHubView(state: state)
        let host = GaiCompanionDragClickContainerView(rootView: root)
        host.onClick = { [weak manager] in
            manager?.companionHubWasClicked()
        }
        host.configureHubAction { [weak manager] in
            manager?.requestOpenCompanionCreator()
        }
        host.onPointerEntered = { [weak host, weak state] in
            state?.isHovered = true
            host?.setQuickActionsVisible(true)
        }
        host.onPointerExited = { [weak host, weak state] in
            state?.isHovered = false
            host?.setQuickActionsVisible(false)
        }
        host.onDragBegan = { [weak manager] in
            manager?.companionHubDragDidBegin()
        }
        host.onDragEnded = { [weak self, weak manager] in
            guard let self else { return }
            manager?.companionHubDidMove(
                frame: self.companionPanel.frame,
                screen: self.companionPanel.screen)
        }
        host.autoresizingMask = [.width, .height]
        hostView = host
        panel.contentView = host
    }

    func show(frame: NSRect, visible: Bool) {
        applyingFrame = true
        if companionPanel.frame != frame {
            companionPanel.setFrame(frame, display: true, animate: false)
        }
        previousFrame = frame
        applyingFrame = false
        companionPanel.alphaValue = 1
        companionPanel.contentView?.layer?.setAffineTransform(.identity)
        if visible {
            companionPanel.orderFrontRegardless()
        } else {
            resetHoverPresentation()
            companionPanel.orderOut(nil)
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            companionPanel.orderFrontRegardless()
        } else {
            resetHoverPresentation()
            companionPanel.orderOut(nil)
        }
    }

    func resize(frame: NSRect) {
        applyingFrame = true
        if companionPanel.frame != frame {
            companionPanel.setFrame(frame, display: true, animate: false)
        }
        previousFrame = frame
        applyingFrame = false
    }

    func restoreVisibilityOnActiveSpace(_ visible: Bool) {
        companionPanel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
        if visible {
            companionPanel.orderFrontRegardless()
        } else {
            resetHoverPresentation()
            companionPanel.orderOut(nil)
        }
    }

    var transitionAlpha: CGFloat { companionPanel.alphaValue }

    var transitionScale: CGFloat {
        companionPanel.contentView?.layer?.affineTransform().a ?? 1
    }

    func applyStackTransitionFrame(
        _ frame: NSRect,
        alpha: CGFloat,
        scale: CGFloat,
        orderFront: Bool
    ) {
        applyingFrame = true
        if companionPanel.frame != frame {
            if companionPanel.frame.size == frame.size {
                companionPanel.setFrameOrigin(frame.origin)
            } else {
                companionPanel.setFrame(frame, display: false, animate: false)
            }
        }
        previousFrame = frame
        applyingFrame = false
        companionPanel.alphaValue = min(max(alpha, 0), 1)
        companionPanel.contentView?.wantsLayer = true
        companionPanel.contentView?.layer?.setAffineTransform(
            CGAffineTransform(scaleX: scale, y: scale))
        if orderFront {
            companionPanel.orderFrontRegardless()
        }
    }

    func prepareStackTransition(maximumScale: CGFloat = 1) {
        companionPanel.contentView?.wantsLayer = true
        guard let layer = companionPanel.contentView?.layer else { return }
        layer.rasterizationScale = (companionPanel.screen?.backingScaleFactor ?? 2)
            * max(1, maximumScale)
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.shouldRasterize = true
    }

    func finishStackTransition() {
        companionPanel.contentView?.layer?.shouldRasterize = false
    }

    func settleStackTransition(frame: NSRect, visible: Bool) {
        show(frame: frame, visible: visible)
    }

    func close() {
        resetHoverPresentation()
        companionPanel.delegate = nil
        companionPanel.orderOut(nil)
        companionPanel.close()
    }

    private func resetHoverPresentation() {
        state.isHovered = false
        hostView?.setQuickActionsVisible(false, animated: false)
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === companionPanel,
              !applyingFrame else { return }
        let frame = companionPanel.frame
        guard let previousFrame else {
            self.previousFrame = frame
            return
        }
        self.previousFrame = frame
        guard frame.origin != previousFrame.origin else { return }
        manager?.companionHubIsMoving(
            frame: frame,
            screen: companionPanel.screen)
    }
}

final class GaiCompanionPanelController: NSObject, NSWindowDelegate {
    let companionPanel: NSPanel
    let terminalPanel: NSPanel

    private let runtimeID: UUID
    private weak var manager: GaiCompanionManager?
    private let dropFeedback: GaiCompanionDropFeedback
    private var dropIsTargeted = false
    private var applyingCompanionFrame = false
    private var applyingTerminalFrame = false
    private var presentation: GaiCompanionPresentation = .collapsed
    private var visibilityGeneration = 0
    private var previousCompanionFrame: NSRect?
    private var interceptingExternalFileDrag = false
    private var terminalMoveSettleWorkItem: DispatchWorkItem?
    private var terminalMoveSettleGeneration = 0
    private var livePlacement: GaiCompanionTerminalPlacement = .top
    private var placementScreenNumber: NSNumber?
    private var placementTransition: GaiCompanionPlacementTransition?
    private var terminalHostView: NSView?
    private var mascotHostView: GaiCompanionDragClickContainerView<GaiCompanionMascotView>?
    private var hoverIntentWorkItem: DispatchWorkItem?
    private var hoverPresenceTimer: DispatchSourceTimer?
    private var pointerIsOverMascot = false
    private var hoverPeekOwnsPresentation = false
    private var hoverBridgeLastPointer: NSPoint?
    private var hoverBridgeLastMotionAt: CFTimeInterval?
    private var terminalIsPinnedUntilOutsideClick = false
    private var dismissalShieldPanels: [NSPanel] = []
    private lazy var placementDisplayLink = GaiCompanionDisplayLink { [weak self] timestamp in
        self?.advanceLivePlacementAnimation(at: timestamp)
    }

    /// Native window dragging can emit more move callbacks than the display can
    /// present. Keep normal dragging entirely in the Window Server, then persist
    /// and perform one exact final layout once the pointer has settled.
    private static let moveSettleDelay: TimeInterval = 0.1
    private static let placementTransitionDuration: CFTimeInterval = 0.18
    private static let hoverIntentDelay: TimeInterval = 0.18
    private static let hoverPresenceInterval: DispatchTimeInterval = .milliseconds(8)
    /// The bridge is a movement corridor, never a third resting hover target.
    /// A paused pointer outside both real surfaces therefore closes almost
    /// immediately, while continuous travel to the terminal remains possible.
    private static let hoverBridgeIdleTimeout: CFTimeInterval = 0.09
    private static let hoverBridgeMinimumMotion: CGFloat = 0.35
    private static let restingCompanionLevel = NSWindow.Level(
        rawValue: GaiFloatingPanels.overlayLevel.rawValue + 1)
    private static let foregroundTerminalLevel = NSWindow.Level(
        rawValue: GaiFloatingPanels.overlayLevel.rawValue + 2)
    // AppKit's drag image lives at CGWindowLevelKey.draggingWindow. A panel
    // above that level remains visible, but is skipped as a native destination
    // and the drop reaches the application underneath. During a file drag,
    // keep the mascot above ordinary/status windows and immediately below the
    // system drag layer so it becomes the one true destination.
    private static let fileDragInterceptionLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)

    init(runtime: GaiCompanionRuntime, manager: GaiCompanionManager) {
        runtimeID = runtime.id
        self.manager = manager
        let dropFeedback = GaiCompanionDropFeedback()
        self.dropFeedback = dropFeedback

        let companionPanel = GaiCompanionPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: GaiCompanionVisualMetrics.basePanelWidth,
                height: GaiCompanionVisualMetrics.basePanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        companionPanel.level = Self.restingCompanionLevel
        companionPanel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
        companionPanel.isOpaque = false
        companionPanel.backgroundColor = .clear
        companionPanel.hasShadow = false
        companionPanel.hidesOnDeactivate = false
        companionPanel.isReleasedWhenClosed = false
        companionPanel.isMovableByWindowBackground = false
        companionPanel.animationBehavior = .none
        companionPanel.acceptsMouseMovedEvents = true
        companionPanel.identifier = NSUserInterfaceItemIdentifier(
            "gai.companion.mascot.\(runtime.id.uuidString)")

        let terminalPanel = GaiCompanionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 330),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        terminalPanel.level = Self.foregroundTerminalLevel
        terminalPanel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
        terminalPanel.isOpaque = false
        terminalPanel.backgroundColor = .clear
        terminalPanel.hasShadow = false
        terminalPanel.hidesOnDeactivate = false
        terminalPanel.isReleasedWhenClosed = false
        terminalPanel.isMovableByWindowBackground = false
        terminalPanel.animationBehavior = .none
        terminalPanel.appearance = NSAppearance(named: .darkAqua)
        terminalPanel.acceptsKeyWindow = true
        terminalPanel.identifier = NSUserInterfaceItemIdentifier(
            "gai.companion.terminal.\(runtime.id.uuidString)")

        self.companionPanel = companionPanel
        self.terminalPanel = terminalPanel

        super.init()
        companionPanel.delegate = self
        terminalPanel.delegate = self
        companionPanel.onFileDropTargetChanged = { [weak self] targeted in
            self?.updateDropTarget(targeted)
        }
        companionPanel.onFileDrop = { [weak self, weak manager] urls in
            guard let self else { return }
            self.dropFeedback.showAccepted(fileCount: urls.count)
            Task { @MainActor in
                manager?.insertDroppedFileURLs(urls, into: runtime.id)
            }
        }

        let mascotRoot = GaiCompanionMascotView(
            runtime: runtime,
            dropFeedback: dropFeedback)
        let mascotHost = GaiCompanionDragClickContainerView(rootView: mascotRoot)
        mascotHost.onClick = { [weak manager] in
            manager?.companionWasClicked(id: runtime.id)
        }
        mascotHost.onDoubleClick = { [weak manager] in
            manager?.openMaximizedTerminal(id: runtime.id)
        }
        mascotHost.onPointerEntered = { [weak self] in
            self?.mascotPointerEntered()
        }
        mascotHost.onPointerExited = { [weak self] in
            self?.mascotPointerExited()
        }
        mascotHost.configureVoiceAction(
            onReplayLatestResponse: { [weak manager] in
                manager?.requestReplayLatestVoice(id: runtime.id)
            })
        mascotHost.onDragBegan = { [weak manager] in
            manager?.companionDragDidBegin(id: runtime.id)
        }
        mascotHost.onDragEnded = { [weak self, weak manager] in
            guard let self else { return }
            manager?.panelDidMove(
                for: runtime.id,
                frame: self.companionPanel.frame,
                screen: self.companionPanel.screen)
        }
        mascotHost.onFileDropTargetChanged = { [weak self] targeted in
            self?.updateDropTarget(targeted)
        }
        mascotHost.onFileDrop = { [weak self, weak manager] urls in
            guard let self else { return }
            self.dropFeedback.showAccepted(fileCount: urls.count)
            Task { @MainActor in
                manager?.insertDroppedFileURLs(urls, into: runtime.id)
            }
        }
        mascotHost.autoresizingMask = [.width, .height]
        companionPanel.contentView = mascotHost
        mascotHostView = mascotHost
        // Installing an NSHostingView hierarchy can replace native drag
        // registrations. Register both concrete destinations only after the
        // final content view is attached to the panel.
        companionPanel.unregisterDraggedTypes()
        companionPanel.registerForDraggedTypes(
            GaiCompanionFileDropPayload.readableTypes)

        let terminalRoot = GaiCompanionTerminalView(
            runtime: runtime,
            onToggleMaximized: { [weak manager] in
                manager?.toggleMaximized(id: runtime.id)
            },
            onApplyLayoutPreset: { [weak manager] preset in
                manager?.applyExpandedTerminalLayout(id: runtime.id, preset: preset)
            },
            onToggleLock: { [weak manager] in manager?.toggleTerminalLock(id: runtime.id) },
            onReplayLatestResponse: { [weak manager] in
                manager?.requestReplayLatestVoice(id: runtime.id)
            },
            onRename: { [weak manager] name in manager?.updateName(id: runtime.id, name: name) },
            onClose: { [weak manager] in manager?.requestCloseCompanion(id: runtime.id) },
            onChooseDirectory: { [weak manager] path in
                manager?.chooseDirectory(id: runtime.id, path: path)
            },
            onDirectoryDialogVisibilityChanged: { [weak manager] isPresented in
                manager?.setTerminalDialogPresented(
                    id: runtime.id,
                    isPresented: isPresented)
            })
        let terminalHost = GaiCompanionFirstMouseHostingView(rootView: terminalRoot)
        terminalHost.autoresizingMask = [.width, .height]
        terminalHost.wantsLayer = true
        terminalHost.layer?.cornerRadius = 8
        terminalHost.layer?.cornerCurve = .continuous
        terminalHost.layer?.masksToBounds = true
        terminalPanel.contentView = terminalHost
        terminalHostView = terminalHost

        // The compact terminal is attached only when visible. AppKit then
        // moves it in the same Window Server transaction as the mascot.
    }

    func setDesktopSelected(_ selected: Bool) {
        mascotHostView?.setQuickActionsVisible(
            selected && !dropIsTargeted && !companionPanel.ignoresMouseEvents)
    }

    var companionTransitionAlpha: CGFloat { companionPanel.alphaValue }

    var companionTransitionScale: CGFloat {
        companionPanel.contentView?.layer?.affineTransform().a ?? 1
    }

    /// Applies one compositor frame of the stack bloom. The window keeps its
    /// real size while its layer scales around the centre, so SwiftUI and the
    /// sprite atlas never relayout during motion.
    func applyStackTransitionFrame(
        _ frame: NSRect,
        alpha: CGFloat,
        scale: CGFloat,
        orderFront: Bool
    ) {
        applyingCompanionFrame = true
        if !NSEqualRects(companionPanel.frame, frame) {
            if companionPanel.frame.size == frame.size {
                companionPanel.setFrameOrigin(frame.origin)
            } else {
                companionPanel.setFrame(frame, display: false, animate: false)
            }
        }
        previousCompanionFrame = frame
        applyingCompanionFrame = false
        companionPanel.alphaValue = min(max(alpha, 0), 1)
        companionPanel.contentView?.wantsLayer = true
        companionPanel.contentView?.layer?.setAffineTransform(
            CGAffineTransform(scaleX: scale, y: scale))
        if orderFront {
            companionPanel.orderFrontRegardless()
        }
    }

    /// Hub dragging changes only the Window Server position. The mascot is
    /// already rasterized for the gesture, so alpha and layer transforms stay
    /// untouched and no SwiftUI work is scheduled for these live frames.
    func applyHubDragFrame(_ frame: NSRect) {
        applyingCompanionFrame = true
        if !NSEqualRects(companionPanel.frame, frame) {
            companionPanel.setFrame(frame, display: false, animate: false)
        }
        previousCompanionFrame = frame
        applyingCompanionFrame = false
    }

    func applyMagneticDragScale(_ scale: CGFloat) {
        companionPanel.contentView?.wantsLayer = true
        companionPanel.contentView?.layer?.setAffineTransform(
            CGAffineTransform(scaleX: scale, y: scale))
    }

    /// The whole mascot hierarchy becomes one compositor texture for stack
    /// motion. Materials, badges and atlas sublayers no longer need to be
    /// recomposited independently for every Window Server frame.
    func prepareStackTransition(maximumScale: CGFloat = 1) {
        cancelHoverPeekLifecycle()
        companionPanel.ignoresMouseEvents = true
        mascotHostView?.setQuickActionsVisible(false, animated: false)
        companionPanel.contentView?.wantsLayer = true
        // Commit the material-free transition hierarchy once. From this point
        // until settle, the layer tree is immutable and WindowServer only moves
        // a bitmap; SwiftUI performs no layout or backdrop work per frame.
        companionPanel.contentView?.layoutSubtreeIfNeeded()
        companionPanel.contentView?.displayIfNeeded()
        guard let layer = companionPanel.contentView?.layer else { return }
        layer.rasterizationScale = (companionPanel.screen?.backingScaleFactor ?? 2)
            * max(1, maximumScale)
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.shouldRasterize = true
    }

    func prepareStackBadgeReveal() {
        companionPanel.contentView?.layoutSubtreeIfNeeded()
        companionPanel.contentView?.displayIfNeeded()
    }

    func finishStackTransition(
        interactive: Bool,
        selected: Bool,
        restingScale: CGFloat
    ) {
        companionPanel.contentView?.layer?.shouldRasterize = false
        companionPanel.contentView?.layer?.setAffineTransform(
            CGAffineTransform(scaleX: restingScale, y: restingScale))
        companionPanel.ignoresMouseEvents = !interactive
        mascotHostView?.setQuickActionsVisible(
            interactive && selected,
            animated: false)
    }

    func settleStackTransition(frame: NSRect, visible: Bool) {
        applyingCompanionFrame = true
        if !NSEqualRects(companionPanel.frame, frame) {
            companionPanel.setFrame(frame, display: true, animate: false)
        }
        previousCompanionFrame = frame
        applyingCompanionFrame = false
        companionPanel.contentView?.layer?.setAffineTransform(.identity)
        companionPanel.alphaValue = 1
        if visible {
            companionPanel.orderFrontRegardless()
        } else {
            companionPanel.orderOut(nil)
        }
    }

    /// Once a collapsing mascot is fully transparent, remove its window from
    /// Window Server composition. Its final hidden frame is restored when the
    /// stack settles, so stopping early has no layout side effect.
    func suspendStackTransitionRendering() {
        companionPanel.orderOut(nil)
    }

    var isHoverPeekPresented: Bool {
        hoverPeekOwnsPresentation
            && presentation == .compact
            && terminalPanel.isVisible
    }

    /// Only an explicit mascot click promotes the hover preview into a pinned
    /// compact terminal. Focusing, typing or clicking inside a hover terminal
    /// deliberately preserves hover ownership, so leaving its bounded region
    /// always closes it. Transparent shields consume the next outside click
    /// only after that explicit mascot click.
    func pinCompactTerminalUntilOutsideClick() {
        guard presentation == .compact,
              terminalPanel.isVisible else { return }
        if hoverPeekOwnsPresentation {
            hoverPeekOwnsPresentation = false
            stopHoverPresenceTimer()
        }
        manager?.terminalPeekDidBecomeInteractive(id: runtimeID)
        guard !terminalIsPinnedUntilOutsideClick else { return }
        terminalIsPinnedUntilOutsideClick = true
        showDismissalShields()
    }

    private func showDismissalShields() {
        hideDismissalShields()
        dismissalShieldPanels = NSScreen.screens.map { screen in
            let panel = GaiCompanionPanel(
                contentRect: screen.visibleFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen)
            panel.level = GaiFloatingPanels.overlayLevel
            panel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
            panel.isOpaque = false
            // A nearly transparent backing keeps the window hit-testable in
            // WindowServer without creating any visible dimming.
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.acceptsKeyWindow = false
            panel.identifier = NSUserInterfaceItemIdentifier(
                "gai.companion.dismiss-shield.\(runtimeID.uuidString)")

            let view = GaiCompanionDismissShieldView(
                frame: NSRect(origin: .zero, size: screen.visibleFrame.size))
            view.autoresizingMask = [.width, .height]
            view.onDismiss = { [weak self] point in
                self?.dismissPinnedTerminal(at: point)
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            return panel
        }
    }

    private func dismissPinnedTerminal(at point: NSPoint) {
        guard terminalIsPinnedUntilOutsideClick else { return }
        let application = GaiUnderlyingApplicationResolver.application(at: point)
        endPinnedTerminalSession()
        manager?.dismissPinnedTerminalFromOutsideClick(
            id: runtimeID,
            activating: application)
    }

    private func endPinnedTerminalSession() {
        terminalIsPinnedUntilOutsideClick = false
        hideDismissalShields()
    }

    private func hideDismissalShields() {
        let panels = dismissalShieldPanels
        dismissalShieldPanels.removeAll(keepingCapacity: true)
        for panel in panels {
            (panel.contentView as? GaiCompanionDismissShieldView)?.onDismiss = nil
            panel.orderOut(nil)
            panel.close()
        }
    }

    /// Moves the existing native terminal hierarchy into Teddy without
    /// creating a second renderer. Keeping the whole host together avoids two
    /// SwiftUI representables competing for the same Metal-backed SurfaceView.
    func detachTerminalContentForInlinePresentation() -> NSView? {
        guard let terminalHostView else { return nil }
        terminalPanel.orderOut(nil)

        if terminalPanel.contentView === terminalHostView {
            let placeholder = NSView(frame: terminalHostView.frame)
            placeholder.wantsLayer = true
            placeholder.layer?.backgroundColor = NSColor.black.cgColor
            terminalPanel.contentView = placeholder
        }

        terminalHostView.removeFromSuperview()
        return terminalHostView
    }

    /// Returns the native hierarchy to the floating panel when Teddy closes
    /// its inline terminal. The PTY, scrollback and renderer all stay alive.
    func restoreTerminalContentAfterInlinePresentation() {
        guard let terminalHostView,
              terminalPanel.contentView !== terminalHostView else { return }
        terminalHostView.removeFromSuperview()
        terminalHostView.autoresizingMask = [.width, .height]
        terminalPanel.contentView = terminalHostView
    }

    func show(
        companionFrame: NSRect,
        terminalFrame: NSRect?,
        placement: GaiCompanionTerminalPlacement,
        screen: NSScreen,
        presentation: GaiCompanionPresentation,
        animated: Bool,
        focus: Bool,
        agentWindowsAreVisible: Bool,
        companionIsVisible: Bool
    ) {
        if presentation != .compact {
            cancelHoverPeekLifecycle()
            endPinnedTerminalSession()
        }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        self.presentation = presentation
        if presentation != .maximized {
            terminalMoveSettleGeneration += 1
            terminalMoveSettleWorkItem?.cancel()
            terminalMoveSettleWorkItem = nil
        }
        configureTerminalResizing(for: presentation, screen: screen)
        resetLivePlacementAnimation()
        livePlacement = placement
        placementScreenNumber = screenNumber(for: screen)
        let wasVisible = terminalPanel.isVisible

        // Compact attachment happens only after the hidden terminal has its
        // target frame and alpha, otherwise adding it to a visible parent can
        // flash an old frame for one compositor pass.
        if presentation != .compact {
            updateTerminalWindowRelationship(for: presentation)
        }

        applyingCompanionFrame = true
        if !NSEqualRects(companionPanel.frame, companionFrame) {
            companionPanel.setFrame(companionFrame, display: true, animate: false)
        }
        applyingCompanionFrame = false
        previousCompanionFrame = companionFrame

        guard agentWindowsAreVisible else {
            if let terminalFrame {
                terminalPanel.alphaValue = 1
                setTerminalFrame(terminalFrame, display: false, animate: false)
                if presentation == .compact {
                    updateTerminalWindowRelationship(for: presentation)
                }
            }
            terminalPanel.orderOut(nil)
            companionPanel.orderOut(nil)
            return
        }

        if companionIsVisible {
            companionPanel.orderFrontRegardless()
        } else {
            companionPanel.orderOut(nil)
        }

        guard let terminalFrame else {
            hideTerminal(animated: animated, generation: generation)
            return
        }

        if !wasVisible && animated {
            terminalPanel.alphaValue = 0
        } else {
            terminalPanel.alphaValue = 1
        }
        setTerminalFrame(
            terminalFrame,
            display: true,
            animate: animated && wasVisible)
        if presentation == .compact {
            updateTerminalWindowRelationship(for: presentation)
        }

        if focus {
            focusTerminalOnActiveSpace()
        } else {
            terminalPanel.orderFrontRegardless()
        }

        if !wasVisible && animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                terminalPanel.animator().alphaValue = 1
            }
        }
    }

    func orderFront() {
        companionPanel.orderFrontRegardless()
        if presentation != .collapsed {
            terminalPanel.orderFrontRegardless()
        }
    }

    /// Establish the all-Spaces terminal as the activation target before the
    /// application becomes active. Activating first lets AppKit choose the old
    /// creator window and can make Mission Control jump to its previous Space.
    func focusTerminalOnActiveSpace(makeMain: Bool = false) {
        terminalPanel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
        terminalPanel.orderFrontRegardless()
        terminalPanel.makeKey()
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        terminalPanel.makeKeyAndOrderFront(nil)
        if makeMain {
            terminalPanel.makeMain()
        }
    }

    func restoreVisibilityOnActiveSpace(
        agentWindowsVisible: Bool,
        companionIsVisible: Bool
    ) {
        companionPanel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
        terminalPanel.collectionBehavior = GaiCompanionSpacePolicy.floatingOverlay
        guard agentWindowsVisible else {
            terminalPanel.orderOut(nil)
            companionPanel.orderOut(nil)
            return
        }
        if companionIsVisible {
            companionPanel.orderFrontRegardless()
        } else {
            companionPanel.orderOut(nil)
        }
        if presentation != .collapsed {
            terminalPanel.orderFrontRegardless()
        } else {
            terminalPanel.orderOut(nil)
        }
    }

    func setAgentWindowsVisible(
        _ visible: Bool,
        companionIsVisible: Bool
    ) {
        visibilityGeneration += 1
        resetLivePlacementAnimation()
        guard visible else {
            cancelHoverPeekLifecycle()
            endPinnedTerminalSession()
            terminalPanel.orderOut(nil)
            companionPanel.orderOut(nil)
            return
        }
        terminalPanel.alphaValue = 1
        if companionIsVisible {
            companionPanel.orderFrontRegardless()
        } else {
            companionPanel.orderOut(nil)
        }
        if presentation != .collapsed {
            terminalPanel.orderFrontRegardless()
        }
    }

    /// Applies live size settings without entering the general show/hide path.
    /// This deliberately preserves ordering, key state and presentation while
    /// invalidating any stale drag or side-transition work.
    func resizeCompanion(
        companionFrame: NSRect,
        terminalFrame: NSRect?,
        placement: GaiCompanionTerminalPlacement,
        screen: NSScreen
    ) {
        resetLivePlacementAnimation()
        terminalMoveSettleGeneration += 1
        terminalMoveSettleWorkItem?.cancel()
        terminalMoveSettleWorkItem = nil
        livePlacement = placement
        placementScreenNumber = screenNumber(for: screen)

        applyingCompanionFrame = true
        if !NSEqualRects(companionPanel.frame, companionFrame) {
            companionPanel.setFrame(companionFrame, display: true, animate: false)
        }
        previousCompanionFrame = companionFrame
        applyingCompanionFrame = false

        guard presentation == .compact,
              terminalPanel.isVisible,
              let terminalFrame else { return }
        setWindowFrame(terminalPanel, to: terminalFrame)
    }

    /// Dismisses the terminal at the start of a real mascot drag without
    /// entering the general layout path. A compact terminal is detached before
    /// fading so it disappears softly at its current position instead of
    /// following the mascot for the duration of the fade.
    func hideTerminalForCompanionDrag() {
        guard presentation != .collapsed else { return }
        cancelHoverPeekLifecycle()
        endPinnedTerminalSession()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        presentation = .collapsed
        resetLivePlacementAnimation()
        terminalMoveSettleGeneration += 1
        terminalMoveSettleWorkItem?.cancel()
        terminalMoveSettleWorkItem = nil
        detachTerminalWindow()
        hideTerminal(animated: true, generation: generation)
    }

    func close() {
        cancelHoverPeekLifecycle()
        endPinnedTerminalSession()
        resetLivePlacementAnimation()
        terminalMoveSettleGeneration += 1
        terminalMoveSettleWorkItem?.cancel()
        terminalMoveSettleWorkItem = nil
        if terminalPanel.parent === companionPanel {
            companionPanel.removeChildWindow(terminalPanel)
        }
        companionPanel.parent?.removeChildWindow(companionPanel)
        companionPanel.delegate = nil
        terminalPanel.delegate = nil
        if let companionPanel = companionPanel as? GaiCompanionPanel {
            companionPanel.onFileDropTargetChanged = nil
            companionPanel.onFileDrop = nil
        }
        companionPanel.unregisterDraggedTypes()
        companionPanel.orderOut(nil)
        terminalPanel.orderOut(nil)
        companionPanel.close()
        terminalPanel.close()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === terminalPanel else { return }
        manager?.panelDidBecomeKey(for: runtimeID)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === terminalPanel else { return }
        manager?.panelDidResignKey(for: runtimeID)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === terminalPanel {
            guard presentation == .maximized, !applyingTerminalFrame else { return }
            scheduleTerminalMoveSettle()
            return
        }

        guard window === companionPanel,
              !applyingCompanionFrame else { return }

        let frame = companionPanel.frame
        guard let previousFrame = previousCompanionFrame else {
            previousCompanionFrame = frame
            return
        }
        previousCompanionFrame = frame

        let deltaX = frame.minX - previousFrame.minX
        let deltaY = frame.minY - previousFrame.minY
        guard deltaX != 0 || deltaY != 0 else { return }

        // A mascot attached to the white hub is being moved by Window Server,
        // not by the user. Feeding that parent-driven move back into the agent
        // drag policy used to launch swap previews for every child on every
        // frame, which caused the visible flicker and irregular frame pacing.
        guard companionPanel.parent == nil else { return }

        // The Window Server has already moved every visible child atomically.
        // Only the desired relative placement is updated here; persistence and
        // model replacement remain deferred until the pointer is released.
        manager?.panelIsMoving(
            for: runtimeID,
            frame: frame,
            screen: companionPanel.screen)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard notification.object as? NSWindow === terminalPanel,
              presentation == .maximized else { return }
        terminalMoveSettleGeneration += 1
        terminalMoveSettleWorkItem?.cancel()
        terminalMoveSettleWorkItem = nil
        manager?.rememberExpandedTerminalFrame(
            id: runtimeID,
            frame: terminalPanel.frame,
            screen: terminalPanel.screen)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === terminalPanel,
              presentation == .maximized,
              let screen = terminalPanel.screen else { return }
        configureTerminalResizing(for: presentation, screen: screen)
    }

    func setFallbackFileDropTargeted(_ targeted: Bool) {
        updateDropTarget(targeted)
    }

    func showFallbackFileDropAccepted(fileCount: Int) {
        updateDropTarget(false)
        dropFeedback.showAccepted(fileCount: fileCount)
    }

    func setExternalFileDragInterceptionActive(_ active: Bool) {
        guard interceptingExternalFileDrag != active else { return }
        interceptingExternalFileDrag = active
        companionPanel.level = active
            ? Self.fileDragInterceptionLevel
            : Self.restingCompanionLevel
        if companionPanel.isVisible {
            companionPanel.orderFrontRegardless()
        }
    }

    private func updateDropTarget(_ targeted: Bool) {
        guard targeted != dropIsTargeted else { return }
        dropIsTargeted = targeted
        if targeted {
            cancelHoverIntent()
        }
        dropFeedback.setTargeted(targeted)
        mascotHostView?.setQuickActionsVisible(
            !targeted && manager?.explicitlySelectedCompanionID == runtimeID)
    }

    private func mascotPointerEntered() {
        pointerIsOverMascot = true
        guard GaiCompanionHoverPeekPreference.isEnabled,
              !dropIsTargeted,
              !interceptingExternalFileDrag,
              presentation == .collapsed else { return }

        cancelHoverIntent()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pointerIsOverMascot,
                  GaiCompanionHoverPeekPreference.isEnabled,
                  !self.dropIsTargeted,
                  !self.interceptingExternalFileDrag,
                  self.presentation == .collapsed else { return }
            self.hoverPeekOwnsPresentation = true
            guard self.manager?.presentTerminalPeek(id: self.runtimeID) == true else {
                self.hoverPeekOwnsPresentation = false
                return
            }
            self.startHoverPresenceTimer()
        }
        hoverIntentWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.hoverIntentDelay,
            execute: workItem)
    }

    private func mascotPointerExited() {
        pointerIsOverMascot = false
        cancelHoverIntent()
        if hoverPeekOwnsPresentation {
            updateHoverPresence()
        }
    }

    private func startHoverPresenceTimer() {
        stopHoverPresenceTimer()
        hoverBridgeLastPointer = NSEvent.mouseLocation
        hoverBridgeLastMotionAt = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: Self.hoverPresenceInterval,
            leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.updateHoverPresence()
        }
        hoverPresenceTimer = timer
        timer.resume()
    }

    private func updateHoverPresence() {
        guard hoverPeekOwnsPresentation,
              presentation == .compact,
              terminalPanel.isVisible else {
            stopHoverPresenceTimer()
            return
        }
        guard GaiCompanionHoverPeekPreference.isEnabled else {
            dismissHoverPeek()
            return
        }

        guard hoverInteractionRegionContains(
            NSEvent.mouseLocation,
            timestamp: CACurrentMediaTime()) else {
            dismissHoverPeek()
            return
        }
    }

    private func hoverInteractionRegionContains(
        _ point: NSPoint,
        timestamp: CFTimeInterval
    ) -> Bool {
        if mascotHostView?.mascotSilhouetteContains(screenPoint: point) == true {
            hoverBridgeLastPointer = point
            hoverBridgeLastMotionAt = timestamp
            return true
        }
        if terminalPanel.frame.contains(point) {
            hoverBridgeLastPointer = point
            hoverBridgeLastMotionAt = timestamp
            return true
        }
        guard let mascotFrame = mascotHostView?.mascotSpriteScreenFrame() else {
            return false
        }
        guard GaiCompanionHoverBridge.contains(
                point,
                mascotFrame: mascotFrame,
                terminalFrame: terminalPanel.frame),
              let previous = hoverBridgeLastPointer,
              GaiCompanionHoverBridge.isProgressing(
                from: previous,
                to: point,
                terminalFrame: terminalPanel.frame)
        else { return false }

        let movement = hypot(point.x - previous.x, point.y - previous.y)
        if movement >= Self.hoverBridgeMinimumMotion {
            hoverBridgeLastMotionAt = timestamp
        }
        hoverBridgeLastPointer = point
        guard let lastMotion = hoverBridgeLastMotionAt else { return false }
        return timestamp - lastMotion <= Self.hoverBridgeIdleTimeout
    }

    private func dismissHoverPeek() {
        guard hoverPeekOwnsPresentation else { return }
        // Keep ownership true until the manager has validated and collapsed
        // this exact hover preview. Clearing it first makes the manager reject
        // the dismissal as stale, leaving one compact terminal permanently
        // visible and blocking every other doudou's hover preview.
        stopHoverPresenceTimer()
        manager?.dismissTerminalPeek(id: runtimeID)
        hoverPeekOwnsPresentation = false
    }

    private func cancelHoverPeekLifecycle() {
        hoverPeekOwnsPresentation = false
        cancelHoverIntent()
        stopHoverPresenceTimer()
    }

    private func cancelHoverIntent() {
        hoverIntentWorkItem?.cancel()
        hoverIntentWorkItem = nil
    }

    private func stopHoverPresenceTimer() {
        hoverPresenceTimer?.cancel()
        hoverPresenceTimer = nil
        hoverBridgeLastPointer = nil
        hoverBridgeLastMotionAt = nil
    }

    /// Starts one bounded FLIP only when the selected side changes. During all
    /// ordinary movement, no child frame is written here: AppKit moves the
    /// attached windows atomically with their companion.
    func animateLivePlacement(
        terminalFrame: NSRect?,
        placement: GaiCompanionTerminalPlacement,
        screen: NSScreen
    ) {
        let nextScreenNumber = screenNumber(for: screen)
        let changedScreen = placementScreenNumber != nil
            && placementScreenNumber != nextScreenNumber
        placementScreenNumber = nextScreenNumber

        if changedScreen {
            settleLivePlacement(
                terminalFrame: terminalFrame,
                placement: placement,
                screen: screen)
            return
        }

        guard placement != livePlacement else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settleLivePlacement(
                terminalFrame: terminalFrame,
                placement: placement,
                screen: screen)
            return
        }
        livePlacement = placement

        let anchor = companionPanel.frame.origin
        guard presentation == .compact,
              terminalPanel.isVisible,
              let terminalFrame else {
            resetLivePlacementAnimation()
            return
        }

        placementTransition = GaiCompanionPlacementTransition(
            terminalFrom: relativeOrigin(of: terminalPanel, anchor: anchor),
            terminalTo: relativeOrigin(of: terminalFrame, anchor: anchor),
            startedAt: CACurrentMediaTime())
        placementDisplayLink.start(synchronizedTo: companionPanel.contentView)
    }

    /// Cancels any in-flight FLIP and establishes the exact geometry when
    /// crossing displays or when reduced motion disables interpolation.
    func settleLivePlacement(
        terminalFrame: NSRect?,
        placement: GaiCompanionTerminalPlacement,
        screen: NSScreen
    ) {
        resetLivePlacementAnimation()
        livePlacement = placement
        placementScreenNumber = screenNumber(for: screen)
        if presentation == .compact,
           terminalPanel.isVisible,
           let terminalFrame {
            setWindowFrame(terminalPanel, to: terminalFrame)
        }
    }

    private func advanceLivePlacementAnimation(at timestamp: CFTimeInterval) {
        guard let transition = placementTransition else {
            placementDisplayLink.stop()
            return
        }

        let linearProgress = CGFloat(
            min(
                max(
                    (timestamp - transition.startedAt)
                        / Self.placementTransitionDuration,
                    0),
                1))
        let progress = GaiCompanionPlacementTiming.value(at: linearProgress)
        let anchor = companionPanel.frame.origin

        if presentation == .compact, terminalPanel.isVisible {
            let terminalOffset = interpolated(
                from: transition.terminalFrom,
                to: transition.terminalTo,
                progress: progress)
            setWindowOrigin(
                terminalPanel,
                to: CGPoint(x: anchor.x + terminalOffset.x, y: anchor.y + terminalOffset.y))
        }

        if linearProgress >= 1 {
            placementTransition = nil
            placementDisplayLink.stop()
        }
    }

    private func relativeOrigin(of window: NSWindow, anchor: CGPoint) -> CGPoint {
        relativeOrigin(of: window.frame, anchor: anchor)
    }

    private func relativeOrigin(of frame: NSRect, anchor: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX - anchor.x, y: frame.minY - anchor.y)
    }

    private func interpolated(from: CGPoint, to: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress)
    }

    private func setWindowOrigin(_ window: NSWindow, to origin: CGPoint) {
        guard abs(window.frame.minX - origin.x) > 0.01
                || abs(window.frame.minY - origin.y) > 0.01 else { return }
        var frame = window.frame
        frame.origin = origin
        window.setFrame(frame, display: false, animate: false)
    }

    private func setWindowFrame(_ window: NSWindow, to frame: NSRect) {
        guard !NSEqualRects(window.frame, frame) else { return }
        if window === terminalPanel {
            setTerminalFrame(frame, display: false, animate: false)
            return
        }
        window.setFrame(frame, display: false, animate: false)
    }

    private func setTerminalFrame(
        _ frame: NSRect,
        display: Bool,
        animate: Bool
    ) {
        applyingTerminalFrame = true
        terminalPanel.setFrame(frame, display: display, animate: animate)
        applyingTerminalFrame = false
    }

    private func screenNumber(for screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func resetLivePlacementAnimation() {
        placementDisplayLink.stop()
        placementTransition = nil
    }

    private func updateTerminalWindowRelationship(
        for presentation: GaiCompanionPresentation
    ) {
        switch presentation {
        case .collapsed:
            // Keep a visible compact child attached until its fade completes.
            // `hideTerminal` detaches it after ordering it out.
            if !terminalPanel.isVisible {
                detachTerminalWindow()
            }
            terminalPanel.level = Self.foregroundTerminalLevel
            return

        case .maximized:
            detachTerminalWindow()
            terminalPanel.level = Self.foregroundTerminalLevel
            return

        case .compact:
            break
        }

        if terminalPanel.parent !== companionPanel {
            companionPanel.addChildWindow(terminalPanel, ordered: .above)
        }
        // `addChildWindow` initially adopts the parent's level. Restore the
        // terminal's dedicated foreground level while retaining the native
        // movement relationship. A visible terminal must cover every mascot,
        // including mascots owned by another controller.
        terminalPanel.level = Self.foregroundTerminalLevel
    }

    private func configureTerminalResizing(
        for presentation: GaiCompanionPresentation,
        screen: NSScreen
    ) {
        guard presentation == .maximized else {
            terminalPanel.styleMask.remove(.resizable)
            terminalPanel.minSize = .zero
            terminalPanel.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            return
        }

        terminalPanel.styleMask.insert(.resizable)
        let workArea = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        terminalPanel.minSize = NSSize(
            width: min(
                CGFloat(GaiCompanionExpandedTerminalSize.minimumWidth),
                workArea.width),
            height: min(
                CGFloat(GaiCompanionExpandedTerminalSize.minimumHeight),
                workArea.height))
        terminalPanel.maxSize = workArea.size
    }

    private func detachTerminalWindow() {
        if terminalPanel.parent === companionPanel {
            companionPanel.removeChildWindow(terminalPanel)
        }
    }

    private func scheduleTerminalMoveSettle() {
        terminalMoveSettleGeneration += 1
        let generation = terminalMoveSettleGeneration
        terminalMoveSettleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.terminalMoveSettleGeneration == generation,
                  self.presentation == .maximized else { return }
            self.terminalMoveSettleWorkItem = nil
            guard NSEvent.pressedMouseButtons & 1 == 0 else {
                self.scheduleTerminalMoveSettle()
                return
            }
            self.manager?.rememberExpandedTerminalFrame(
                id: self.runtimeID,
                frame: self.terminalPanel.frame,
                screen: self.terminalPanel.screen)
        }
        terminalMoveSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.moveSettleDelay,
            execute: workItem)
    }

    private func hideTerminal(animated: Bool, generation: Int) {
        guard terminalPanel.isVisible else { return }
        guard animated else {
            terminalPanel.orderOut(nil)
            detachTerminalWindow()
            terminalPanel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            terminalPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.visibilityGeneration == generation,
                  self.presentation == .collapsed else { return }
            self.terminalPanel.orderOut(nil)
            self.detachTerminalWindow()
            self.terminalPanel.alphaValue = 1
        }
    }
}

private struct GaiCompanionHubView: View {
    @ObservedObject var state: GaiCompanionHubState

    private let colorway = GaiCompanionColorway.hubColorway
    private var scaleFactor: CGFloat {
        CGFloat(GaiCompanionVisualMetrics.scaleFactor(for: state.scalePercent))
    }
    private var spriteWidth: CGFloat {
        CGFloat(GaiCompanionVisualMetrics.scaledSpriteWidth(
            for: state.scalePercent))
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())

            VStack(spacing: -4 * scaleFactor) {
                GaiCompanionSpriteView(
                    colorway: colorway,
                    animation: .idle,
                    size: spriteWidth)
                    .shadow(
                        color: Color.white.opacity(0.18),
                        radius: 11 * scaleFactor)
                Color.clear.frame(height: 24 * scaleFactor)
            }
            .padding(.bottom, 2 * scaleFactor)

            if state.companionCount > 0, state.isHovered {
                VStack {
                    HStack {
                        Spacer()
                        Text("\(state.companionCount)")
                            .font(.system(
                                size: 10 * scaleFactor,
                                weight: .bold,
                                design: .rounded))
                            .foregroundStyle(.white.opacity(0.96))
                            .padding(.horizontal, 6 * scaleFactor)
                            .padding(.vertical, 3 * scaleFactor)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .fill(Color.white.opacity(0.12))
                                    }
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .stroke(
                                                .white.opacity(0.32),
                                                lineWidth: 0.8 * scaleFactor)
                                    }
                            }
                            .shadow(
                                color: .black.opacity(0.35),
                                radius: 6 * scaleFactor,
                                y: 2 * scaleFactor)
                    }
                    Spacer()
                }
                .padding(.top, 35 * scaleFactor)
                .padding(.trailing, 9 * scaleFactor)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.14), value: state.isHovered)
        .accessibilityLabel("Pile de \(state.companionCount) doudous")
        .accessibilityValue(state.isExpanded ? "Ouverte" : "Fermée")
    }

}

private struct GaiCompanionMascotView: View {
    @ObservedObject var runtime: GaiCompanionRuntime
    @ObservedObject var dropFeedback: GaiCompanionDropFeedback

    private var accent: Color { Color(gaiRGB: runtime.record.colorway.palette.baseRGB) }
    private var scaleFactor: CGFloat {
        if runtime.collapsedStackDepth > 0 { return 1 }
        return CGFloat(GaiCompanionVisualMetrics.scaleFactor(for: runtime.record.scalePercent))
    }
    private var spriteWidth: CGFloat {
        if runtime.collapsedStackDepth > 0 {
            return CGFloat(GaiCompanionVisualMetrics.baseSpriteWidth)
        }
        return CGFloat(
            GaiCompanionVisualMetrics.scaledSpriteWidth(for: runtime.record.scalePercent))
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            if runtime.collapsedStackDepth > 1 {
                stackGhost(opacity: 0.18, x: -9, y: 6, scale: 0.88)
                stackGhost(opacity: 0.30, x: 9, y: 3, scale: 0.94)
            }

            if dropFeedback.isTargeted {
                RoundedRectangle(cornerRadius: 22 * scaleFactor, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22 * scaleFactor, style: .continuous)
                            .stroke(
                                accent.opacity(0.95),
                                style: StrokeStyle(
                                    lineWidth: max(2, 2 * scaleFactor),
                                    dash: [6 * scaleFactor, 4 * scaleFactor]))
                    }
                    .shadow(color: accent.opacity(0.72), radius: 16 * scaleFactor)
                    .padding(4 * scaleFactor)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            VStack(spacing: -4 * scaleFactor) {
                GaiCompanionSpriteView(
                    colorway: runtime.renderedColorway,
                    animation: runtime.animation,
                    size: spriteWidth)
                    .shadow(color: phaseGlow.opacity(0.85), radius: 11 * scaleFactor)
                    .scaleEffect(dropFeedback.isTargeted ? 1.08 : 1)

                if runtime.collapsedStackDepth > 0
                    || runtime.stackBadgePhase == .hidden {
                    Color.clear.frame(height: 24 * scaleFactor)
                } else {
                    nameBadge
                        .opacity(runtime.stackBadgePhase == .visible ? 1 : 0.001)
                        .animation(
                            .linear(duration: 0.075),
                            value: runtime.stackBadgePhase)
                }
            }
            .padding(.bottom, max(1, 2 * scaleFactor))

            if runtime.collapsedStackDepth > 1 {
                stackCountBadge
            }

            if dropFeedback.isTargeted {
                dropBadge(
                    title: "Déposer ici",
                    symbol: "arrow.down.doc.fill",
                    color: accent)
            } else if let fileCount = dropFeedback.acceptedFileCount {
                dropBadge(
                    title: fileCount == 1
                        ? "Chemin inséré"
                        : "\(fileCount) chemins insérés",
                    symbol: "checkmark.circle.fill",
                    color: .green)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.16), value: dropFeedback.isTargeted)
        .animation(.easeOut(duration: 0.16), value: dropFeedback.acceptedFileCount)
        .accessibilityLabel("\(runtime.record.displayName), \(runtime.phaseLabel)")
        .accessibilityValue(runtime.isDesktopSelected ? "Sélectionné" : "Non sélectionné")
    }

    private func stackGhost(
        opacity: Double,
        x: CGFloat,
        y: CGFloat,
        scale: CGFloat
    ) -> some View {
        VStack(spacing: -4 * scaleFactor) {
            GaiCompanionSpriteView(
                colorway: runtime.renderedColorway,
                animation: .idle,
                size: spriteWidth)
            Color.clear.frame(height: 24 * scaleFactor)
        }
        .scaleEffect(scale)
        .offset(x: x * scaleFactor, y: y * scaleFactor)
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var stackCountBadge: some View {
        VStack {
            HStack {
                Spacer()
                Text("\(runtime.collapsedStackDepth)")
                    .font(.system(
                        size: max(9, 10 * scaleFactor),
                        weight: .bold,
                        design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .padding(.horizontal, 6 * scaleFactor)
                    .padding(.vertical, 3 * scaleFactor)
                    .background {
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Capsule(style: .continuous)
                                    .fill(accent.opacity(0.24))
                            }
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(.white.opacity(0.32), lineWidth: 0.8)
                            }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            }
            Spacer()
        }
        .padding(.top, 35 * scaleFactor)
        .padding(.trailing, 9 * scaleFactor)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var nameBadge: some View {
        Text(runtime.record.displayName)
            .font(.system(
                size: 13 * scaleFactor,
                weight: .semibold,
                design: .rounded))
            .foregroundStyle(Color.white.opacity(0.94))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8 * scaleFactor)
            .padding(.vertical, 3.5 * scaleFactor)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(Color.gray.opacity(0.16))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(
                                Color.white.opacity(0.28),
                                lineWidth: 0.8 * scaleFactor)
                    }
            }
            .overlay(alignment: .top) {
                Capsule(style: .continuous)
                    .stroke(
                        Color.white.opacity(0.12),
                        lineWidth: 0.6 * scaleFactor)
                    .mask {
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: .bottom)
                    }
            }
            .shadow(
                color: Color.black.opacity(0.28),
                radius: 5 * scaleFactor,
                y: 2 * scaleFactor)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func dropBadge(title: String, symbol: String, color: Color) -> some View {
        VStack {
            Label(title, systemImage: symbol)
                .font(.system(size: max(9, 10 * scaleFactor), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, 8 * scaleFactor)
                .padding(.vertical, 5 * scaleFactor)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.76))
                        .overlay(Capsule().stroke(color.opacity(0.85), lineWidth: 1)))
                .shadow(color: color.opacity(0.55), radius: 7 * scaleFactor)
                .padding(.horizontal, 5 * scaleFactor)
                .padding(.top, 5 * scaleFactor)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    private var phaseGlow: Color {
        switch runtime.activity.phase {
        case .completedUnseen: .green
        case .awaitingInput, .awaitingApproval: .orange
        case .failed, .exited: .red
        case .working: accent
        case .idle: .clear
        }
    }
}

/// The exact flat terminal chrome used by the original Stage: a 30 pt header
/// directly attached to the terminal surface, with no surrounding card.
private struct GaiCompanionTerminalView: View {
    @ObservedObject var runtime: GaiCompanionRuntime

    let onToggleMaximized: () -> Void
    let onApplyLayoutPreset: (GaiCompanionTerminalLayoutPreset) -> Void
    let onToggleLock: () -> Void
    let onReplayLatestResponse: () -> Void
    let onRename: (String) -> Void
    let onClose: () -> Void
    let onChooseDirectory: (String) -> Void
    let onDirectoryDialogVisibilityChanged: (Bool) -> Void

    var body: some View {
        Group {
            if let surface = runtime.surfaceView {
                GaiCompanionLiveTerminalView(
                    runtime: runtime,
                    surfaceView: surface,
                    onToggleMaximized: onToggleMaximized,
                    onApplyLayoutPreset: onApplyLayoutPreset,
                    onToggleLock: onToggleLock,
                    onReplayLatestResponse: onReplayLatestResponse,
                    onRename: onRename,
                    onClose: onClose,
                    onChooseDirectory: onChooseDirectory,
                    onDirectoryDialogVisibilityChanged: onDirectoryDialogVisibilityChanged)
                    // An agent keeps the same UUID when its working directory
                    // changes, but Ghostty creates a new native surface. Key the
                    // subtree by that concrete incarnation so AppKit never keeps
                    // the scroll view which hosted the released terminal.
                    .id(ObjectIdentifier(surface))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.11, green: 0.11, blue: 0.118))
            }
        }
    }
}

/// Observes the surface directly so the file explorer follows live `pwd`
/// changes made inside the terminal, not only changes made from the picker.
private struct GaiCompanionLiveTerminalView: View {
    @ObservedObject var runtime: GaiCompanionRuntime
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    let onToggleMaximized: () -> Void
    let onApplyLayoutPreset: (GaiCompanionTerminalLayoutPreset) -> Void
    let onToggleLock: () -> Void
    let onReplayLatestResponse: () -> Void
    let onRename: (String) -> Void
    let onClose: () -> Void
    let onChooseDirectory: (String) -> Void
    let onDirectoryDialogVisibilityChanged: (Bool) -> Void

    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent) private var tintPanels = false

    private var accent: Color { Color(gaiRGB: runtime.record.colorway.palette.baseRGB) }
    private var paneColor: Color {
        Color.gaiTerminalPaneColor(accent: accent, tinted: tintPanels, active: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !runtime.isInlineTerminalPresented {
                floatingHeader
            }

            ZStack(alignment: .bottom) {
                GaiCompanionFastSurfaceWrapper(surfaceView: surfaceView)
                    .background(paneColor)
                    .background(GaiCompanionSurfaceLayerAsserter(
                        surfaceView: surfaceView,
                        backdrop: NSColor(paneColor).cgColor))
                    .clipped()
                    .transaction { transaction in
                        transaction.animation = nil
                    }

                if let message = surfaceView.childExitedMessage {
                    ChildExitedMessageBar(msg: message)
                        .font(.system(size: min(surfaceView.cellSize.height * 0.8, 30)))
                }
            }
            .background(paneColor)
        }
        .background(paneColor)
    }

    private var floatingHeader: some View {
        HStack(spacing: 7) {
                GaiAgentNameEditor(
                    name: runtime.record.displayName,
                    font: .system(size: 11.5, weight: .semibold, design: .rounded),
                    maximumDisplayWidth: 120,
                    fieldWidth: 112,
                    pencilButtonSize: 18,
                    accent: accent,
                    onRename: onRename,
                    onEditingEnded: restoreTerminalFocus)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 12)

                GaiDirectoryPicker(
                    path: surfaceView.pwd,
                    accent: accent,
                    onPick: onChooseDirectory,
                    onDialogVisibilityChanged: onDirectoryDialogVisibilityChanged)
                    .frame(maxWidth: 110, alignment: .leading)

                GaiCompanionWindowDragArea()
                    .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: 22, height: 2)
                            .allowsHitTesting(false)
                    }
                    .help("Move terminal window")

                GaiCompanionHeaderIconButton(
                    symbol: "waveform",
                    help: "Lire vocalement la dernière réponse de la CLI",
                    size: 18,
                    accessibilityLabel: "Lire la dernière réponse",
                    action: onReplayLatestResponse)
                GaiCompanionHeaderIconButton(
                    symbol: runtime.isTerminalLocked ? "lock.fill" : "lock.open",
                    help: runtime.isTerminalLocked
                        ? "Close terminal when focus moves away"
                        : "Keep terminal open when clicking outside",
                    emphasized: runtime.isTerminalLocked,
                    foreground: runtime.isTerminalLocked ? accent : .white,
                    size: 18,
                    accessibilityLabel: "Keep terminal open",
                    accessibilityValue: runtime.isTerminalLocked ? "On" : "Off",
                    action: onToggleLock)
                GaiCompanionLayoutPresetMenu(onSelect: onApplyLayoutPreset)
                GaiCompanionHeaderIconButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    help: "Ouvrir dans Teddy",
                    size: 18,
                    action: onToggleMaximized)
                GaiCompanionHeaderIconButton(
                    symbol: "xmark",
                    help: "Kill terminal and remove agent",
                    size: 18,
                    action: onClose)
        }
        .padding(.horizontal, 9)
        .frame(height: GaiStageMetrics.paneHeaderHeight)
        .background(Color.gaiPanelColor(accent: accent, tinted: tintPanels))
        .clipped()
    }

    private func restoreTerminalFocus() {
        DispatchQueue.main.async { [weak surfaceView] in
            guard let surfaceView,
                  let window = surfaceView.window,
                  window.isKeyWindow,
                  window.attachedSheet == nil else { return }
            window.makeFirstResponder(surfaceView)
        }
    }
}

/// Debug-local copy of the Stage's minimal surface path. Keeping it here
/// preserves complete Release isolation while retaining the same rendering
/// and focus behavior.
private struct GaiCompanionFastSurfaceWrapper: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @FocusState private var surfaceFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            Ghostty.SurfaceRepresentable(view: surfaceView, size: geometry.size)
                .focused($surfaceFocus)
                .focusedValue(\.ghosttySurfacePwd, surfaceView.pwd)
                .focusedValue(\.ghosttySurfaceView, surfaceView)
                .focusedValue(\.ghosttySurfaceCellSize, surfaceView.cellSize)
        }
        .ghosttySurfaceView(surfaceView)
    }
}

/// Mirrors the Stage's opaque surface-layer policy without adding a card,
/// border, material or shadow around the terminal.
private struct GaiCompanionSurfaceLayerAsserter: NSViewRepresentable {
    let surfaceView: Ghostty.SurfaceView
    let backdrop: CGColor

    final class AsserterView: NSView {
        weak var surfaceView: Ghostty.SurfaceView?
        var backdrop = CGColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func assertLayerPolicy() {
            guard let layer = surfaceView?.layer else { return }
            layer.compositingFilter = nil
            layer.filters = nil
            layer.backgroundFilters = nil
            layer.opacity = 1
            layer.isOpaque = true
            layer.shouldRasterize = false
            layer.drawsAsynchronously = true
            guard let superlayer = layer.superlayer else { return }
            superlayer.backgroundColor = backdrop
            superlayer.compositingFilter = nil
            superlayer.isOpaque = true
            superlayer.shouldRasterize = false
        }

        override func layout() {
            super.layout()
            assertLayerPolicy()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            assertLayerPolicy()
        }
    }

    func makeNSView(context: Context) -> AsserterView {
        let view = AsserterView()
        view.surfaceView = surfaceView
        view.backdrop = backdrop
        return view
    }

    func updateNSView(_ view: AsserterView, context: Context) {
        view.surfaceView = surfaceView
        view.backdrop = backdrop
        view.assertLayerPolicy()
        DispatchQueue.main.async { [weak view] in
            view?.assertLayerPolicy()
        }
    }
}

private struct GaiCompanionHeaderIconButton: View {
    let symbol: String
    let help: String
    var emphasized = false
    var foreground: Color = .white
    var size: CGFloat = 18
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: max(9, size * 0.5), weight: .bold))
            .foregroundStyle(foreground.opacity(emphasized ? 0.95 : 0.62))
            .frame(width: size, height: size)
            .background(Circle().fill(foreground.opacity(emphasized ? 0.16 : 0)))
            .overlay(GaiClickCatcher(action: action))
            .help(help)
            .accessibilityLabel(accessibilityLabel ?? help)
            .accessibilityValue(accessibilityValue ?? "")
    }
}

private struct GaiCompanionLayoutPresetMenu: View {
    let onSelect: (GaiCompanionTerminalLayoutPreset) -> Void

    var body: some View {
        Menu {
            presetButton(.fullScreen)
            Divider()
            Section("Halves") {
                presetButton(.leftHalf)
                presetButton(.rightHalf)
                presetButton(.topHalf)
                presetButton(.bottomHalf)
            }
            Section("Quarters") {
                presetButton(.topLeftQuarter)
                presetButton(.topRightQuarter)
                presetButton(.bottomLeftQuarter)
                presetButton(.bottomRightQuarter)
            }
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Arrange terminal window")
        .accessibilityLabel("Arrange terminal window")
    }

    private func presetButton(_ preset: GaiCompanionTerminalLayoutPreset) -> some View {
        Button {
            onSelect(preset)
        } label: {
            Label(preset.title, systemImage: preset.symbol)
        }
    }
}

private extension GaiCompanionTerminalLayoutPreset {
    var title: String {
        switch self {
        case .fullScreen: "Full screen"
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .topLeftQuarter: "Top-left quarter"
        case .topRightQuarter: "Top-right quarter"
        case .bottomLeftQuarter: "Bottom-left quarter"
        case .bottomRightQuarter: "Bottom-right quarter"
        }
    }

    var symbol: String {
        switch self {
        case .fullScreen: "rectangle.inset.filled"
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .topHalf: "rectangle.tophalf.inset.filled"
        case .bottomHalf: "rectangle.bottomhalf.inset.filled"
        case .topLeftQuarter: "arrow.up.left.square.fill"
        case .topRightQuarter: "arrow.up.right.square.fill"
        case .bottomLeftQuarter: "arrow.down.left.square.fill"
        case .bottomRightQuarter: "arrow.down.right.square.fill"
        }
    }
}

private enum GaiCompanionSizingMode: String, CaseIterable {
    case together
    case individual

    var title: String {
        switch self {
        case .together: "Whole team"
        case .individual: "One agent"
        }
    }

    var symbol: String {
        switch self {
        case .together: "link"
        case .individual: "person.fill"
        }
    }
}

/// Shared presentation background for the companion library and creator.
private struct GaiCompanionEditorialBackground: View {
    let accent: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 470)
        }
    }
}

struct GaiCompanionLibraryView: View {
    @ObservedObject var manager: GaiCompanionManager
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    @State private var isCreatingCompanion = false
    @State private var sizingMode: GaiCompanionSizingMode = .together
    @State private var selectedCompanionID: UUID?
    @State private var scaleDraft = GaiCompanionScalePercent.standard.value
    @State private var hasMixedSizes = false

    var body: some View {
        ZStack {
            libraryBackground

            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    companionsHeader

                    agentsSurface
                }
                .frame(maxHeight: .infinity, alignment: .top)

                if !manager.runtimes.isEmpty {
                    sizeToolbar
                }
            }
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .ignoresSafeArea()
        .frame(minWidth: 560, minHeight: 450)
        .sheet(isPresented: $isCreatingCompanion) {
            GaiCompanionCreationView(manager: manager)
        }
        .onAppear {
            ensureValidSelection()
            syncScaleDraft()
        }
        .onChange(of: manager.runtimes.map(\.id)) { _ in
            ensureValidSelection()
            syncScaleDraft()
        }
    }

    private var libraryBackground: some View {
        GaiCompanionEditorialBackground(accent: libraryAccent)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DouDou Company")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Every agent has their own terminal, ready to work.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Open settings")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("w", modifiers: .command)
                .help("Close DouDou Company")
            }
        }
    }

    private var sizeToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("Agent size")
                    .font(.system(size: 13, weight: .bold, design: .rounded))

                Spacer(minLength: 10)

                if manager.runtimes.count > 1 {
                    sizingModePicker
                }
            }

            Label(scopeSummary, systemImage: sizingMode.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            GaiCompanionSocialScaleControl(
                value: scaleDraft,
                isMixed: hasMixedSizes,
                accent: sizingAccent,
                onPreview: previewScale,
                onCommit: commitScale)
        }
    }

    private var sizingModePicker: some View {
        HStack(spacing: 8) {
            ForEach(GaiCompanionSizingMode.allCases, id: \.self) { mode in
                Button {
                    setSizingMode(mode)
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(mode == sizingMode
                                    ? libraryAccent.opacity(0.22)
                                    : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var companionsHeader: some View {
        HStack(spacing: 7) {
            Text("Agents")
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text("\(manager.runtimes.count)")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            if sizingMode == .individual, !manager.runtimes.isEmpty {
                Text("Select an agent to resize")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var agentsSurface: some View {
        if manager.runtimes.isEmpty {
            GaiCompanionEmptyCrewView {
                isCreatingCompanion = true
            }
        } else {
            VStack(spacing: 0) {
                if manager.runtimes.count <= 2 {
                    VStack(spacing: 0) {
                        agentRows
                    }
                    .frame(height: agentListViewportHeight)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                agentRows
                            }
                        }
                        .frame(height: agentListViewportHeight)
                        .onAppear {
                            DispatchQueue.main.async {
                                guard let newestID = manager.runtimes.last?.id else { return }
                                proxy.scrollTo(newestID, anchor: .bottom)
                            }
                        }
                        .onChange(of: manager.runtimes.map(\.id)) { ids in
                            guard let newestID = ids.last else { return }
                            withAnimation(.easeOut(duration: 0.16)) {
                                proxy.scrollTo(newestID, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()
                    .opacity(0.45)
                    .padding(.leading, 66)

                hireAgentRow
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    @ViewBuilder
    private var agentRows: some View {
        ForEach(
            Array(manager.runtimes.enumerated()),
            id: \.element.id
        ) { index, runtime in
            GaiCompanionCompactRow(
                runtime: runtime,
                manager: manager,
                isSelected: sizingMode == .individual
                    && selectedCompanionID == runtime.id,
                onSelect: { selectCompanion(runtime) })
                .id(runtime.id)

            if index < manager.runtimes.count - 1 {
                Divider()
                    .opacity(0.45)
                    .padding(.leading, 66)
            }
        }
    }

    private var hireAgentRow: some View {
        Button {
            isCreatingCompanion = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(libraryAccent.opacity(0.18))
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(libraryAccent)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Hire agent")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    Text("Add another agent to DouDou Company")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
    }

    private var agentListViewportHeight: CGFloat {
        let visibleRows = min(manager.runtimes.count, 2)
        let rowHeights = CGFloat(visibleRows) * 58
        let dividerHeights = CGFloat(max(visibleRows - 1, 0))
        return rowHeights + dividerHeights
    }

    private var scopeSummary: String {
        switch sizingMode {
        case .together:
            manager.runtimes.count == 1
                ? "Sizing applies to this agent"
                : "All \(manager.runtimes.count) agents resize together"
        case .individual:
            selectedRuntime.map {
                "Resizing \($0.record.displayName)"
            } ?? "Choose an agent"
        }
    }

    private var libraryAccent: Color {
        Color(gaiRGB: GaiCompanionColorway.purple.palette.baseRGB)
    }

    private var sizingAccent: Color { libraryAccent }

    private var selectedRuntime: GaiCompanionRuntime? {
        if let selectedCompanionID,
           let runtime = manager.runtimes.first(where: { $0.id == selectedCompanionID }) {
            return runtime
        }
        return manager.runtimes.first
    }

    private var controlledRuntimes: [GaiCompanionRuntime] {
        switch sizingMode {
        case .together:
            manager.runtimes
        case .individual:
            selectedRuntime.map { [$0] } ?? []
        }
    }

    private var controlledIDs: Set<UUID> {
        Set(controlledRuntimes.map(\.id))
    }

    private func ensureValidSelection() {
        guard let selectedCompanionID,
              manager.runtimes.contains(where: { $0.id == selectedCompanionID }) else {
            self.selectedCompanionID = manager.runtimes.first?.id
            return
        }
    }

    private func syncScaleDraft() {
        let values = controlledRuntimes.map { $0.record.scalePercent.value }
        guard !values.isEmpty else {
            scaleDraft = GaiCompanionScalePercent.standard.value
            hasMixedSizes = false
            return
        }
        let average = Double(values.reduce(0, +)) / Double(values.count)
        let steppedAverage = Int((average / 5).rounded()) * 5
        scaleDraft = GaiCompanionScalePercent(steppedAverage).value
        hasMixedSizes = Set(values).count > 1
    }

    private func setSizingMode(_ mode: GaiCompanionSizingMode) {
        sizingMode = mode
        ensureValidSelection()
        if mode == .individual,
           let runtime = selectedRuntime {
            scaleDraft = runtime.record.scalePercent.value
            hasMixedSizes = false
        } else {
            syncScaleDraft()
        }
    }

    private func selectCompanion(_ runtime: GaiCompanionRuntime) {
        sizingMode = .individual
        selectedCompanionID = runtime.id
        scaleDraft = runtime.record.scalePercent.value
        hasMixedSizes = false
    }

    private func previewScale(_ value: Int) {
        guard !controlledIDs.isEmpty else { return }
        scaleDraft = GaiCompanionScalePercent(value).value
        hasMixedSizes = false
        manager.previewScales(
            ids: controlledIDs,
            scalePercent: GaiCompanionScalePercent(scaleDraft))
    }

    private func commitScale(_ value: Int) {
        guard !controlledIDs.isEmpty else { return }
        scaleDraft = GaiCompanionScalePercent(value).value
        hasMixedSizes = false
        manager.commitScales(
            ids: controlledIDs,
            scalePercent: GaiCompanionScalePercent(scaleDraft))
    }
}

struct GaiCompanionCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: GaiCompanionManager

    @State private var colorway: GaiCompanionColorway
    @State private var scalePercent = GaiCompanionScalePercent.standard.value
    @State private var completionSoundEnabled = true

    init(manager: GaiCompanionManager) {
        self.manager = manager
        _colorway = State(initialValue: manager.suggestedCompanionColorway)
    }

    var body: some View {
        ZStack {
            GaiCompanionEditorialBackground(accent: accent)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Hire an agent")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("Choose their look and presence. You can change everything later.")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }

                GaiCompanionCreationProfilePreview(
                    colorway: colorway,
                    scalePercent: scalePercent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a color")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    GaiCompanionColorDots(
                        selection: colorway,
                        diameter: 25,
                        onSelect: { colorway = $0 })
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a size")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    GaiCompanionSocialScaleControl(
                        value: scalePercent,
                        isMixed: false,
                        accent: accent,
                        onPreview: { scalePercent = $0 },
                        onCommit: { scalePercent = $0 })
                }

                HStack(spacing: 10) {
                    Button {
                        completionSoundEnabled.toggle()
                    } label: {
                        Label(
                            completionSoundEnabled ? "Task chime on" : "Task chime off",
                            systemImage: completionSoundEnabled
                                ? "speaker.wave.2.fill"
                                : "speaker.slash.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(completionSoundEnabled
                                        ? accent.opacity(0.2)
                                        : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        manager.previewCompletionSound()
                    } label: {
                        Label("Preview chime", systemImage: "play.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        createCompanion()
                    } label: {
                        Label("Hire agent", systemImage: "sparkles")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 570)
    }

    private var accent: Color {
        Color(gaiRGB: colorway.palette.baseRGB)
    }

    private func createCompanion() {
        let selectedColorway = colorway
        let selectedScale = GaiCompanionScalePercent(scalePercent)
        let selectedSound = completionSoundEnabled
        dismiss()
        DispatchQueue.main.async {
            manager.createCompanion(
                colorway: selectedColorway,
                scalePercent: selectedScale,
                completionSoundEnabled: selectedSound)
        }
    }
}

private struct GaiCompanionCreationProfilePreview: View {
    let colorway: GaiCompanionColorway
    let scalePercent: Int

    private var accent: Color { Color(gaiRGB: colorway.palette.baseRGB) }
    private var shadow: Color { Color(gaiRGB: colorway.palette.shadowRGB) }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [accent.opacity(0.92), shadow.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Circle()
                .fill(Color.white.opacity(0.11))
                .frame(width: 120, height: 120)
                .offset(x: 195, y: 48)
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 76, height: 76)
                .offset(x: -212, y: -34)
            GaiCompanionSpriteView(
                colorway: colorway,
                animation: .idle,
                size: previewSpriteWidth)
                .padding(.bottom, 7)
                .shadow(color: shadow.opacity(0.45), radius: 14, y: 8)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                Text("New agent")
            }
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.18)))
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            Text("\(scalePercent)%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.18)))
                .padding(12)
        }
    }

    private var previewSpriteWidth: CGFloat {
        // Keep the companion visually central in the profile cover while
        // still making the full 50–200% range immediately legible.
        min(82 * CGFloat(scalePercent) / 100, 138).rounded()
    }
}

/// One stable inline editor shared by the company list and terminal chrome.
/// Editing never changes the surrounding layout, so controls do not jump when
/// the text field appears.
private struct GaiAgentNameEditor: View {
    let name: String
    let font: Font
    let maximumDisplayWidth: CGFloat
    let fieldWidth: CGFloat
    let pencilButtonSize: CGFloat
    let accent: Color
    let onActivate: (() -> Void)?
    let onRename: (String) -> Void
    let onEditingEnded: () -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isHoveringPencil = false
    @FocusState private var fieldFocused: Bool

    init(
        name: String,
        font: Font,
        maximumDisplayWidth: CGFloat,
        fieldWidth: CGFloat,
        pencilButtonSize: CGFloat,
        accent: Color,
        onActivate: (() -> Void)? = nil,
        onRename: @escaping (String) -> Void,
        onEditingEnded: @escaping () -> Void = {}
    ) {
        self.name = name
        self.font = font
        self.maximumDisplayWidth = maximumDisplayWidth
        self.fieldWidth = fieldWidth
        self.pencilButtonSize = pencilButtonSize
        self.accent = accent
        self.onActivate = onActivate
        self.onRename = onRename
        self.onEditingEnded = onEditingEnded
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("Agent name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(
                        width: fieldWidth,
                        height: max(20, pencilButtonSize))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(accent.opacity(0.62), lineWidth: 1))
                    .focused($fieldFocused)
                    .onSubmit(commitEditing)
                    .onExitCommand(perform: cancelEditing)
                    .accessibilityLabel("Agent name")
            } else {
                HStack(spacing: 3) {
                    if let onActivate {
                        Button(action: onActivate) {
                            nameLabel
                        }
                        .buttonStyle(.plain)
                    } else {
                        nameLabel
                    }

                    Button(action: beginEditing) {
                        Image(systemName: "pencil")
                            .font(.system(size: max(9, pencilButtonSize * 0.52), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: pencilButtonSize, height: pencilButtonSize)
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(isHoveringPencil ? 0.08 : 0)))
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringPencil = $0 }
                    .help("Rename agent")
                    .accessibilityLabel("Rename \(name)")
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: isEditing)
        .onChange(of: fieldFocused) { focused in
            if !focused, isEditing {
                commitEditing()
            }
        }
        .onChange(of: name) { nextName in
            if !isEditing {
                draft = nextName
            }
        }
    }

    private var nameLabel: some View {
        Text(name)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maximumDisplayWidth, alignment: .leading)
    }

    private func beginEditing() {
        draft = name
        withAnimation(.easeOut(duration: 0.12)) {
            isEditing = true
        }
        DispatchQueue.main.async {
            fieldFocused = true
        }
    }

    private func commitEditing() {
        guard isEditing else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = String(trimmed.prefix(40))
        isEditing = false
        fieldFocused = false
        if !normalizedName.isEmpty, normalizedName != name {
            onRename(normalizedName)
        }
        onEditingEnded()
    }

    private func cancelEditing() {
        guard isEditing else { return }
        draft = name
        isEditing = false
        fieldFocused = false
        onEditingEnded()
    }
}

private struct GaiCompanionCompactRow: View {
    @ObservedObject var runtime: GaiCompanionRuntime
    let manager: GaiCompanionManager
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isChoosingColor = false
    @State private var isHovering = false
    @StateObject private var dropFeedback = GaiCompanionDropFeedback()

    private var selectionAccent: Color {
        Color(gaiRGB: GaiCompanionColorway.purple.palette.baseRGB)
    }

    var body: some View {
        HStack(spacing: 9) {
            avatarControl
                .overlay {
                    if dropFeedback.isTargeted {
                        Circle()
                            .fill(selectionAccent.opacity(0.16))
                            .overlay {
                                Circle()
                                    .stroke(
                                        selectionAccent,
                                        style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                            }
                            .allowsHitTesting(false)
                    } else if dropFeedback.acceptedFileCount != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.72)))
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(dropFeedback.isTargeted ? 1.08 : 1)
                .animation(.easeOut(duration: 0.16), value: dropFeedback.isTargeted)
                .dropDestination(for: URL.self) { urls, _ in
                    acceptDroppedFileURLs(urls)
                } isTargeted: { targeted in
                    dropFeedback.setTargeted(targeted)
                }

            VStack(alignment: .leading, spacing: 2) {
                GaiAgentNameEditor(
                    name: runtime.record.displayName,
                    font: .system(size: 13, weight: .bold, design: .rounded),
                    maximumDisplayWidth: 160,
                    fieldWidth: 158,
                    pencilButtonSize: 18,
                    accent: selectionAccent,
                    onActivate: onSelect,
                    onRename: { manager.updateName(id: runtime.id, name: $0) })

                Button(action: onSelect) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(phaseColor)
                            .frame(width: 6, height: 6)
                        Text(runtime.phaseLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(gaiCompanionFolderName(for: runtime.record))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button(action: onSelect) {
                Text("\(runtime.record.scalePercent.value)%")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selectionAccent)
            }

            Button {
                manager.updateCompletionSound(
                    id: runtime.id,
                    enabled: !runtime.record.completionSoundEnabled)
            } label: {
                Image(systemName: runtime.record.completionSoundEnabled
                    ? "speaker.wave.2.fill"
                    : "speaker.slash.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(runtime.record.completionSoundEnabled
                                ? selectionAccent.opacity(0.16)
                                : Color.primary.opacity(0.055)))
            }
            .buttonStyle(.plain)
            .help(runtime.record.completionSoundEnabled ? "Mute task chime" : "Turn task chime on")

            Button {
                manager.showCompanion(id: runtime.id)
            } label: {
                Label("Open desk", systemImage: "terminal")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.075)))
            }
            .buttonStyle(.plain)
            .help("Open agent terminal")

            Menu {
                Button {
                    manager.previewCompletionSound()
                } label: {
                    Label("Preview task chime", systemImage: "play.fill")
                }
                Divider()
                Button(role: .destructive) {
                    manager.requestCloseCompanion(id: runtime.id)
                } label: {
                    Label("Remove agent", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.055)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected
                    ? selectionAccent.opacity(0.10)
                    : isHovering ? Color.primary.opacity(0.035) : .clear))
        .onHover { isHovering = $0 }
    }

    private var avatarControl: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: onSelect) {
                avatar
            }
            .buttonStyle(.plain)

            Button {
                isChoosingColor.toggle()
            } label: {
                Circle()
                    .fill(Color(gaiRGB: runtime.record.colorway.palette.baseRGB))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.62), lineWidth: 1))
                    .padding(3)
                    .background(
                        Circle()
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
            }
            .buttonStyle(.plain)
            .help("Change agent color")
            .accessibilityLabel("Change agent color")
            .popover(isPresented: $isChoosingColor, arrowEdge: .trailing) {
                colorPickerPopover
            }
        }
        .frame(width: 42, height: 42)
    }

    private func acceptDroppedFileURLs(_ urls: [URL]) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        manager.insertDroppedFileURLs(fileURLs, into: runtime.id)
        dropFeedback.showAccepted(fileCount: fileURLs.count)
        return true
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.16))
            GaiCompanionSpriteView(
                colorway: runtime.renderedColorway,
                animation: runtime.animation,
                size: 35)
        }
        .frame(width: 42, height: 42)
    }

    private var colorPickerPopover: some View {
        ZStack {
            GaiCompanionEditorialBackground(
                accent: Color(gaiRGB: runtime.record.colorway.palette.baseRGB))

            VStack(alignment: .leading, spacing: 12) {
                Text("Agent color")
                    .font(.system(size: 13, weight: .bold, design: .rounded))

                GaiCompanionColorDots(
                    selection: runtime.record.colorway,
                    diameter: 22,
                    onSelect: { colorway in
                        manager.updateColorway(id: runtime.id, colorway: colorway)
                        isChoosingColor = false
                    })
            }
            .padding(16)
        }
    }

    private var phaseColor: Color {
        switch runtime.activity.phase {
        case .working: selectionAccent
        case .awaitingInput, .awaitingApproval: .orange
        case .completedUnseen: .green
        case .failed, .exited: .red
        case .idle: Color.primary.opacity(0.42)
        }
    }
}

private struct GaiCompanionColorDots: View {
    let selection: GaiCompanionColorway
    var diameter: CGFloat
    let onSelect: (GaiCompanionColorway) -> Void

    var body: some View {
        HStack(spacing: max(6, diameter * 0.34)) {
            ForEach(GaiCompanionColorway.selectableColorways) { colorway in
                Button {
                    onSelect(colorway)
                } label: {
                    Circle()
                        .fill(Color(gaiRGB: colorway.palette.baseRGB))
                        .frame(width: diameter, height: diameter)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.16), lineWidth: 1))
                        .overlay(
                            Circle()
                                .stroke(
                                    Color.primary.opacity(selection == colorway ? 0.92 : 0),
                                    lineWidth: 2)
                                .padding(-3))
                }
                .buttonStyle(.plain)
                .help(colorway.displayName)
                .accessibilityLabel("\(colorway.displayName) agent color")
                .accessibilityAddTraits(selection == colorway ? .isSelected : [])
            }
        }
    }
}

private struct GaiCompanionKnobArc: Shape {
    let progress: CGFloat

    func path(in rect: CGRect) -> Path {
        let diameter = min(rect.width, rect.height)
        let radius = max(1, diameter / 2 - 5)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(135),
            endAngle: .degrees(135 + 270 * Double(min(max(progress, 0), 1))),
            clockwise: false)
        return path
    }
}

private struct GaiCompanionSocialScaleControl: View {
    let value: Int
    let isMixed: Bool
    let accent: Color
    let onPreview: (Int) -> Void
    let onCommit: (Int) -> Void

    private let knobSize: CGFloat = 96

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            knob

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    isMixed ? "Mixed sizes" : sizeMood,
                    systemImage: isMixed ? "circle.grid.2x2.fill" : "sparkles")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))

                Text("Turn the dial or adjust in 5% steps.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    scaleButton(symbol: "minus", direction: -5)

                    Text("5%")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)

                    scaleButton(symbol: "plus", direction: 5)

                    Spacer(minLength: 8)

                    Button {
                        applyImmediately(GaiCompanionScalePercent.standard.value)
                    } label: {
                        Label("100%", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.065)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isMixed && value == GaiCompanionScalePercent.standard.value)
                    .opacity(!isMixed && value == GaiCompanionScalePercent.standard.value ? 0.45 : 1)
                    .help("Reset to standard size")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent size")
        .accessibilityValue(isMixed ? "Mixed sizes" : "\(value) percent")
    }

    private var knob: some View {
        ZStack {
            GaiCompanionKnobArc(progress: 1)
                .stroke(
                    Color.primary.opacity(0.09),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round))

            GaiCompanionKnobArc(progress: progress)
                .stroke(
                    accent,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .shadow(color: accent.opacity(0.24), radius: 4)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.12), Color.black.opacity(0.24)],
                        center: .topLeading,
                        startRadius: 1,
                        endRadius: 48))
                .frame(width: 67, height: 67)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.09), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.38), radius: 7, y: 4)

            Circle()
                .fill(Color.white.opacity(0.88))
                .frame(width: 6, height: 6)
                .offset(y: -27)
                .rotationEffect(.degrees(knobAngle + 90))

            if isMixed {
                Text("Mixed")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(value)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: knobSize, height: knobSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    onPreview(scaleValue(at: gesture.location))
                }
                .onEnded { gesture in
                    onCommit(scaleValue(at: gesture.location))
                })
        .help("Drag around the dial to change agent size")
    }

    private var progress: CGFloat {
        CGFloat(value - GaiCompanionScalePercent.minimum)
            / CGFloat(GaiCompanionScalePercent.maximum - GaiCompanionScalePercent.minimum)
    }

    private var knobAngle: Double {
        135 + 270 * Double(min(max(progress, 0), 1))
    }

    private var sizeMood: String {
        switch value {
        case ...75: "Compact"
        case ...110: "Standard"
        case ...145: "Prominent"
        default: "Commanding"
        }
    }

    @ViewBuilder
    private func scaleButton(symbol: String, direction: Int) -> some View {
        let next = GaiCompanionScalePercent(value + direction).value
        Button {
            applyImmediately(next)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(!isMixed && next == value)
    }

    private func applyImmediately(_ next: Int) {
        onPreview(next)
        onCommit(next)
    }

    private func scaleValue(at location: CGPoint) -> Int {
        let center = CGPoint(x: knobSize / 2, y: knobSize / 2)
        var angle = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
        if angle < 0 { angle += 360 }

        let adjustedAngle: CGFloat
        if angle < 45 {
            adjustedAngle = angle + 360
        } else if angle < 135 {
            // The 90° gap is intentionally inactive. Staying on the nearest
            // end avoids a violent jump when the pointer crosses below the dial.
            adjustedAngle = progress < 0.5 ? 135 : 405
        } else {
            adjustedAngle = angle
        }
        let nextProgress = min(max((adjustedAngle - 135) / 270, 0), 1)
        let raw = Double(GaiCompanionScalePercent.minimum)
            + Double(nextProgress)
                * Double(GaiCompanionScalePercent.maximum - GaiCompanionScalePercent.minimum)
        return GaiCompanionScalePercent(Int((raw / 5).rounded()) * 5).value
    }
}

private struct GaiCompanionEmptyCrewView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.055))
                    .frame(width: 56, height: 56)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text("DouDou Company starts here")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("Hire your first digital agent. Their terminal is always one click away.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onCreate()
            } label: {
                Label("Hire your first agent", systemImage: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(gaiRGB: GaiCompanionColorway.purple.palette.baseRGB))
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08)))
    }
}

private func gaiCompanionFolderName(for record: GaiCompanionRecord) -> String {
    let path = record.directoryPath
    if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? "/" : name
}

private extension Color {
    init(gaiRGB value: UInt32) {
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
#endif
