#if os(macOS)
import AppKit
import CoreVideo
import GhosttyKit
import QuartzCore
import SwiftUI

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

private final class GaiCompanionFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onFileDropTargetChanged: ((Bool) -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    private let hostingView: NSHostingView<Content>
    private var clickGeneration: UInt64 = 0

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

    /// Preserve a responsive single click while still giving a genuinely fast
    /// second click enough time to replace it without flashing the compact
    /// terminal first.
    private static var singleClickDelay: TimeInterval {
        min(NSEvent.doubleClickInterval, 0.28)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
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
            clickGeneration &+= 1
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
        var exceededDragThreshold = false
        let notificationCenter = NotificationCenter.default
        let movementObserver = notificationCenter.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard !exceededDragThreshold,
                  let origin = window?.frame.origin,
                  hypot(origin.x - startOrigin.x, origin.y - startOrigin.y) >= 6
            else { return }

            exceededDragThreshold = true
            self?.onDragBegan?()
        }
        defer {
            notificationCenter.removeObserver(movementObserver)
        }

        window.performDrag(with: event)

        let endPointer = NSEvent.mouseLocation
        let pointerDistance = hypot(
            endPointer.x - startPointer.x,
            endPointer.y - startPointer.y)
        let windowDistance = hypot(
            window.frame.minX - startOrigin.x,
            window.frame.minY - startOrigin.y)
        let completedDrag = exceededDragThreshold
            || pointerDistance >= 6
            || windowDistance >= 6
        if completedDrag {
            if !exceededDragThreshold {
                onDragBegan?()
            }
            onDragEnded?()
            return
        }
        let endInWindow = window.convertPoint(fromScreen: endPointer)
        let endInView = convert(endInWindow, from: nil)
        guard bounds.contains(endInView) else { return }

        clickGeneration &+= 1
        let generation = clickGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.singleClickDelay
        ) { [weak self] in
            guard let self, self.clickGeneration == generation else { return }
            self.onClick?()
        }
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

/// Display-synchronised main-thread ticks with coalescing. `CVDisplayLink`
/// calls back off-main; the data source merges frames if AppKit is briefly busy
/// instead of building a queue of stale animation work.
private final class GaiCompanionDisplayLink {
    private let onFrame: (CFTimeInterval) -> Void
    private let frameSource: DispatchSourceUserDataAdd
    private var displayLink: CVDisplayLink?
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

    func start() {
        guard !running else { return }
        running = true
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
    private lazy var placementDisplayLink = GaiCompanionDisplayLink { [weak self] timestamp in
        self?.advanceLivePlacementAnimation(at: timestamp)
    }

    /// Native window dragging can emit more move callbacks than the display can
    /// present. Keep normal dragging entirely in the Window Server, then persist
    /// and perform one exact final layout once the pointer has settled.
    private static let moveSettleDelay: TimeInterval = 0.1
    private static let placementTransitionDuration: CFTimeInterval = 0.18
    private static let restingCompanionLevel = NSWindow.Level(
        rawValue: GaiFloatingPanels.overlayLevel.rawValue + 1)
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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        companionPanel.level = Self.restingCompanionLevel
        companionPanel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
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
        terminalPanel.level = GaiFloatingPanels.overlayLevel
        terminalPanel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
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
            manager?.toggleTerminal(id: runtime.id)
        }
        mascotHost.onDoubleClick = { [weak manager] in
            manager?.openMaximizedTerminal(id: runtime.id)
        }
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
        // Installing an NSHostingView hierarchy can replace native drag
        // registrations. Register both concrete destinations only after the
        // final content view is attached to the panel.
        companionPanel.unregisterDraggedTypes()
        companionPanel.registerForDraggedTypes(
            GaiCompanionFileDropPayload.readableTypes)

        let terminalRoot = GaiCompanionTerminalView(
            runtime: runtime,
            onToggleMaximized: { [weak manager] in manager?.toggleMaximized(id: runtime.id) },
            onApplyLayoutPreset: { [weak manager] preset in
                manager?.applyExpandedTerminalLayout(id: runtime.id, preset: preset)
            },
            onToggleLock: { [weak manager] in manager?.toggleTerminalLock(id: runtime.id) },
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
        agentWindowsAreVisible: Bool
    ) {
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

        companionPanel.orderFrontRegardless()

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
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            terminalPanel.makeKeyAndOrderFront(nil)
        } else {
            terminalPanel.orderFrontRegardless()
        }
        companionPanel.orderFrontRegardless()

        if !wasVisible && animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                terminalPanel.animator().alphaValue = 1
            }
        }
    }

    func orderFront() {
        if presentation != .collapsed {
            terminalPanel.orderFrontRegardless()
        }
        companionPanel.orderFrontRegardless()
    }

    func setAgentWindowsVisible(_ visible: Bool) {
        visibilityGeneration += 1
        resetLivePlacementAnimation()
        guard visible else {
            terminalPanel.orderOut(nil)
            companionPanel.orderOut(nil)
            return
        }
        terminalPanel.alphaValue = 1
        orderFront()
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
        resetLivePlacementAnimation()
        terminalMoveSettleGeneration += 1
        terminalMoveSettleWorkItem?.cancel()
        terminalMoveSettleWorkItem = nil
        if terminalPanel.parent === companionPanel {
            companionPanel.removeChildWindow(terminalPanel)
        }
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
        dropFeedback.setTargeted(targeted)
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
        placementDisplayLink.start()
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
            terminalPanel.level = GaiFloatingPanels.overlayLevel
            return

        case .maximized:
            detachTerminalWindow()
            terminalPanel.level = GaiFloatingPanels.overlayLevel
            return

        case .compact:
            break
        }

        if terminalPanel.parent !== companionPanel {
            companionPanel.addChildWindow(terminalPanel, ordered: .below)
        }
        // `addChildWindow` initially adopts the parent's level. Restore the
        // terminal's lower global level while retaining the native movement
        // relationship, so terminals can never cover another mascot.
        terminalPanel.level = GaiFloatingPanels.overlayLevel
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

private final class GaiCompanionLibraryWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class GaiCompanionLibraryWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(manager: GaiCompanionManager) {
        let window = GaiCompanionLibraryWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false)
        window.title = "DouDou Company"
        window.minSize = NSSize(width: 560, height: 450)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.animationBehavior = .documentWindow
        window.tabbingMode = .disallowed
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("gai.companion.library")
        let hostingView = NSHostingView(
            rootView: GaiCompanionLibraryView(
                manager: manager,
                onClose: { [weak window] in window?.performClose(nil) }))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 24
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        window.contentView = hostingView
        window.setContentSize(NSSize(width: 600, height: 500))
        window.invalidateShadow()
        self.window = window
        super.init()
        window.delegate = self
    }

    func show(activate: Bool) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if activate {
            NSApp.unhide(nil)
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            window.makeKeyAndOrderFront(nil)
        } else if NSApp.isActive {
            window.orderFront(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The close affordance behaves like a lightweight background action:
        // the library disappears, while agents and their PTYs continue running.
        sender.orderOut(nil)
        return false
    }
}

private struct GaiCompanionMascotView: View {
    @ObservedObject var runtime: GaiCompanionRuntime
    @ObservedObject var dropFeedback: GaiCompanionDropFeedback

    private var accent: Color { Color(gaiRGB: runtime.record.colorway.palette.baseRGB) }
    private var scaleFactor: CGFloat {
        CGFloat(GaiCompanionVisualMetrics.scaleFactor(for: runtime.record.scalePercent))
    }
    private var spriteWidth: CGFloat {
        CGFloat(GaiCompanionVisualMetrics.scaledSpriteWidth(for: runtime.record.scalePercent))
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

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

                nameBadge
            }
            .padding(.bottom, max(1, 2 * scaleFactor))

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
                    symbol: runtime.presentation == .maximized
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    help: runtime.presentation == .maximized
                        ? "Restore compact terminal"
                        : "Maximize terminal",
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

/// The creation sheet is the visual source of truth for every companion
/// surface. Keeping the background in one place prevents the library from
/// drifting back toward a conventional utility-window appearance.
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

private struct GaiCompanionLibraryView: View {
    @ObservedObject var manager: GaiCompanionManager
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

private struct GaiCompanionCreationView: View {
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
