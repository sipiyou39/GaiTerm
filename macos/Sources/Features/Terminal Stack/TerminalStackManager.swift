#if os(macOS)
import AppKit
import Combine
import SwiftUI

struct TerminalStackCard: Identifiable, Equatable {
    let id: UUID
    var title: String
    var subtitle: String
    var snapshot: NSImage?
}

final class TerminalStackModel: ObservableObject {
    @Published var cards: [TerminalStackCard] = []
    @Published var isExpanded: Bool = false
    @Published var hoveredID: UUID?
    @Published var pinnedPreviewID: UUID?
    @Published var selectedID: UUID?

    var activePreviewID: UUID? {
        selectedID ?? pinnedPreviewID ?? hoveredID
    }

    var activePreviewCard: TerminalStackCard? {
        guard let id = activePreviewID else { return nil }
        return cards.first { $0.id == id }
    }
}

private final class TerminalStackEntry {
    let id: UUID
    weak var window: NSWindow?
    weak var controller: TerminalController?
    var savedFrame: NSRect
    var detachedContentView: NSView?
    var parkingContentView: NSView?

    init(id: UUID, window: NSWindow, controller: TerminalController, savedFrame: NSRect) {
        self.id = id
        self.window = window
        self.controller = controller
        self.savedFrame = savedFrame
    }
}

private final class TerminalStackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TerminalStackManager {
    static let shared = TerminalStackManager()

    let model = TerminalStackModel()

    private var panel: NSPanel?
    private var entries: [UUID: TerminalStackEntry] = [:]
    private var windowIDs: [ObjectIdentifier: UUID] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var clickOutsideLocalMonitor: Any?
    private var clickOutsideGlobalMonitor: Any?
    private var isRestoringWindow = false
    private var hoverClearWorkItem: DispatchWorkItem?
    private weak var liveHostView: NSView?
    private var liveHostCardID: UUID?
    private var liveHostConstraints: [NSLayoutConstraint] = []

    private let cardWidth: CGFloat = 226
    private let collapsedHeight: CGFloat = 214

    var hasCollapsedTerminals: Bool {
        !model.cards.isEmpty
    }

    private init() {}

    func collapseWhenReady(_ controllers: [TerminalController]) {
        ensurePanel()

        for (index, controller) in controllers.enumerated() {
            let delay = 0.42 + (Double(index) * 0.08)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak controller] in
                guard let self, let controller else { return }
                _ = self.collapse(controller: controller)
            }
        }

    }

    @discardableResult
    func collapse(window: NSWindow?) -> Bool {
        guard !isRestoringWindow else { return false }
        guard let window, let controller = window.windowController as? TerminalController else { return false }
        return collapse(controller: controller)
    }

    @discardableResult
    private func collapse(controller: TerminalController) -> Bool {
        guard let window = controller.window else { return false }
        guard !window.styleMask.contains(.fullScreen) else { return false }
        guard !(window is NSPanel) else { return false }

        ensurePanel()

        let windowID = ObjectIdentifier(window)
        if let existingID = windowIDs[windowID] {
            entries[existingID]?.savedFrame = window.frame
            updateCard(existingID, from: window)
            hide(window: window, controller: controller)
            return true
        }

        let id = UUID()
        let entry = TerminalStackEntry(
            id: id,
            window: window,
            controller: controller,
            savedFrame: window.frame
        )

        entries[id] = entry
        windowIDs[windowID] = id
        model.cards.append(makeCard(id: id, from: window))
        hide(window: window, controller: controller)
        refreshPanelVisibility()
        return true
    }

    func toggleExpanded() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            model.isExpanded.toggle()
            if !model.isExpanded {
                model.hoveredID = nil
                model.pinnedPreviewID = nil
                model.selectedID = nil
            }
        }
        if !model.isExpanded {
            detachLiveTerminal()
        }
        updateMouseInteraction()
    }

    func setHoveredCard(_ id: UUID?) {
        guard model.isExpanded else { return }
        hoverClearWorkItem?.cancel()

        if let id {
            model.hoveredID = id
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.model.pinnedPreviewID == nil else { return }
                self.model.hoveredID = nil
                self.updateMouseInteraction()
            }
            hoverClearWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
        }
        updateMouseInteraction()
    }

    func pinPreview(_ id: UUID?) {
        model.pinnedPreviewID = id
        updateMouseInteraction()
    }

    func selectInlineTerminal(_ id: UUID) {
        guard entries[id] != nil else { return }

        withAnimation(.easeOut(duration: 0.12)) {
            model.selectedID = id
            model.hoveredID = id
            model.pinnedPreviewID = nil
        }

        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateMouseInteraction()
    }

    func attachLiveTerminal(cardID: UUID, to hostView: NSView) {
        guard model.selectedID == cardID else { return }
        guard let entry = entries[cardID], let window = entry.window else { return }

        if liveHostCardID == cardID, liveHostView === hostView {
            focusLiveTerminal(entry)
            return
        }

        detachLiveTerminal()

        let contentView: NSView
        if let detached = entry.detachedContentView {
            contentView = detached
        } else if let current = window.contentView {
            entry.detachedContentView = current
            entry.parkingContentView = NSView(frame: current.frame)
            window.contentView = entry.parkingContentView
            contentView = current
        } else {
            return
        }

        contentView.removeFromSuperview()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(contentView)
        liveHostConstraints = [
            contentView.topAnchor.constraint(equalTo: hostView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            contentView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            contentView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
        ]
        NSLayoutConstraint.activate(liveHostConstraints)

        liveHostCardID = cardID
        liveHostView = hostView
        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusLiveTerminal(entry)
    }

    func detachLiveTerminal(from hostView: NSView) {
        guard liveHostView === hostView else { return }
        detachLiveTerminal()
    }

    func restore(cardID: UUID) {
        guard let entry = entries[cardID], let window = entry.window else {
            remove(cardID: cardID)
            return
        }

        isRestoringWindow = true
        defer {
            isRestoringWindow = false
        }

        detachLiveTerminal()

        remove(cardID: cardID)

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            if visible.intersects(entry.savedFrame) {
                window.setFrame(entry.savedFrame, display: true, animate: true)
            } else {
                window.center()
            }
        } else {
            window.setFrame(entry.savedFrame, display: true, animate: true)
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        entry.controller?.windowDidChangeOcclusionState(Notification(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        ))
        NSApp.activate(ignoringOtherApps: true)
    }

    func remove(window: NSWindow) {
        let windowID = ObjectIdentifier(window)
        guard let cardID = windowIDs[windowID] else { return }
        remove(cardID: cardID)
    }

    private func remove(cardID: UUID) {
        if liveHostCardID == cardID {
            detachLiveTerminal()
        }

        if let window = entries[cardID]?.window {
            windowIDs.removeValue(forKey: ObjectIdentifier(window))
        }
        entries.removeValue(forKey: cardID)
        model.cards.removeAll { $0.id == cardID }

        if model.cards.isEmpty {
            withAnimation(.easeOut(duration: 0.18)) {
                model.isExpanded = false
                model.hoveredID = nil
                model.pinnedPreviewID = nil
                model.selectedID = nil
            }
        } else if model.activePreviewID == cardID {
            model.hoveredID = nil
            model.pinnedPreviewID = nil
            model.selectedID = nil
        }

        refreshPanelVisibility()
    }

    private func updateCard(_ id: UUID, from window: NSWindow) {
        guard let index = model.cards.firstIndex(where: { $0.id == id }) else { return }
        model.cards[index] = makeCard(id: id, from: window)
    }

    private func updateCardSnapshot(_ id: UUID, image: NSImage?) {
        guard let index = model.cards.firstIndex(where: { $0.id == id }) else { return }
        model.cards[index].snapshot = image
    }

    private func makeCard(id: UUID, from window: NSWindow) -> TerminalStackCard {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty || title == "GaiTerm" ? "Terminal \(model.cards.count + 1)" : title
        let size = window.contentView?.bounds.size ?? window.frame.size
        let subtitle = "\(Int(size.width)) x \(Int(size.height))"
        return TerminalStackCard(
            id: id,
            title: displayTitle,
            subtitle: subtitle,
            snapshot: snapshot(of: window)
        )
    }

    private func hide(window: NSWindow, controller: TerminalController) {
        window.orderOut(nil)
        controller.windowDidChangeOcclusionState(Notification(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        ))
    }

    private func snapshot(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView else { return nil }
        return snapshot(of: view)
    }

    private func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 20, bounds.height > 20 else { return nil }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image.downscaled(maxDimension: 1600)
    }

    private func detachLiveTerminal() {
        guard let cardID = liveHostCardID, let entry = entries[cardID] else {
            liveHostConstraints.removeAll()
            liveHostView = nil
            liveHostCardID = nil
            return
        }

        if !liveHostConstraints.isEmpty {
            NSLayoutConstraint.deactivate(liveHostConstraints)
            liveHostConstraints.removeAll()
        }

        guard let contentView = entry.detachedContentView else {
            liveHostView = nil
            liveHostCardID = nil
            return
        }

        updateCardSnapshot(cardID, image: snapshot(of: contentView))
        contentView.removeFromSuperview()

        if let window = entry.window {
            window.contentView = contentView
            window.orderOut(nil)
            entry.controller?.windowDidChangeOcclusionState(Notification(
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            ))
        }

        entry.detachedContentView = nil
        entry.parkingContentView = nil
        liveHostView = nil
        liveHostCardID = nil
    }

    private func focusLiveTerminal(_ entry: TerminalStackEntry) {
        DispatchQueue.main.async { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.panel?.makeKeyAndOrderFront(nil)
            if let focusedSurface = entry.controller?.focusedSurface {
                focusedSurface.window?.makeFirstResponder(focusedSurface)
            }
        }
    }

    private func ensurePanel() {
        if panel != nil { return }
        guard let screen = NSScreen.main else { return }

        let frame = panelFrame(for: screen)
        let panel = TerminalStackPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let view = NSHostingView(rootView: TerminalStackOverlayView(
            model: model,
            onToggleExpanded: { [weak self] in self?.toggleExpanded() },
            onHover: { [weak self] id in self?.setHoveredCard(id) },
            onSelect: { [weak self] id in self?.selectInlineTerminal(id) }
        ))
        view.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = view

        self.panel = panel
        setupPanelObservers()
        setupMouseMonitors()
    }

    private func setupPanelObservers() {
        guard cancellables.isEmpty else { return }

        model.$cards
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshPanelVisibility()
                self?.updateMouseInteraction()
            }
            .store(in: &cancellables)

        model.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMouseInteraction() }
            .store(in: &cancellables)

        model.$hoveredID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMouseInteraction() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalWindowWillClose(_:)),
            name: TerminalWindow.terminalWillCloseNotification,
            object: nil
        )
    }

    private func setupMouseMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.updateMouseInteraction()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateMouseInteraction()
        }
        clickOutsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.collapseExpandedIfClickIsOutside()
            return event
        }
        clickOutsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.collapseExpandedIfClickIsOutside()
        }
    }

    @objc private func screenDidChange() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = panelFrame(for: screen)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        updateMouseInteraction()
    }

    @objc private func terminalWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        remove(window: window)
    }

    private func refreshPanelVisibility() {
        guard let panel else { return }

        if model.cards.isEmpty {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func collapseExpandedIfClickIsOutside() {
        guard model.isExpanded else { return }
        guard let rect = currentInteractiveRect() else { return }
        guard !rect.contains(NSEvent.mouseLocation) else { return }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            model.isExpanded = false
            model.hoveredID = nil
            model.pinnedPreviewID = nil
            model.selectedID = nil
        }
        detachLiveTerminal()
    }

    private func updateMouseInteraction() {
        guard let panel, panel.isVisible else { return }
        guard !model.cards.isEmpty, let rect = currentInteractiveRect() else {
            panel.ignoresMouseEvents = true
            return
        }

        let mouseInZone = rect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == mouseInZone {
            panel.ignoresMouseEvents = !mouseInZone
        }
    }

    private func currentInteractiveRect() -> NSRect? {
        guard let screen = NSScreen.main, !model.cards.isEmpty else { return nil }

        let cardCount = CGFloat(min(model.cards.count, 6))
        let expandedRailHeight = min(
            screen.visibleFrame.height - 96,
            max(220, (cardCount * 156) + 36)
        )
        let expandedPreviewHeight = min(screen.visibleFrame.height - 92, 940)
        let listHeight = model.isExpanded
            ? (model.activePreviewID == nil ? expandedRailHeight : max(expandedRailHeight, expandedPreviewHeight))
            : collapsedHeight
        let width: CGFloat
        if model.isExpanded {
            width = model.activePreviewID == nil
                ? cardWidth + 74
                : min(screen.frame.width, 1560)
        } else {
            width = cardWidth + 82
        }

        return NSRect(
            x: screen.frame.minX,
            y: screen.visibleFrame.midY - (listHeight / 2),
            width: width,
            height: listHeight
        )
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }
}

private extension NSImage {
    func downscaled(maxDimension: CGFloat) -> NSImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }

        let scale = maxDimension / longest
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let image = NSImage(size: newSize)
        image.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1)
        image.unlockFocus()
        return image
    }
}
#endif
