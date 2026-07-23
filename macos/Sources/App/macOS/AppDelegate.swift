import AppKit
import SwiftUI
import UserNotifications
import OSLog
import Sparkle
import GhosttyKit
import Carbon

private extension NSWindow.Level {
    static let gaiCriticalDialog = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 30)
}

class AppDelegate: NSObject,
                    ObservableObject,
                    NSApplicationDelegate,
                    UNUserNotificationCenterDelegate,
                    GhosttyAppDelegate {
    // The application logger. We should probably move this at some point to a dedicated
    // class/struct but for now it lives here! 🤷‍♂️
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )

    /// Various menu items so that we can programmatically sync the keyboard shortcut with the Ghostty config
    @IBOutlet private var menuAbout: NSMenuItem?
    @IBOutlet private var menuServices: NSMenu?
    @IBOutlet private var menuCheckForUpdates: NSMenuItem?
    @IBOutlet private var menuOpenConfig: NSMenuItem?
    @IBOutlet private var menuReloadConfig: NSMenuItem?
    @IBOutlet private var menuSecureInput: NSMenuItem?
    @IBOutlet private var menuQuit: NSMenuItem?

    @IBOutlet private var menuNewWindow: NSMenuItem?
    @IBOutlet private var menuNewTab: NSMenuItem?
    @IBOutlet private var menuSplitRight: NSMenuItem?
    @IBOutlet private var menuSplitLeft: NSMenuItem?
    @IBOutlet private var menuSplitDown: NSMenuItem?
    @IBOutlet private var menuSplitUp: NSMenuItem?
    @IBOutlet private var menuClose: NSMenuItem?
    @IBOutlet private var menuCloseAllWindows: NSMenuItem?

    @IBOutlet private var menuUndo: NSMenuItem?
    @IBOutlet private var menuRedo: NSMenuItem?
    @IBOutlet private var menuCopy: NSMenuItem?
    @IBOutlet private var menuPaste: NSMenuItem?
    @IBOutlet private var menuPasteSelection: NSMenuItem?
    @IBOutlet private var menuSelectAll: NSMenuItem?
    @IBOutlet private var menuFindParent: NSMenuItem?
    @IBOutlet private var menuFind: NSMenuItem?
    @IBOutlet private var menuSelectionForFind: NSMenuItem?
    @IBOutlet private var menuScrollToSelection: NSMenuItem?
    @IBOutlet private var menuFindNext: NSMenuItem?
    @IBOutlet private var menuFindPrevious: NSMenuItem?
    @IBOutlet private var menuHideFindBar: NSMenuItem?

    @IBOutlet private var menuToggleVisibility: NSMenuItem?
    @IBOutlet private var menuToggleFullScreen: NSMenuItem?
    @IBOutlet private var menuBringAllToFront: NSMenuItem?
    @IBOutlet private var menuZoomSplit: NSMenuItem?
    @IBOutlet private var menuPreviousSplit: NSMenuItem?
    @IBOutlet private var menuNextSplit: NSMenuItem?
    @IBOutlet private var menuSelectSplitAbove: NSMenuItem?
    @IBOutlet private var menuSelectSplitBelow: NSMenuItem?
    @IBOutlet private var menuSelectSplitLeft: NSMenuItem?
    @IBOutlet private var menuSelectSplitRight: NSMenuItem?
    @IBOutlet private var menuReturnToDefaultSize: NSMenuItem?
    @IBOutlet private var menuFloatOnTop: NSMenuItem?
    @IBOutlet private var menuUseAsDefault: NSMenuItem?
    @IBOutlet private var menuSetAsDefaultTerminal: NSMenuItem?

    @IBOutlet private var menuIncreaseFontSize: NSMenuItem?
    @IBOutlet private var menuDecreaseFontSize: NSMenuItem?
    @IBOutlet private var menuResetFontSize: NSMenuItem?
    @IBOutlet private var menuChangeTitle: NSMenuItem?
    @IBOutlet private var menuReadonly: NSMenuItem?
    @IBOutlet private var menuShowGaiTerm: NSMenuItem?

    @IBOutlet private var menuEqualizeSplits: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerUp: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerDown: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerLeft: NSMenuItem?
    @IBOutlet private var menuMoveSplitDividerRight: NSMenuItem?

    /// The dock menu
    private var dockMenu: NSMenu = NSMenu()

    /// This is only true before application has become active.
    private var applicationHasBecomeActive: Bool = false

    /// This is set in applicationDidFinishLaunching with the system uptime so we can determine the
    /// seconds since the process was launched.
    private var applicationLaunchTime: TimeInterval = 0

    /// This is the current configuration from the Ghostty configuration that we need.
    private var derivedConfig: DerivedConfig = DerivedConfig()

    /// The ghostty global state. Only one per process.
    let ghostty: Ghostty.App

    /// DouDou Company uses one stable terminal surface per agent in every
    /// macOS configuration. Debug keeps a separate bundle identity so it can
    /// coexist safely with the installed release.
    lazy var gaiWorkspaceManager = GaiCompanionManager(ghostty: ghostty)
    private var gaiAgentEventSocketServer: GaiCompanionEventSocketServer?
    private var gaiAgentHotKey: EventHotKeyRef?
    private var gaiAgentHotKeyHandler: EventHandlerRef?
    private static let gaiAgentHotKeySignature: OSType = 0x4444434F // "DDCO"
    private static let gaiAgentHotKeyIdentifier: UInt32 = 1
    var gaiAgentEventSocketPath: String? {
        gaiAgentEventSocketServer?.socketPath
    }

    /// The global undo manager for app-level actions. This remains
    /// ExpiringUndoManager while the classic Ghostty window files are still
    /// compiled; they are no longer used as GaiTerm entry points.
    lazy var undoManager = ExpiringUndoManager()

    /// Manages updates
    let updateController = UpdateController()
    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

    /// The elapsed time since the process was started
    var timeSinceLaunch: TimeInterval {
        return ProcessInfo.processInfo.systemUptime - applicationLaunchTime
    }

    /// Tracks the windows that we hid for toggleVisibility.
    private(set) var hiddenState: ToggleVisibilityState?

    /// The observer for the app appearance.
    private var appearanceObserver: NSKeyValueObservation?

    /// Signals
    private var signals: [DispatchSourceSignal] = []

    private let appIconUpdater = AppIconUpdater()

    @MainActor private lazy var menuShortcutManager = Ghostty.MenuShortcutManager()

    override init() {
#if DEBUG
        ghostty = Ghostty.App(configPath: ProcessInfo.processInfo.environment["GHOSTTY_CONFIG_PATH"])
#else
        ghostty = Ghostty.App()
#endif
        super.init()

        ghostty.delegate = self
    }

    // MARK: - NSApplicationDelegate

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if
            let suite = UserDefaults.ghosttySuite,
            let clear = ProcessInfo.processInfo.environment["GHOSTTY_CLEAR_USER_DEFAULTS"],
            (clear as NSString).boolValue {
            UserDefaults.ghostty.removePersistentDomain(forName: suite)
        }
        #endif
        UserDefaults.ghostty.register(defaults: [
            // Disable the automatic full screen menu item because we handle
            // it manually.
            "NSFullScreenMenuItemEverywhere": false,

            // On macOS 26 RC1, the autofill heuristic controller causes unusable levels
            // of slowdowns and CPU usage in the terminal window under certain [unknown]
            // conditions. We don't know exactly why/how. This disables the full heuristic
            // controller.
            //
            // Practically, this means things like SMS autofill don't work, but that is
            // a desirable behavior to NOT have happen for a terminal, so this is a win.
            // Manual autofill via the `Edit => AutoFill` menu item still work as expected.
            "NSAutoFillHeuristicControllerEnabled": false,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // System settings overrides
        UserDefaults.ghostty.register(defaults: [
            // Disable this so that repeated key events make it through to our terminal views.
            "ApplePressAndHoldEnabled": false,
        ])

        // Store our start time
        applicationLaunchTime = ProcessInfo.processInfo.systemUptime

        // Check if secure input was enabled when we last quit.
        if UserDefaults.ghostty.bool(forKey: "SecureInput") != SecureInput.shared.enabled {
            toggleSecureInput(self)
        }

        // Initial config loading
        ghosttyConfigDidChange(config: ghostty.config)

        // Start the ordered local transport before creating any PTYs so every
        // hosted CLI inherits its private socket path from the first process.
        let eventServer = GaiCompanionEventSocketServer { [weak self] url in
            self?.handleGaiTermURL(url) ?? false
        }
        do {
            _ = try eventServer.start()
            gaiAgentEventSocketServer = eventServer
        } catch {
            // Provider hooks retain their authenticated LaunchServices fallback
            // if the local socket cannot be established.
            Ghostty.logger.warning(
                "ordered agent transport unavailable: \(String(describing: error), privacy: .public)")
        }

        // A provider reads its hook/plugin configuration when its process is
        // created. Finish the bounded local installation before GaiTerm can
        // create the first agent PTY; otherwise that first agent session could
        // miss every lifecycle signal until it is restarted.
        GaiAgentHookInstaller.installBeforeLaunchingCompanionSurfaces()
        gaiWorkspaceManager.start()

        // Start our update checker.
        updateController.startUpdater()
        GaiUpdateWindowController.shared.showReleaseNotesIfNeeded()

        // This registers the Services menu to exist.
        NSApp.servicesMenu = menuServices

        // Setup a local event monitor for app-level keyboard shortcuts. See
        // localEventHandler for more info why.
        _ = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown],
            handler: localEventHandler)

        // Notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewWindow(_:)),
            name: Ghostty.Notification.ghosttyNewWindow,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyNewTab(_:)),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil)

        // Configure user notifications
        let showAction = UNNotificationAction(
            identifier: Ghostty.userNotificationActionShow,
            title: "Show",
            options: [.foreground])
        let actions = [
            showAction
        ]

        let center = UNUserNotificationCenter.current()

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Ghostty.userNotificationCategory,
                actions: actions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        ])
        center.delegate = self

        // Observe our appearance so we can report the correct value to libghostty.
        self.appearanceObserver = NSApplication.shared.observe(
            \.effectiveAppearance,
             options: [.new, .initial]
        ) { _, change in
            guard let appearance = change.newValue else { return }
            guard let app = self.ghostty.app else { return }
            let scheme: ghostty_color_scheme_e
            if appearance.isDark {
                scheme = GHOSTTY_COLOR_SCHEME_DARK
            } else {
                scheme = GHOSTTY_COLOR_SCHEME_LIGHT
            }

            ghostty_app_set_color_scheme(app, scheme)
        }

        // Setup our menu
        setupMenuImages()
        registerGaiAgentHotKey()

        // Setup signal handlers
        setupSignals()

        switch Ghostty.launchSource {
        case .app:
            // Don't have to do anything.
            break

        case .zig_run, .cli:
            // Part of launch services (clicking an app, using `open`, etc.) activates
            // the application and brings it to the front. When using the CLI we don't
            // get this behavior, so we have to do it manually.

            // This never gets called until we click the dock icon. This forces it
            // activate immediately.
            applicationDidBecomeActive(.init(name: NSApplication.didBecomeActiveNotification))

            // We run in the background, this forces us to the front.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.unhide(nil)
                NSApp.arrangeInFront(nil)
            }
        }
    }

    func applicationDidHide(_ notification: Notification) {
        // Keep track of our hidden state to restore properly
        self.hiddenState = .init()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If we're back manually then clear the hidden state because macOS handles it.
        self.hiddenState = nil

        // First launch stuff
        if !applicationHasBecomeActive {
            applicationHasBecomeActive = true

            // Let's launch our first window. We only do this if we have no other windows. It
            // is possible to have other windows in a few scenarios:
            //   - if we're opening a URL since `application(_:openFile:)` is called before this.
            //   - if we're restoring from persisted state
            if derivedConfig.initialWindow {
                gaiWorkspaceManager.start()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the company window only sends it to the background. Agents
        // and their PTYs keep running until the user explicitly quits.
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = NSApplication.shared.windows
        if windows.isEmpty { return .terminateNow }

        // If we've already accepted to install an update, then we don't need to
        // confirm quit. The user is already expecting the update to happen.
        if updateController.isInstalling {
            return .terminateNow
        }

        // This probably isn't fully safe. The isEmpty check above is aspirational, it doesn't
        // quite work with SwiftUI because windows are retained on close. So instead we check
        // if there are any that are visible. I'm guessing this breaks under certain scenarios.
        //
        // NOTE(mitchellh): I don't think we need this check at all anymore. I'm keeping it
        // here because I don't want to remove it in a patch release cycle but we should
        // target removing it soon.
        if windows.allSatisfy({ !$0.isVisible }) {
            return .terminateNow
        }

        // If the user is shutting down, restarting, or logging out, we don't confirm quit.
        why: if let event = NSAppleEventManager.shared().currentAppleEvent {
            // If all GaiTerm windows are in the background (i.e. you Cmd-Q from the Cmd-Tab
            // view), then this is null. I don't know why (pun intended) but we have to
            // guard against it.
            guard let keyword = AEKeyword("why?") else { break why }

            if let why = event.attributeDescriptor(forKeyword: keyword) {
                switch why.typeCodeValue {
                case kAEShutDown, kAERestart, kAEReallyLogOut:
                    return .terminateNow

                default:
                    break
                }
            }
        }

        // If our app says we don't need to confirm, we can exit now.
        if !ghostty.needsConfirmQuit { return .terminateNow }

        return terminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGaiAgentHotKey()
        gaiAgentEventSocketServer?.stop()
        gaiAgentEventSocketServer = nil
        // We have no notifications we want to persist after death,
        // so remove them all now. In the future we may want to be
        // more selective and only remove surface-targeted notifications.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// This is called when the application is already open and someone double-clicks the icon
    /// or clicks the dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If the application isn't active yet then we don't want to process
        // this because we're not ready. This happens sometimes in Xcode runs
        // but I haven't seen it happen in releases. I'm unsure why.
        guard applicationHasBecomeActive else { return true }

        NSApp.unhide(nil)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        // DouDou Company's home is the agent library, not a classic terminal
        // window. Reopening it preserves the independent Hide Agents choice.
        gaiWorkspaceManager.reveal()
        reloadDockMenu()
        return false
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Ghostty will validate as well but we can avoid creating an entirely new
        // surface by doing our own validation here. We can also show a useful error
        // this way.

        var isDirectory = ObjCBool(true)
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory) else { return false }

        // Set to true if confirmation is required before starting up the
        // new terminal.
        var requiresConfirm: Bool = false

        // Initialize the surface config which will be used to create the tab or window for the opened file.
        var config = Ghostty.SurfaceConfiguration()

        if isDirectory.boolValue {
            // When opening a directory, check the configuration to decide
            // whether to open in a new tab or new window.
            config.workingDirectory = filename
        } else {
            // Unconditionally require confirmation in the file execution case.
            // In the future I have ideas about making this more fine-grained if
            // we can not inherit of unsandboxed state. For now, we need to confirm
            // because there is a sandbox escape possible if a sandboxed application
            // somehow is tricked into `open`-ing a non-sandboxed application.
            requiresConfirm = true

            // When opening a file, we want to execute the file. To do this, we
            // don't override the command directly, because it won't load the
            // profile/rc files for the shell, which is super important on macOS
            // due to things like Homebrew. Instead, we set the command to
            // `<filename>; exit` which is what Terminal and iTerm2 do.
            config.initialInput = "\(Ghostty.Shell.quote(filename)); exit\n"

            // For commands executed directly, we want to ensure we wait after exit
            // because in most cases scripts don't block on exit and we don't want
            // the window to just flash closed once complete.
            config.waitAfterCommand = true

            // Set the parent directory to our working directory so that relative
            // paths in scripts work.
            config.workingDirectory = (filename as NSString).deletingLastPathComponent
        }

        if requiresConfirm {
            // Confirmation required. We use an app-wide NSAlert for now. In the future we
            // may want to show this as a sheet on the focused window (especially if we're
            // opening a tab). I'm not sure.
            let alert = NSAlert()
            alert.messageText = "Allow DouDou Company to execute \"\(filename)\"?"
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break

            default:
                return false
            }
        }

        _ = gaiWorkspaceManager.openTerminal(baseConfig: config)

        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            _ = handleGaiTermURL(url)
        }
    }

    @discardableResult
    private func handleGaiTermURL(_ url: URL) -> Bool {
        if url.scheme == GaiCompanionEventEnvelope.scheme,
           url.host == GaiCompanionEventEnvelope.host {
            do {
                let envelope = try GaiCompanionEventEnvelope(url: url)
                return gaiWorkspaceManager.recordAgentEvent(
                    envelope.event,
                    token: envelope.token).shouldAcknowledge
            } catch {
                // Never log the URL because it carries the per-terminal
                // capability token.
                Ghostty.logger.warning(
                    "ignored malformed agent event: \(String(describing: error), privacy: .public)")
                return false
            }
        }

        let expectedScheme = GaiCompanionEventEnvelope.scheme
        guard url.scheme == expectedScheme, url.host == "notify" else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        let items = components.queryItems ?? []

        func value(_ name: String, maxLength: Int = 240) -> String {
            let raw = items.first(where: { $0.name == name })?.value ?? ""
            return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        }

        guard let surfaceID = UUID(uuidString: value("surface", maxLength: 64)) else { return true }
        _ = gaiWorkspaceManager.recordExternalNotification(
            surfaceID: surfaceID,
            title: value("title", maxLength: 80),
            body: value("body", maxLength: 240))
        return true
    }

    /// Registers a real system-wide shortcut. Unlike an AppKit key equivalent,
    /// this keeps working while DouDou Company is in the background.
    private func registerGaiAgentHotKey() {
        guard gaiAgentHotKey == nil, gaiAgentHotKeyHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID)
                guard parameterStatus == noErr,
                      hotKeyID.signature == AppDelegate.gaiAgentHotKeySignature,
                      hotKeyID.id == AppDelegate.gaiAgentHotKeyIdentifier
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let appDelegate = Unmanaged<AppDelegate>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    appDelegate.toggleVisibility(appDelegate)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &gaiAgentHotKeyHandler)
        guard handlerStatus == noErr else {
            Ghostty.logger.warning(
                "could not install DouDou Company global hot-key handler: \(handlerStatus)")
            gaiAgentHotKeyHandler = nil
            return
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.gaiAgentHotKeySignature,
            id: Self.gaiAgentHotKeyIdentifier)
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &gaiAgentHotKey)
        guard registrationStatus == noErr else {
            Ghostty.logger.warning(
                "could not register DouDou Company global hot key: \(registrationStatus)")
            if let handler = gaiAgentHotKeyHandler {
                RemoveEventHandler(handler)
                gaiAgentHotKeyHandler = nil
            }
            gaiAgentHotKey = nil
            return
        }
    }

    private func unregisterGaiAgentHotKey() {
        if let hotKey = gaiAgentHotKey {
            UnregisterEventHotKey(hotKey)
            gaiAgentHotKey = nil
        }
        if let handler = gaiAgentHotKeyHandler {
            RemoveEventHandler(handler)
            gaiAgentHotKeyHandler = nil
        }
    }

    /// Setup signal handlers
    private func setupSignals() {
        // Register a signal handler for config reloading. It appears that all
        // of this is required. I've commented each line because its a bit unclear.
        // Warning: signal handlers don't work when run via Xcode. They have to be
        // run on a real app bundle.

        // We need to ignore signals we register with makeSignalSource or they
        // don't seem to handle.
        signal(SIGUSR2, SIG_IGN)

        // Make the signal source and register our event handle. We keep a weak
        // ref to ourself so we don't create a retain cycle.
        let sigusr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        sigusr2.setEventHandler { [weak self] in
            guard let self else { return }
            Ghostty.logger.info("reloading configuration in response to SIGUSR2")
            self.ghostty.reloadConfig()
        }

        // The signal source starts unactivated, so we have to resume it once
        // we setup the event handler.
        sigusr2.resume()

        // We need to keep a strong reference to it so it isn't disabled.
        signals.append(sigusr2)
    }

    // MARK: Notifications and Events

    /// This handles events from the NSEvent.addLocalEventMonitor. We use this so we can get
    /// events without any terminal windows open.
    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        return switch event.type {
        case .keyDown:
            localEventKeyDown(event)

        default:
            event
        }
    }

    private func localEventKeyDown(_ event: NSEvent) -> NSEvent? {
        // If the tab overview is visible and escape is pressed, close it.
        // This can't POSSIBLY be right and is probably a FirstResponder problem
        // that we should handle elsewhere in our program. But this works and it
        // is guarded by the tab overview currently showing.
        if event.keyCode == 0x35, // Escape key
           let window = NSApp.keyWindow,
           let tabGroup = window.tabGroup,
           tabGroup.isOverviewVisible {
            window.toggleTabOverview(nil)
            return nil
        }

        // If we have a main window then we don't process any of the keys
        // because we let it capture and propagate.
        guard NSApp.mainWindow == nil else { return event }

        // If this event as-is would result in a key binding then we send it.
        if let app = ghostty.app, let config = ghostty.config.config {
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            let match = (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                if !ghostty_config_key_is_binding(config, ghosttyEvent) {
                    return false
                }

                return ghostty_app_key(app, ghosttyEvent)
            }

            // If the key was handled by Ghostty we stop the event chain. If
            // the key wasn't handled then we let it fall through and continue
            // processing. This is important because some bindings may have no
            // affect at this scope.
            if match {
                return nil
            }
        }

        // If this event would be handled by our menu then we do nothing.
        if let mainMenu = NSApp.mainMenu,
           mainMenu.performKeyEquivalent(with: event) {
            return nil
        }

        // If we reach this point then we try to process the key event
        // through the Ghostty key mechanism.

        // Ghostty must be loaded
        guard let ghostty = self.ghostty.app else { return event }

        // Build our event input and call ghostty
        if ghostty_app_key(ghostty, event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)) {
            // The key was used so we want to stop it from going to our Mac app
            Ghostty.logger.debug("local key event handled event=\(event, privacy: .public)")
            return nil
        }

        return event
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        syncFloatOnTopMenu(notification.object as? NSWindow)
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a surface one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        ghosttyConfigDidChange(config: config)
    }

    @objc private func ghosttyBellDidRing(_ notification: Notification) {
        if ghostty.config.bellFeatures.contains(.system) {
            NSSound.beep()
        }

        if ghostty.config.bellFeatures.contains(.audio) {
            if let configPath = ghostty.config.bellAudioPath,
               let sound = NSSound(contentsOfFile: configPath.path, byReference: false) {
                sound.volume = ghostty.config.bellAudioVolume
                sound.play()
            }
        }

        if ghostty.config.bellFeatures.contains(.attention) {
            // Bounce the dock icon if we're not focused.
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func requestBadgeAuthorizationAndSet(_ center: UNUserNotificationCenter) {
        let options: UNAuthorizationOptions = [.alert, .badge, .sound]
        center.requestAuthorization(options: options) { granted, error in
            if let error = error {
                Self.logger.warning("Error requesting badge authorization: \(error, privacy: .public)")
                return
            }

            // Permission granted, set the badge
            if granted {
                DispatchQueue.main.async {
                    self.setDockBadge()
                }
            }
        }
    }

    private func syncDockBadge() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                // If we're authorized and allow badges, then set the badge.
                if settings.badgeSetting == .enabled {
                    DispatchQueue.main.async {
                        self.setDockBadge()
                    }
                } else if settings.badgeSetting == .notSupported {
                    // If badge setting is not supported, we may be in a sandbox that doesn't allow it.
                    // We can still attempt to set the badge and hope for the best, but we should also
                    // request authorization just in case it is a permissions issue.
                    self.requestBadgeAuthorizationAndSet(center)
                }

            case .notDetermined:
                // Not determined yet, request authorization for badge
                self.requestBadgeAuthorizationAndSet(center)

            case .denied, .provisional, .ephemeral:
                // In these known non-authorized states, do not attempt to set the badge.
                break

            @unknown default:
                // Handle future unknown states by doing nothing.
                break
            }
        }
    }

    @objc private func ghosttyNewWindow(_ notification: Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        _ = gaiWorkspaceManager.openTerminal(baseConfig: config)
    }

    @objc private func ghosttyNewTab(_ notification: Notification) {
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration
        _ = gaiWorkspaceManager.openTerminal(baseConfig: config)
    }

    private func setDockBadge() {
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
    }

    private func ghosttyConfigDidChange(config: Ghostty.Config) {
        // Update the config we need to store
        self.derivedConfig = DerivedConfig(config)

        // Depending on the "window-save-state" setting we have to set the NSQuitAlwaysKeepsWindows
        // configuration. This is the only way to carefully control whether macOS invokes the
        // state restoration system.
        switch config.windowSaveState {
        case "never": UserDefaults.ghostty.setValue(false, forKey: "NSQuitAlwaysKeepsWindows")
        case "always": UserDefaults.ghostty.setValue(true, forKey: "NSQuitAlwaysKeepsWindows")
        case "default": fallthrough
        default: UserDefaults.ghostty.removeObject(forKey: "NSQuitAlwaysKeepsWindows")
        }

        // Sync our auto-update settings. If SUEnableAutomaticChecks (in our Info.plist) is
        // explicitly false (NO), auto-updates are disabled. Otherwise, we use the behavior
        // defined by our "auto-update" configuration (if set) or fall back to Sparkle
        // user-based defaults.
        #if DEBUG
        // Debug and Release intentionally coexist. Never let the development
        // bundle consume or install the public Sparkle appcast.
        updateController.updater.automaticallyChecksForUpdates = false
        updateController.updater.automaticallyDownloadsUpdates = false
        #else
        if Bundle.main.infoDictionary?["SUEnableAutomaticChecks"] as? Bool == false {
            updateController.updater.automaticallyChecksForUpdates = false
            updateController.updater.automaticallyDownloadsUpdates = false
        } else if let autoUpdate = config.autoUpdate {
            updateController.updater.automaticallyChecksForUpdates =
                autoUpdate == .check || autoUpdate == .download
            updateController.updater.automaticallyDownloadsUpdates =
                autoUpdate == .download
            /*
             To test `auto-update` easily, uncomment the line below and
             delete `SUEnableAutomaticChecks` in Ghostty-Info.plist.

             Note: When `auto-update = download`, you may need to
             `Clean Build Folder` if a background install has already begun.
             */
            // updateController.updater.checkForUpdatesInBackground()
        }
        #endif

        // Config could change keybindings, so update everything that depends on that
        DispatchQueue.main.async {
            self.syncMenuShortcuts(config)
        }
        // Update our badge since config can change what we show.
        syncDockBadge()

        // Config could change window appearance. We wrap this in an async queue because when
        // this is called as part of application launch it can deadlock with an internal
        // AppKit mutex on the appearance.
        DispatchQueue.main.async { self.syncAppearance(config: config) }

        // Decide whether to hide/unhide app from dock and app switcher
        switch config.macosHidden {
        case .never:
            NSApp.setActivationPolicy(.regular)

        case .always:
            NSApp.setActivationPolicy(.accessory)
        }

        // If we have configuration errors, we need to show them.
        let c = ConfigurationErrorsController.sharedInstance
        c.errors = config.errors
        if c.errors.count > 0 {
            if c.window == nil || !c.window!.isVisible {
                c.showWindow(self)
            }
        }

        updateAppIcon(from: config)
    }

    /// Sync the appearance of our app with the theme specified in the config.
    private func syncAppearance(config: Ghostty.Config) {
        NSApplication.shared.appearance = .init(ghosttyConfig: config)
    }

    private func updateAppIcon(from config: Ghostty.Config) {
        // GaiTerm ships its own bundle icon (AppIcon asset). Only override at
        // runtime if the user explicitly picked a non-default icon — otherwise
        // leave the bundle icon alone (calling NSWorkspace.setIcon(nil,…) here
        // wiped the GaiTerm icon off the Dock).
        guard let icon = AppIcon(config: config) else { return }
        Task.detached {
            await self.appIconUpdater.update(icon: icon)
        }
    }

    // MARK: - Restorable State

    /// We support NSSecureCoding for restorable state. Required as of macOS Sonoma (14) but a good idea anyways.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
        // GaiTerm persists workspaces via GaiWorkspaceStore/UserDefaults, not
        // AppKit's classic Ghostty window restoration.
    }

    func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
        Self.logger.debug("GaiTerm ignores classic Ghostty window restoration")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive: UNNotificationResponse,
        withCompletionHandler: () -> Void
    ) {
        ghostty.handleUserNotification(response: didReceive)
        withCompletionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent: UNNotification,
        withCompletionHandler: (UNNotificationPresentationOptions) -> Void
    ) {
        let shouldPresent = ghostty.shouldPresentNotification(notification: willPresent)
        let options: UNNotificationPresentationOptions = shouldPresent ? [.banner, .sound] : []
        withCompletionHandler(options)
    }

    // MARK: - GhosttyAppDelegate

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        gaiWorkspaceManager.surface(for: uuid)
    }

    // MARK: - Global State

    func setSecureInput(_ mode: Ghostty.SetSecureInput) {
        let input = SecureInput.shared
        switch mode {
        case .on:
            input.global = true

        case .off:
            input.global = false

        case .toggle:
            input.global.toggle()
        }
        self.menuSecureInput?.state = if input.global { .on } else { .off }
        UserDefaults.ghostty.set(input.global, forKey: "SecureInput")
    }

    // MARK: - IB Actions

    @IBAction func openGaiSettings(_ sender: Any?) {
        GaiSettingsWindowController.shared.show()
    }

    @IBAction func openConfig(_ sender: Any?) {
        ghostty.openConfig()
    }

    @IBAction func reloadConfig(_ sender: Any?) {
        ghostty.reloadConfig()
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates()
        // UpdateSimulator.happyPath.simulate(with: updateViewModel)
    }

    @IBAction func newWindow(_ sender: Any?) {
        _ = gaiWorkspaceManager.openTerminal()
    }

    @IBAction func newTab(_ sender: Any?) {
        _ = gaiWorkspaceManager.openTerminal()
    }

    @IBAction func closeTerminal(_ sender: Any?) {
        guard let surface = gaiWorkspaceManager.focusedSurface() else {
            NSApp.keyWindow?.performClose(sender)
            return
        }
        gaiWorkspaceManager.closeSurface(surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        closeTerminal(sender)
    }

    @IBAction func closeWindow(_ sender: Any?) {
        closeTerminal(sender)
    }

    @IBAction func closeAllWindows(_ sender: Any?) {
        gaiWorkspaceManager.closeAllSurfaces()
    }

    @IBAction func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "DouDou Company",
        ])
    }

    @IBAction func showHelp(_ sender: Any) {
        guard let url = URL(string: "https://github.com/sipiyou39/GaiTerm") else { return }
        NSWorkspace.shared.open(url)
    }

    @IBAction func toggleSecureInput(_ sender: Any) {
        setSecureInput(.toggle)
    }

    @IBAction func showGaiTerm(_ sender: Any) {
        gaiWorkspaceManager.reveal()
        reloadDockMenu()
    }

    /// Toggles the lightweight agent layer without touching PTYs or the
    /// library window.
    @IBAction func toggleVisibility(_ sender: Any) {
        gaiWorkspaceManager.toggleAgentVisibility()
        reloadDockMenu()
    }

    @IBAction func bringAllToFront(_ sender: Any) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        NSApplication.shared.arrangeInFront(sender)
    }

    @IBAction func undo(_ sender: Any?) {
        undoManager.undo()
    }

    @IBAction func redo(_ sender: Any?) {
        undoManager.redo()
    }

    private struct DerivedConfig {
        let initialWindow: Bool
        let shouldQuitAfterLastWindowClosed: Bool

        init() {
            self.initialWindow = true
            self.shouldQuitAfterLastWindowClosed = false
        }

        init(_ config: Ghostty.Config) {
            self.initialWindow = config.initialWindow
            self.shouldQuitAfterLastWindowClosed = config.shouldQuitAfterLastWindowClosed
        }
    }

    struct ToggleVisibilityState {
        let hiddenWindows: [Weak<NSWindow>]
        let keyWindow: Weak<NSWindow>?

        fileprivate init() {
            // We need to know the key window so that we can bring focus back to the
            // right window if it was hidden.
            self.keyWindow = if let keyWindow = NSApp.keyWindow {
                .init(keyWindow)
            } else {
                nil
            }

            // We need to keep track of the windows that were visible because we only
            // want to bring back these windows if we remove the toggle.
            //
            // We also ignore fullscreen windows because they don't hide anyways.
            var visibleWindows = [Weak<NSWindow>]()
            NSApp.windows.filter {
                $0.isVisible &&
                !$0.styleMask.contains(.fullScreen)
            }.forEach { window in
                // We only keep track of selectedWindow if it's in a tabGroup,
                // so we can keep its selection state when restoring
                let windowToHide = window.tabGroup?.selectedWindow ?? window
                if !visibleWindows.contains(where: { $0.value === windowToHide }) {
                    visibleWindows.append(Weak(windowToHide))
                }
            }
            self.hiddenWindows = visibleWindows
        }

        func restore() {
            hiddenWindows.forEach { $0.value?.orderFrontRegardless() }
            keyWindow?.value?.makeKey()
        }
    }
}

// MARK: Menu

extension AppDelegate {
    /// This is called for the dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return dockMenu
    }

    private func reloadDockMenu() {
        let reveal = NSMenuItem(
            title: "Open DouDou Company",
            action: #selector(showGaiTerm),
            keyEquivalent: "")
        let toggleAgents = NSMenuItem(
            title: gaiWorkspaceManager.agentWindowsAreVisible ? "Hide Agents" : "Show Agents",
            action: #selector(toggleVisibility),
            keyEquivalent: "")
        let newTerminal = NSMenuItem(title: "Hire Agent", action: #selector(newWindow), keyEquivalent: "")

        dockMenu.removeAllItems()
        dockMenu.addItem(reveal)
        dockMenu.addItem(toggleAgents)
        dockMenu.addItem(newTerminal)
    }

    /// Setup all the images for our menu items.
    private func setupMenuImages() {
        // Note: This COULD Be done all in the xib file, but I find it easier to
        // modify this stuff as code.
        self.menuAbout?.setImageIfDesired(systemSymbolName: "info.circle")
        self.menuCheckForUpdates?.setImageIfDesired(systemSymbolName: "square.and.arrow.down")
        self.menuOpenConfig?.setImageIfDesired(systemSymbolName: "gear")
        self.menuReloadConfig?.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90")
        self.menuSecureInput?.setImageIfDesired(systemSymbolName: "lock.display")
        self.menuNewWindow?.setImageIfDesired(systemSymbolName: "macwindow.badge.plus")
        self.menuNewTab?.setImageIfDesired(systemSymbolName: "macwindow")
        self.menuSplitRight?.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
        self.menuSplitLeft?.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
        self.menuSplitUp?.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")
        self.menuSplitDown?.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
        self.menuClose?.setImageIfDesired(systemSymbolName: "xmark")
        self.menuPasteSelection?.setImageIfDesired(systemSymbolName: "doc.on.clipboard.fill")
        self.menuIncreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.larger")
        self.menuResetFontSize?.setImageIfDesired(systemSymbolName: "textformat.size")
        self.menuDecreaseFontSize?.setImageIfDesired(systemSymbolName: "textformat.size.smaller")
        self.menuShowGaiTerm?.setImageIfDesired(systemSymbolName: "apple.terminal")
        self.menuReadonly?.setImageIfDesired(systemSymbolName: "eye.fill")
        self.menuSetAsDefaultTerminal?.setImageIfDesired(systemSymbolName: "star.fill")
        self.menuToggleFullScreen?.setImageIfDesired(systemSymbolName: "square.arrowtriangle.4.outward")
        self.menuToggleVisibility?.setImageIfDesired(systemSymbolName: "eye")
        self.menuZoomSplit?.setImageIfDesired(systemSymbolName: "arrow.up.left.and.arrow.down.right")
        self.menuPreviousSplit?.setImageIfDesired(systemSymbolName: "chevron.backward.2")
        self.menuNextSplit?.setImageIfDesired(systemSymbolName: "chevron.forward.2")
        self.menuEqualizeSplits?.setImageIfDesired(systemSymbolName: "inset.filled.topleft.topright.bottomleft.bottomright.rectangle")
        self.menuSelectSplitLeft?.setImageIfDesired(systemSymbolName: "arrow.left")
        self.menuSelectSplitRight?.setImageIfDesired(systemSymbolName: "arrow.right")
        self.menuSelectSplitAbove?.setImageIfDesired(systemSymbolName: "arrow.up")
        self.menuSelectSplitBelow?.setImageIfDesired(systemSymbolName: "arrow.down")
        self.menuMoveSplitDividerUp?.setImageIfDesired(systemSymbolName: "arrow.up.to.line")
        self.menuMoveSplitDividerDown?.setImageIfDesired(systemSymbolName: "arrow.down.to.line")
        self.menuMoveSplitDividerLeft?.setImageIfDesired(systemSymbolName: "arrow.left.to.line")
        self.menuMoveSplitDividerRight?.setImageIfDesired(systemSymbolName: "arrow.right.to.line")
        self.menuFloatOnTop?.setImageIfDesired(systemSymbolName: "square.filled.on.square")
        self.menuFindParent?.setImageIfDesired(systemSymbolName: "text.page.badge.magnifyingglass")

        // The agent UI has no split tree; each terminal owns one stable agent.
        // Keep the legacy outlets connected while removing those commands from
        // the public DouDou Company menus.
        menuAbout?.title = "About DouDou Company"
        menuQuit?.title = "Quit DouDou Company"
        menuNewWindow?.title = "Hire Agent"
        menuNewTab?.isHidden = true
        menuCloseAllWindows?.title = "Remove All Agents"
        menuShowGaiTerm?.title = "Open DouDou Company"
        configureGaiAgentVisibilityMenuItem()
        [
            menuSplitRight, menuSplitLeft, menuSplitUp, menuSplitDown,
            menuZoomSplit, menuPreviousSplit, menuNextSplit,
            menuSelectSplitLeft, menuSelectSplitRight,
            menuSelectSplitAbove, menuSelectSplitBelow,
            menuMoveSplitDividerUp, menuMoveSplitDividerDown,
            menuMoveSplitDividerLeft, menuMoveSplitDividerRight,
            menuEqualizeSplits, menuChangeTitle, menuFloatOnTop,
        ].forEach { $0?.isHidden = true }
    }

    /// Sync all of our menu item keyboard shortcuts with the Ghostty configuration.
    @MainActor private func syncMenuShortcuts(_ config: Ghostty.Config) {
        guard ghostty.readiness == .ready else { return }

        menuShortcutManager.reset()

        syncMenuShortcut(config, action: "check_for_updates", menuItem: self.menuCheckForUpdates)
        syncMenuShortcut(config, action: "open_config", menuItem: self.menuOpenConfig)
        syncMenuShortcut(config, action: "reload_config", menuItem: self.menuReloadConfig)
        syncMenuShortcut(config, action: "quit", menuItem: self.menuQuit)

        syncMenuShortcut(config, action: "new_window", menuItem: self.menuNewWindow)
        syncMenuShortcut(config, action: "new_tab", menuItem: self.menuNewTab)
        syncMenuShortcut(config, action: "close_surface", menuItem: self.menuClose)
        syncMenuShortcut(config, action: "close_all_windows", menuItem: self.menuCloseAllWindows)
        syncMenuShortcut(config, action: "new_split:right", menuItem: self.menuSplitRight)
        syncMenuShortcut(config, action: "new_split:left", menuItem: self.menuSplitLeft)
        syncMenuShortcut(config, action: "new_split:down", menuItem: self.menuSplitDown)
        syncMenuShortcut(config, action: "new_split:up", menuItem: self.menuSplitUp)

        syncMenuShortcut(config, action: "undo", menuItem: self.menuUndo)
        syncMenuShortcut(config, action: "redo", menuItem: self.menuRedo)
        syncMenuShortcut(config, action: "copy_to_clipboard", menuItem: self.menuCopy)
        syncMenuShortcut(config, action: "paste_from_clipboard", menuItem: self.menuPaste)
        syncMenuShortcut(config, action: "paste_from_selection", menuItem: self.menuPasteSelection)
        syncMenuShortcut(config, action: "select_all", menuItem: self.menuSelectAll)
        syncMenuShortcut(config, action: "start_search", menuItem: self.menuFind)
        syncMenuShortcut(config, action: "end_search", menuItem: self.menuHideFindBar)
        syncMenuShortcut(config, action: "search_selection", menuItem: self.menuSelectionForFind)
        syncMenuShortcut(config, action: "scroll_to_selection", menuItem: self.menuScrollToSelection)
        syncMenuShortcut(config, action: "navigate_search:next", menuItem: self.menuFindNext)
        syncMenuShortcut(config, action: "navigate_search:previous", menuItem: self.menuFindPrevious)

        syncMenuShortcut(config, action: "toggle_split_zoom", menuItem: self.menuZoomSplit)
        syncMenuShortcut(config, action: "goto_split:previous", menuItem: self.menuPreviousSplit)
        syncMenuShortcut(config, action: "goto_split:next", menuItem: self.menuNextSplit)
        syncMenuShortcut(config, action: "goto_split:up", menuItem: self.menuSelectSplitAbove)
        syncMenuShortcut(config, action: "goto_split:down", menuItem: self.menuSelectSplitBelow)
        syncMenuShortcut(config, action: "goto_split:left", menuItem: self.menuSelectSplitLeft)
        syncMenuShortcut(config, action: "goto_split:right", menuItem: self.menuSelectSplitRight)
        syncMenuShortcut(config, action: "resize_split:up,10", menuItem: self.menuMoveSplitDividerUp)
        syncMenuShortcut(config, action: "resize_split:down,10", menuItem: self.menuMoveSplitDividerDown)
        syncMenuShortcut(config, action: "resize_split:right,10", menuItem: self.menuMoveSplitDividerRight)
        syncMenuShortcut(config, action: "resize_split:left,10", menuItem: self.menuMoveSplitDividerLeft)
        syncMenuShortcut(config, action: "equalize_splits", menuItem: self.menuEqualizeSplits)
        syncMenuShortcut(config, action: "reset_window_size", menuItem: self.menuReturnToDefaultSize)

        syncMenuShortcut(config, action: "increase_font_size:1", menuItem: self.menuIncreaseFontSize)
        syncMenuShortcut(config, action: "decrease_font_size:1", menuItem: self.menuDecreaseFontSize)
        syncMenuShortcut(config, action: "reset_font_size", menuItem: self.menuResetFontSize)
        syncMenuShortcut(config, action: "prompt_surface_title", menuItem: self.menuChangeTitle)
        syncMenuShortcut(config, action: "toggle_quick_terminal", menuItem: self.menuShowGaiTerm)
        configureGaiAgentVisibilityMenuItem()
        syncMenuShortcut(config, action: "toggle_window_float_on_top", menuItem: self.menuFloatOnTop)

        syncMenuShortcut(config, action: "toggle_secure_input", menuItem: self.menuSecureInput)

        // This menu item is NOT synced with the configuration because it disables macOS
        // global fullscreen keyboard shortcut. The shortcut in the Ghostty config will continue
        // to work but it won't be reflected in the menu item.
        //
        // syncMenuShortcut(config, action: "toggle_fullscreen", menuItem: self.menuToggleFullScreen)

        // Dock menu
        reloadDockMenu()
    }

    @MainActor private func syncMenuShortcut(_ config: Ghostty.Config, action: String, menuItem: NSMenuItem?) {
        menuShortcutManager.syncMenuShortcut(config, action: action, menuItem: menuItem)
    }

    private func configureGaiAgentVisibilityMenuItem() {
        menuToggleVisibility?.title =
            gaiWorkspaceManager.agentWindowsAreVisible ? "Hide Agents" : "Show Agents"
        menuToggleVisibility?.keyEquivalent = "d"
        menuToggleVisibility?.keyEquivalentModifierMask = [.command, .option, .control]
    }

    @MainActor func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool {
        menuShortcutManager.performGhosttyBindingMenuKeyEquivalent(with: event)
    }
}

// MARK: Floating Windows

extension AppDelegate {
    func syncFloatOnTopMenu(_ window: NSWindow?) {
        guard let window = window ?? NSApp.keyWindow else { return }
        self.menuFloatOnTop?.state = window.level == .floating ? .on : .off
    }

    @IBAction func floatOnTop(_ menuItem: NSMenuItem) {
        if let identifier = NSApp.keyWindow?.identifier?.rawValue,
           identifier.hasPrefix("gai.companion.") {
            menuItem.state = .off
            return
        }
        menuItem.state = menuItem.state == .on ? .off : .on
        guard let window = NSApp.keyWindow else { return }
        window.level = menuItem.state == .on ? .floating : .normal
    }

    @IBAction func useAsDefault(_ sender: NSMenuItem) {
        // GaiTerm's panels own their levels directly; there is no classic
        // terminal window default level to persist.
    }

    @IBAction func setAsDefaultTerminal(_ sender: NSMenuItem) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .unixExecutable) { error in
            guard let error else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Failed to Set Default Terminal"
                alert.informativeText = """
                DouDou Company could not be set as the default terminal application.

                Error: \(error.localizedDescription)
                """
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

// MARK: NSMenuItemValidation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleVisibility(_:)):
            item.title =
                gaiWorkspaceManager.agentWindowsAreVisible ? "Hide Agents" : "Show Agents"
            return true

        case #selector(setAsDefaultTerminal(_:)):
            return NSWorkspace.shared.defaultTerminal != Bundle.main.bundleURL

        case #selector(floatOnTop(_:)),
            #selector(useAsDefault(_:)):
            return NSApp.keyWindow != nil

        case #selector(undo(_:)):
            if undoManager.canUndo {
                item.title = "Undo \(undoManager.undoActionName)"
            } else {
                item.title = "Undo"
            }
            return undoManager.canUndo

        case #selector(redo(_:)):
            if undoManager.canRedo {
                item.title = "Redo \(undoManager.redoActionName)"
            } else {
                item.title = "Redo"
            }
            return undoManager.canRedo

        default:
            return true
        }
    }
}

// MARK: - Termination Flow

extension AppDelegate {
    func terminate() -> NSApplication.TerminateReply {
        guard ghostty.needsConfirmQuit else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit DouDou Company?"
        alert.informativeText = "At least one terminal process is still running. If you quit, those processes will be terminated."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let restorePanels = GaiFloatingPanels.lower()
        defer { restorePanels() }

        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .gaiCriticalDialog
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
