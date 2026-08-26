import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// UserDefaults keys for GaiTerm's GUI settings. Shared between the settings UI
/// and the features that consume them.
enum GaiPreferenceKey {
    /// Reveal a companion's compact CLI after a deliberate pointer hover.
    static let teddyPeekEnabled = "GaiTeddyPeekEnabled"
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

/// Settings design tokens. These deliberately mirror Teddy's monochrome
/// conversation shell so entering settings feels like changing sections, not
/// opening another application.
private enum TeddySettingsPalette {
    static let canvas = Color.black.opacity(0.72)
    static let sidebar = Color.black.opacity(0.82)
    static let sidebarRaised = Color.white.opacity(0.035)
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.085)
    static let selection = Color.white.opacity(0.075)
    static let control = Color.white.opacity(0.07)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.07)
    static let accent = Color.white.opacity(0.94)
}

// MARK: - Root

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "Général"
    case cli = "CLI"
    case appearance = "Apparence"
    case notifications = "Notifications"
    case editor = "Éditeur"
    case permissions = "Autorisations"
    case updates = "Mises à jour"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .cli: return "terminal"
        case .appearance: return "paintbrush"
        case .notifications: return "bell.badge"
        case .editor: return "chevron.left.forwardslash.chevron.right"
        case .permissions: return "lock.shield"
        case .updates: return "arrow.down.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Démarrage et comportement global"
        case .cli: "Détection locale et intégrations optionnelles"
        case .appearance: "Interface et surfaces de travail"
        case .notifications: "Alertes et sons des agents"
        case .editor: "Lisibilité du code et du terminal"
        case .permissions: "Accès accordés à Teddy CLI"
        case .updates: "Version et mises à jour"
        }
    }
}

struct SettingsView: View {
    let onDismiss: () -> Void

    @State private var category: SettingsCategory = .general
    @AppStorage("TeddyVoiceSidebarWidthV2") private var sidebarWidth = 252.0

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: resolvedSidebarWidth(in: geometry.size.width))
                Rectangle()
                    .fill(TeddySettingsPalette.hairline)
                    .frame(width: 1)
                detailPane
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.clear)
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarTopBar

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onDismiss) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10.5, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(TeddySettingsPalette.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text("Créer un doudou")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(TeddySettingsPalette.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.top, 12)

                Text("RÉGLAGES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(TeddySettingsPalette.tertiaryText)
                    .padding(.horizontal, 20)
                    .padding(.top, 19)
                    .padding(.bottom, 8)

                ForEach(SettingsCategory.allCases) { item in
                    sidebarItem(item)
                }

                Spacer(minLength: 0)
            }

            settingsFooter
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TeddySettingsPalette.sidebar)
    }

    private var sidebarTopBar: some View {
        ZStack(alignment: .trailing) {
            SettingsWindowDragRegion()
            Button(action: onDismiss) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TeddySettingsPalette.secondaryText)
                    .frame(width: 30, height: 28)
                    .background(TeddySettingsPalette.sidebarRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 11)
            .help("Revenir à la création de doudou")
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TeddySettingsPalette.hairline).frame(height: 1)
        }
    }

    private func sidebarItem(_ item: SettingsCategory) -> some View {
        let active = category == item
        return Button { category = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20)
                Text(item.rawValue)
                    .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? TeddySettingsPalette.primaryText : TeddySettingsPalette.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                active ? TeddySettingsPalette.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }

    private var settingsFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TeddySettingsPalette.primaryText)
                .frame(width: 32, height: 32)
                .background(TeddySettingsPalette.control, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Teddy CLI")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TeddySettingsPalette.primaryText)
                Text(appVersion)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(TeddySettingsPalette.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .overlay(alignment: .top) {
            Rectangle().fill(TeddySettingsPalette.hairline).frame(height: 1)
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                SettingsWindowDragRegion()
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TeddySettingsPalette.primaryText)
                    Text(category.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(TeddySettingsPalette.tertiaryText)
                }
                .padding(.leading, 28)
            }
            .frame(height: 64)
            .overlay(alignment: .bottom) {
                Rectangle().fill(TeddySettingsPalette.hairline).frame(height: 1)
            }

            ScrollView {
                detail
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 30)
                    .padding(.bottom, 44)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TeddySettingsPalette.canvas)
    }

    @ViewBuilder
    private var detail: some View {
        switch category {
        case .general: GeneralSettings()
        case .cli: CLIIntegrationsSettings()
        case .appearance: AppearanceSettings()
        case .notifications: NotificationsSettings()
        case .editor: EditorSettings()
        case .permissions: PermissionsSettings()
        case .updates: UpdatesSettings()
        }
    }

    private func resolvedSidebarWidth(in totalWidth: CGFloat) -> CGFloat {
        min(max(232, sidebarWidth), max(232, totalWidth - 640))
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(v)"
    }
}

// MARK: - CLI integrations

private struct CLIIntegrationsSettings: View {
    typealias Provider = GaiAgentHookInstaller.SupportedProvider
    typealias Status = GaiAgentHookInstaller.IntegrationStatus

    @State private var statuses: [Provider: Status] = [:]
    @State private var operationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Détection robuste") {
                SettingsRow(
                    title: "La voix reste disponible sans hooks",
                    subtitle: "Teddy CLI identifie la CLI depuis le processus réellement au premier plan. Les hooks améliorent uniquement la précision des débuts, fins et réponses finales.",
                    first: true) {
                    Label("Local", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.green.opacity(0.9))
                }
            }

            SettingsSection(title: "Adaptateurs natifs") {
                ForEach(Array(Provider.allCases.enumerated()), id: \.element.id) { index, provider in
                    SettingsRow(
                        title: provider.displayName,
                        subtitle: rowSubtitle(for: provider),
                        first: index == 0) {
                        HStack(spacing: 9) {
                            statusBadge(for: provider)
                            Button(actionTitle(for: provider)) {
                                configure(provider)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(TeddySettingsPalette.primaryText)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(
                                TeddySettingsPalette.control,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(TeddySettingsPalette.cardStroke, lineWidth: 1)
                            }
                        }
                    }
                }
            }

            if let operationMessage {
                Text(operationMessage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(TeddySettingsPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .onAppear(perform: refresh)
    }

    private func rowSubtitle(for provider: Provider) -> String {
        guard let status = statuses[provider] else {
            return "Vérification de la configuration locale…"
        }
        switch status.state {
        case .ready:
            return status.detail
        case .missing, .invalid:
            return "\(status.detail) Teddy CLI continue de fonctionner grâce à la détection locale."
        }
    }

    private func actionTitle(for provider: Provider) -> String {
        statuses[provider]?.state == .ready ? "Réparer" : "Configurer"
    }

    @ViewBuilder
    private func statusBadge(for provider: Provider) -> some View {
        let state = statuses[provider]?.state
        let ready = state == .ready
        Label(
            ready ? "Prêt" : state == .invalid ? "À réparer" : "Optionnel",
            systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(ready ? Color.green.opacity(0.88) : TeddySettingsPalette.secondaryText)
    }

    private func configure(_ provider: Provider) {
        do {
            try GaiAgentHookInstaller.configureIntegration(for: provider)
            refresh()
            operationMessage = provider == .codex
                ? "Codex est configuré. S’il affiche une validation de confiance, ouvre /hooks et accepte l’empreinte une seule fois."
                : "\(provider.displayName) est configuré. Les prochaines sessions utiliseront l’adaptateur natif."
        } catch {
            refresh()
            operationMessage = "Impossible de configurer \(provider.displayName) : \(error.localizedDescription)"
        }
    }

    private func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: Provider.allCases.map {
            ($0, GaiAgentHookInstaller.integrationStatus(for: $0))
        })
    }
}

private struct SettingsWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowDragView {
        SettingsWindowDragView()
    }

    func updateNSView(_ nsView: SettingsWindowDragView, context: Context) {}
}

private final class SettingsWindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
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
                .foregroundStyle(TeddySettingsPalette.tertiaryText)
            VStack(spacing: 0) { content }
                .background(TeddySettingsPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TeddySettingsPalette.cardStroke, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.bottom, 22)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var first: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle()
                    .fill(TeddySettingsPalette.hairline)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TeddySettingsPalette.primaryText)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(TeddySettingsPalette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 18)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
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
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(TeddySettingsPalette.accent)
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
    @AppStorage(
        GaiPreferenceKey.teddyPeekEnabled,
        store: UserDefaults.ghostty)
    private var teddyPeekEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Démarrage") {
                SettingsToggle(
                    title: "Ouvrir Teddy CLI à la connexion",
                    subtitle: "Lance Teddy CLI automatiquement à l’ouverture de ta session Mac.",
                    first: true,
                    isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            }

            SettingsSection(title: "Doudous sur le bureau") {
                SettingsToggle(
                    title: "Afficher la CLI au survol",
                    subtitle: "Laisse brièvement le pointeur sur un doudou pour lire sa CLI sans changer de fenêtre.",
                    first: true,
                    isOn: $teddyPeekEnabled)
            }
        }
        .onAppear { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
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
            SettingsSection(title: "Surfaces") {
                SettingsToggle(
                    title: "Teinter les panneaux avec la couleur du projet",
                    subtitle: "Applique une nuance sombre de la couleur du projet aux panneaux. Désactivé, l’interface reste neutre.",
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
                    title: "Notifications sur le bureau",
                    subtitle: "Affiche une bannière macOS lorsqu’une CLI termine en arrière-plan.",
                    first: true,
                    isOn: $desktopNotifications)
            }

            SettingsSection(title: "Sons") {
                SettingsToggle(
                    title: "Jouer un son de notification",
                    subtitle: "Utilise le son Teddy CLI sélectionné lorsqu’un agent termine.",
                    first: true,
                    isOn: $soundEnabled)
                SettingsRow(title: "Son", subtitle: "Choisis le signal joué à la fin d’une mission.") {
                    Picker("", selection: $soundID) {
                        ForEach(GaiNotificationSoundLibrary.sounds) { sound in
                            Text(sound.displayName).tag(sound.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsRow(title: "Volume", subtitle: "Préécoute le volume exact des notifications.") {
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
                                    .fill(TeddySettingsPalette.accent.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Écouter le son")
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
            SettingsSection(title: "Éditeur de code") {
                SettingsRow(title: "Taille du texte", subtitle: "Taille de la police monospace en points.", first: true) {
                    HStack(spacing: 8) {
                        stepper("minus") { fontSize = max(9, fontSize - 1) }
                        Text("\(Int(fontSize))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18)
                        stepper("plus") { fontSize = min(24, fontSize + 1) }
                    }
                }
                SettingsToggle(title: "Afficher les numéros de ligne", isOn: $lineNumbers)
                SettingsToggle(title: "Replier les lignes longues", isOn: $wrap)
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
                    title: "Notifications macOS",
                    subtitle: "Nécessaire pour afficher une bannière lorsqu’une CLI termine en arrière-plan.",
                    first: true) {
                    notificationStatusBadge
                }
                SettingsRow(
                    title: "Activer les notifications",
                    subtitle: notificationActionSubtitle) {
                    actionButton(notificationActionTitle, action: activateNotifications)
                }
                SettingsRow(
                    title: "Bannières",
                    subtitle: "Autorise l’affichage des notifications dans le coin supérieur droit.") {
                    PermissionStatusBadge(
                        title: notificationAlertSetting == .enabled ? "Prêt" : "Désactivé",
                        state: notificationAlertSetting == .enabled ? .granted : .blocked)
                }
                SettingsRow(
                    title: "Badge du Dock",
                    subtitle: "Autorise le compteur de notifications sur l’icône Teddy CLI.") {
                    PermissionStatusBadge(
                        title: notificationBadgeSetting == .enabled ? "Prêt" : "Désactivé",
                        state: notificationBadgeSetting == .enabled ? .granted : .blocked)
                }
                SettingsRow(
                    title: "Son des notifications",
                    subtitle: "Autorise les sons macOS. Les sons Teddy CLI se règlent dans Notifications.") {
                    PermissionStatusBadge(
                        title: notificationSoundSetting == .enabled ? "Prêt" : "Désactivé",
                        state: notificationSoundSetting == .enabled ? .granted : .blocked)
                }
            }

            SettingsSection(title: "Raccourci clavier") {
                SettingsRow(
                    title: "Afficher ou masquer tous les agents",
                    subtitle: "Appuie puis relâche Maj + Option pour basculer tous les doudous, même depuis une autre app.",
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
                        .accessibilityLabel("Maj plus Option")
                }
            }

            SettingsSection(title: "Accès aux fichiers") {
                SettingsRow(
                    title: "Accès complet au disque",
                    subtitle: "Autorise une fois l’accès à Documents, Bureau et aux dossiers utilisés par les terminaux.",
                    first: true) {
                    PermissionStatusBadge(
                        title: fullDisk ? "Accordé" : "Non accordé",
                        state: fullDisk ? .granted : .blocked)
                }
                SettingsRow(
                    title: "Ouvrir les Réglages Système",
                    subtitle: "Active Teddy CLI dans la liste. S’il n’apparaît pas, ajoute-le avec le bouton « + ».") {
                    actionButton("Ouvrir l’accès complet", action: openFullDiskAccess)
                }
                SettingsRow(
                    title: "Actualiser l’état",
                    subtitle: "Vérifie de nouveau l’autorisation après l’avoir activée.") {
                    actionButton("Actualiser", filled: false, action: { fullDisk = Self.hasFullDiskAccess() })
                }
            }

            Text("Après avoir accordé l’accès complet au disque, quitte puis rouvre Teddy CLI une seule fois.")
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
            PermissionStatusBadge(title: "Accordé", state: .granted)
        case .denied:
            PermissionStatusBadge(title: "Refusé", state: .blocked)
        case .notDetermined:
            PermissionStatusBadge(title: "Non demandé", state: .pending)
        @unknown default:
            PermissionStatusBadge(title: "Inconnu", state: .pending)
        }
    }

    private var notificationActionTitle: String {
        notificationAuthorization == .notDetermined
            ? "Autoriser"
            : "Ouvrir les réglages"
    }

    private var notificationActionSubtitle: String {
        notificationAuthorization == .notDetermined
            ? "Demande à macOS l’accès aux bannières, sons et badges."
            : "Modifie les bannières, sons et badges dans les Réglages Système."
    }

    private func actionButton(_ title: String, filled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(filled ? TeddySettingsPalette.accent.opacity(0.16) : TeddySettingsPalette.control))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(filled ? 0.11 : 0.07), lineWidth: 1)
            }
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
            SettingsSection(title: "Logiciel") {
                SettingsToggle(
                    title: "Rechercher automatiquement les mises à jour",
                    subtitle: "Vérifie périodiquement les nouvelles versions de Teddy CLI en arrière-plan.",
                    first: true,
                    isOn: Binding(get: { autoCheck }, set: { setAuto($0) }))
                SettingsRow(title: "Vérifier maintenant", subtitle: "Recherche immédiatement une nouvelle version.") {
                    Button("Rechercher") { controller?.checkForUpdates() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            TeddySettingsPalette.accent.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.11), lineWidth: 1)
                        }
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
