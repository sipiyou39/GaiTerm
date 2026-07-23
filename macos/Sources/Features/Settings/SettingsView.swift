import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// UserDefaults keys for GaiTerm's GUI settings. Shared between the settings UI
/// and the features that consume them.
enum GaiPreferenceKey {
    /// Tint the workspaces drawer's glass with the selected workspace's accent.
    static let tintGlassWithWorkspaceAccent = "GaiTintGlassWithWorkspaceAccent"
    /// Code editor font size (points).
    static let editorFontSize = "GaiEditorFontSize"
    /// Show line numbers in the code editor.
    static let editorShowLineNumbers = "GaiEditorShowLineNumbers"
    /// Soft-wrap long lines in the code editor.
    static let editorWrapLines = "GaiEditorWrapLines"
    /// Restore saved workspaces on launch (vs. start empty).
    static let restoreWorkspaces = "GaiRestoreWorkspaces"
    /// Persisted drawer card width.
    static let drawerCardWidth = "GaiDrawerCardWidth"
    /// Persisted stage card width.
    static let stageCardWidth = "GaiStageCardWidth"
    /// Whether drawer/stage widths move as one linked block.
    static let linkPanelWidths = "GaiLinkPanelWidths"
    /// Show macOS banners for CLI notifications.
    static let agentDesktopNotifications = "GaiAgentDesktopNotifications"
    /// Play an app sound when a CLI notification arrives.
    static let agentNotificationSoundEnabled = "GaiAgentNotificationSoundEnabled"
    /// Selected bundled notification sound identifier.
    static let agentNotificationSoundName = "GaiAgentNotificationSoundName"
    /// Selected notification sound volume, 0...1.
    static let agentNotificationSoundVolume = "GaiAgentNotificationSoundVolume"
}

/// Settings design tokens (dark, flat — matches the drawer/stage).
private enum S {
    static let bg = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let sidebar = Color(red: 0.085, green: 0.085, blue: 0.095)
    static let card = Color.white.opacity(0.045)
    static let accent = Color(red: 0.42, green: 0.64, blue: 0.96)
}

private extension NSWindow.Level {
    static let gaiSettings = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
}

// MARK: - Window

/// Presents the settings window (App menu → Settings…). One window for the
/// app's lifetime.
final class GaiSettingsWindowController {
    static let shared = GaiSettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "DouDou Company Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(S.bg)
            window.appearance = NSAppearance(named: .darkAqua)
            window.level = .gaiSettings
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.level = .gaiSettings
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case notifications = "Notifications"
    case editor = "Editor"
    case permissions = "Permissions"
    case updates = "Updates"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .notifications: return "bell.badge"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .permissions: return "lock.shield"
        case .updates: return "arrow.down.circle"
        }
    }
}

struct SettingsView: View {
    @State private var category: SettingsCategory = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            ScrollView {
                detail
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 500)
        .background(S.bg)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            brand
                .padding(.horizontal, 14)
                .padding(.top, 30)
                .padding(.bottom, 16)
            ForEach(SettingsCategory.allCases) { item in
                sidebarItem(item)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(S.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image("AppIconImage")
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("DouDou Company")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(appVersion)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func sidebarItem(_ item: SettingsCategory) -> some View {
        let active = category == item
        return Button { category = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(item.rawValue)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? S.accent.opacity(0.22) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var detail: some View {
        switch category {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .notifications: NotificationsSettings()
        case .editor: EditorSettings()
        case .permissions: PermissionsSettings()
        case .updates: UpdatesSettings()
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(v)"
    }
}

// MARK: - Reusable pieces

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.4))
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(S.card))
        }
        .padding(.bottom, 20)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var first: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(Color.white.opacity(0.06)) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    var first: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, first: first) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(S.accent)
        }
    }
}

// MARK: - Notification sounds

struct GaiNotificationSoundChoice: Identifiable, Equatable {
    let id: String
    let displayName: String
    let fileName: String
}

enum GaiNotificationSoundLibrary {
    static let defaultID = "gaiterm-notify-01"
    static let defaultVolume = 0.72

    static let sounds: [GaiNotificationSoundChoice] = [
        .init(id: "gaiterm-notify-01", displayName: "Signal 1", fileName: "gaiterm-notify-01"),
        .init(id: "gaiterm-notify-02", displayName: "Signal 2", fileName: "gaiterm-notify-02"),
        .init(id: "gaiterm-notify-03", displayName: "Signal 3", fileName: "gaiterm-notify-03"),
        .init(id: "gaiterm-notify-04", displayName: "Signal 4", fileName: "gaiterm-notify-04"),
        .init(id: "gaiterm-notify-05", displayName: "Signal 5", fileName: "gaiterm-notify-05"),
        .init(id: "gaiterm-notify-06", displayName: "Signal 6", fileName: "gaiterm-notify-06"),
        .init(id: "gaiterm-notify-07", displayName: "Signal 7", fileName: "gaiterm-notify-07"),
        .init(id: "gaiterm-notify-08", displayName: "Signal 8", fileName: "gaiterm-notify-08"),
        .init(id: "gaiterm-notify-09", displayName: "Signal 9", fileName: "gaiterm-notify-09"),
    ]

    static func sound(for id: String) -> GaiNotificationSoundChoice {
        sounds.first { $0.id == id } ?? sounds[0]
    }

    static func soundURL(for id: String) -> URL? {
        let choice = sound(for: id)
        return Bundle.main.url(
            forResource: choice.fileName,
            withExtension: "caf",
            subdirectory: "Sounds")
    }

    static func desktopNotificationsEnabled() -> Bool {
        boolValue(for: GaiPreferenceKey.agentDesktopNotifications, defaultValue: true)
    }

    static func soundEnabled() -> Bool {
        boolValue(for: GaiPreferenceKey.agentNotificationSoundEnabled, defaultValue: true)
    }

    static func selectedSoundID() -> String {
        let raw = UserDefaults.standard.string(forKey: GaiPreferenceKey.agentNotificationSoundName)
        guard let raw, sounds.contains(where: { $0.id == raw }) else { return defaultID }
        return raw
    }

    static func selectedVolume() -> Double {
        guard let number = UserDefaults.standard.object(
            forKey: GaiPreferenceKey.agentNotificationSoundVolume) as? NSNumber
        else { return defaultVolume }
        return min(1, max(0, number.doubleValue))
    }

    private static func boolValue(for key: String, defaultValue: Bool) -> Bool {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else {
            return defaultValue
        }
        return number.boolValue
    }
}

final class GaiNotificationSoundPlayer: NSObject, NSSoundDelegate {
    static let shared = GaiNotificationSoundPlayer()

    private var activeSounds: [NSSound] = []
    private let maxConcurrentSounds = 4

    func playSelectedNotificationSound() {
        guard GaiNotificationSoundLibrary.soundEnabled() else { return }
        play(
            id: GaiNotificationSoundLibrary.selectedSoundID(),
            volume: GaiNotificationSoundLibrary.selectedVolume())
    }

    func preview(id: String, volume: Double) {
        play(id: id, volume: volume)
    }

    private func play(id: String, volume: Double) {
        DispatchQueue.main.async {
            guard let url = GaiNotificationSoundLibrary.soundURL(for: id),
                  let sound = NSSound(contentsOf: url, byReference: false)
            else { return }

            while self.activeSounds.count >= self.maxConcurrentSounds {
                self.activeSounds.removeFirst().stop()
            }
            sound.volume = Float(min(1, max(0, volume)))
            sound.delegate = self
            self.activeSounds.append(sound)
            if !sound.play() {
                self.activeSounds.removeAll { $0 === sound }
                NSSound.beep()
            }
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        activeSounds.removeAll { $0 === sound }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Startup") {
                SettingsToggle(
                    title: "Launch DouDou Company at login",
                    subtitle: "Open DouDou Company automatically when you log in.",
                    first: true,
                    isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            }
        }
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
        } catch {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(GaiPreferenceKey.tintGlassWithWorkspaceAccent) private var tintGlass = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Panels") {
                SettingsToggle(
                    title: "Tint panels with workspace color",
                    subtitle: "The pull tab, drawer, stage and pane headers take on a dark tint of the workspace's accent color. Off keeps them neutral gray.",
                    first: true,
                    isOn: $tintGlass)
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsSettings: View {
    @AppStorage(GaiPreferenceKey.agentDesktopNotifications) private var desktopNotifications = true
    @AppStorage(GaiPreferenceKey.agentNotificationSoundEnabled) private var soundEnabled = true
    @AppStorage(GaiPreferenceKey.agentNotificationSoundName) private var soundID = GaiNotificationSoundLibrary.defaultID
    @AppStorage(GaiPreferenceKey.agentNotificationSoundVolume) private var volume = GaiNotificationSoundLibrary.defaultVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Notifications") {
                SettingsToggle(
                    title: "Desktop notifications",
                    subtitle: "Show a macOS banner when Codex or Claude finishes in a background pane.",
                    first: true,
                    isOn: $desktopNotifications)
            }

            SettingsSection(title: "Sounds") {
                SettingsToggle(
                    title: "Play notification sound",
                    subtitle: "Use the selected DouDou Company sound for CLI completion notifications.",
                    first: true,
                    isOn: $soundEnabled)
                SettingsRow(title: "Sound", subtitle: "Choose the bundled completion sound.") {
                    Picker("", selection: $soundID) {
                        ForEach(GaiNotificationSoundLibrary.sounds) { sound in
                            Text(sound.displayName).tag(sound.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsRow(title: "Volume", subtitle: "Preview the exact notification volume.") {
                    HStack(spacing: 10) {
                        Slider(value: $volume, in: 0...1)
                            .frame(width: 126)
                        Text("\(Int((volume * 100).rounded()))%")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 38, alignment: .trailing)
                        Button {
                            GaiNotificationSoundPlayer.shared.preview(id: soundID, volume: volume)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 24)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(S.accent.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Test sound")
                    }
                }
            }
        }
    }
}

// MARK: - Editor

private struct EditorSettings: View {
    @AppStorage(GaiPreferenceKey.editorFontSize) private var fontSize = 13.0
    @AppStorage(GaiPreferenceKey.editorShowLineNumbers) private var lineNumbers = true
    @AppStorage(GaiPreferenceKey.editorWrapLines) private var wrap = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Code editor") {
                SettingsRow(title: "Font size", subtitle: "Monospaced font size in points.", first: true) {
                    HStack(spacing: 8) {
                        stepper("minus") { fontSize = max(9, fontSize - 1) }
                        Text("\(Int(fontSize))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18)
                        stepper("plus") { fontSize = min(24, fontSize + 1) }
                    }
                }
                SettingsToggle(title: "Show line numbers", isOn: $lineNumbers)
                SettingsToggle(title: "Wrap long lines", isOn: $wrap)
            }
        }
    }

    private func stepper(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @State private var fullDisk = false
    @State private var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    @State private var notificationAlertSetting: UNNotificationSetting = .notSupported
    @State private var notificationBadgeSetting: UNNotificationSetting = .notSupported
    @State private var notificationSoundSetting: UNNotificationSetting = .notSupported

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Notifications") {
                SettingsRow(
                    title: "macOS notifications",
                    subtitle: "Required for desktop banners when Codex or Claude finishes in a background pane.",
                    first: true) {
                    notificationStatusBadge
                }
                SettingsRow(
                    title: "Activate notifications",
                    subtitle: notificationActionSubtitle) {
                    actionButton(notificationActionTitle, action: activateNotifications)
                }
                SettingsRow(
                    title: "Banners",
                    subtitle: "Allows the top-right macOS notification banner.") {
                    PermissionStatusBadge(
                        title: notificationAlertSetting == .enabled ? "Ready" : "Off",
                        state: notificationAlertSetting == .enabled ? .granted : .blocked)
                }
                SettingsRow(
                    title: "Dock badge",
                    subtitle: "Allows macOS notification badge support; DouDou Company also updates its Dock count directly.") {
                    PermissionStatusBadge(
                        title: notificationBadgeSetting == .enabled ? "Ready" : "Off",
                        state: notificationBadgeSetting == .enabled ? .granted : .blocked)
                }
                SettingsRow(
                    title: "Notification sound",
                    subtitle: "Allows sound on macOS notifications. DouDou Company sounds are controlled in Notifications → Sounds.") {
                    PermissionStatusBadge(
                        title: notificationSoundSetting == .enabled ? "Ready" : "Off",
                        state: notificationSoundSetting == .enabled ? .granted : .blocked)
                }
            }

            SettingsSection(title: "Keyboard shortcut") {
                SettingsRow(
                    title: "Show or hide all agents",
                    subtitle: "Press and release Shift + Option to toggle every agent, even while another app is active. No permission is required.",
                    first: true) {
                    Text("⇧⌥")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.09))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)))
                        .accessibilityLabel("Shift plus Option")
                }
            }

            SettingsSection(title: "File access") {
                SettingsRow(
                    title: "Full Disk Access",
                    subtitle: "Grant this once and macOS stops asking for your Documents, Desktop and other folders every time the file explorer or a terminal touches them.",
                    first: true) {
                    PermissionStatusBadge(
                        title: fullDisk ? "Granted" : "Not granted",
                        state: fullDisk ? .granted : .blocked)
                }
                SettingsRow(
                    title: "Open System Settings",
                    subtitle: "Find DouDou Company in the list, switch it on. If it isn't listed, use “+” and pick DouDou Company.") {
                    actionButton("Open Full Disk Access", action: openFullDiskAccess)
                }
                SettingsRow(
                    title: "Re-check status",
                    subtitle: "After enabling it, refresh the status here.") {
                    actionButton("Re-check", filled: false, action: { fullDisk = Self.hasFullDiskAccess() })
                }
            }

            Text("After enabling Full Disk Access, quit and reopen DouDou Company once for it to take effect.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
        }
        .onAppear { refreshPermissionStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
    }

    private var notificationStatusBadge: some View {
        switch notificationAuthorization {
        case .authorized, .provisional, .ephemeral:
            PermissionStatusBadge(title: "Granted", state: .granted)
        case .denied:
            PermissionStatusBadge(title: "Denied", state: .blocked)
        case .notDetermined:
            PermissionStatusBadge(title: "Not requested", state: .pending)
        @unknown default:
            PermissionStatusBadge(title: "Unknown", state: .pending)
        }
    }

    private var notificationActionTitle: String {
        notificationAuthorization == .notDetermined ? "Allow Notifications" : "Open Notifications Settings"
    }

    private var notificationActionSubtitle: String {
        notificationAuthorization == .notDetermined
            ? "Ask macOS for banners, sounds and badge permission now."
            : "Change banners, sounds and badges in macOS Settings."
    }

    private func actionButton(_ title: String, filled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(filled ? S.accent.opacity(0.85) : Color.white.opacity(0.1)))
    }

    private func activateNotifications() {
        let center = UNUserNotificationCenter.current()
        if notificationAuthorization == .notDetermined {
            center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
                refreshNotificationStatus()
            }
        } else {
            openNotificationSettings()
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshPermissionStatus() {
        fullDisk = Self.hasFullDiskAccess()
        refreshNotificationStatus()
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationAuthorization = settings.authorizationStatus
                notificationAlertSetting = settings.alertSetting
                notificationBadgeSetting = settings.badgeSetting
                notificationSoundSetting = settings.soundSetting
            }
        }
    }

    /// Heuristic: try to open a TCC-protected file (the user's TCC database).
    /// It only opens when Full Disk Access is granted.
    static func hasFullDiskAccess() -> Bool {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        try? handle.close()
        return true
    }
}

private enum PermissionBadgeState {
    case granted
    case pending
    case blocked

    var color: Color {
        switch self {
        case .granted:
            return Color(red: 0.35, green: 0.8, blue: 0.45)
        case .pending:
            return Color(red: 0.95, green: 0.65, blue: 0.3)
        case .blocked:
            return Color(red: 1, green: 0.27, blue: 0.27)
        }
    }
}

private struct PermissionStatusBadge: View {
    let title: String
    let state: PermissionBadgeState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(state.color)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Updates

private struct UpdatesSettings: View {
    @State private var autoCheck = false

    private var controller: UpdateController? {
        (NSApp.delegate as? AppDelegate)?.updateController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Software updates") {
                SettingsToggle(
                    title: "Automatically check for updates",
                    subtitle: "Periodically check for new versions of DouDou Company in the background.",
                    first: true,
                    isOn: Binding(get: { autoCheck }, set: { setAuto($0) }))
                SettingsRow(title: "Check now", subtitle: "Look for an update right now.") {
                    Button("Check for Updates") { controller?.checkForUpdates() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(S.accent.opacity(0.85)))
                }
            }
        }
        .onAppear { autoCheck = controller?.updater.automaticallyChecksForUpdates ?? false }
    }

    private func setAuto(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        autoCheck = on
    }
}
