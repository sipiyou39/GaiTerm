import AppKit
import SwiftUI
import Sparkle

private extension NSWindow.Level {
    static let gaiUpdate = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 4)
}

private struct GaiUpdateReleaseNotes {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"

    static let today: [String] = [
        "Les panes Codex et Claude peuvent maintenant notifier quand ils ont fini et attendent ton input.",
        "Rouge signifie qu'une CLI a repondu et que la reponse n'a pas encore ete lue.",
        "Orange signifie que la CLI attend toujours ton input. L'orange reste visible apres ouverture de la notification, puis disparait quand tu renvoies un travail avec Entree.",
        "La cloche dans le header d'un pane permet de muter ce pane sans perdre l'indicateur orange de CLI en attente.",
        "L'eclair dans le header d'un pane ouvre automatiquement le stage sur ce pane quand sa CLI finit.",
        "Les notifications macOS affichent maintenant une seule preview utile, avec workspace et dossier sur une meme ligne.",
        "Settings regroupe les autorisations importantes : notifications macOS, acces clavier global et Full Disk Access.",
        "Les fenetres critiques comme Settings, quit et update passent devant le stage.",
    ]
}

final class GaiUpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = GaiUpdateWindowController()

    private var updateWindow: NSWindow?
    private var notesWindow: NSWindow?
    private var pendingDismiss: (() -> Void)?

    func showUpdateAvailable(
        appcastItem: SUAppcastItem,
        install: @escaping () -> Void,
        remindLater: @escaping () -> Void
    ) {
        let version = appcastItem.displayVersionString.isEmpty
            ? GaiUpdateReleaseNotes.version
            : appcastItem.displayVersionString
        let size = appcastItem.contentLength > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(appcastItem.contentLength), countStyle: .file)
            : nil
        showUpdateAvailable(
            version: version,
            size: size,
            releaseDate: appcastItem.date,
            install: install,
            remindLater: remindLater)
    }

    func showUpdateAvailable(
        version: String,
        size: String? = nil,
        releaseDate: Date? = nil,
        install: @escaping () -> Void,
        remindLater: @escaping () -> Void
    ) {
        closeUpdateWindow(runDismiss: false)
        pendingDismiss = remindLater

        let view = GaiUpdateAvailableWindow(
            version: version,
            size: size,
            releaseDate: releaseDate,
            remindLater: { [weak self] in
                self?.closeUpdateWindow(runDismiss: true)
            },
            installNow: { [weak self] in
                self?.pendingDismiss = nil
                self?.updateWindow?.close()
                self?.updateWindow = nil
                install()
            })
        let window = makeWindow(
            title: "GaiTerm Update",
            size: NSSize(width: 430, height: 276),
            rootView: view)
        updateWindow = window
        window.delegate = self
        show(window)
    }

    func showReleaseNotes(version: String = GaiUpdateReleaseNotes.version) {
        closeNotesWindow()
        let view = GaiReleaseNotesWindow(
            version: version,
            notes: GaiUpdateReleaseNotes.today,
            close: { [weak self] in self?.closeNotesWindow() })
        let window = makeWindow(
            title: "GaiTerm Release Notes",
            size: NSSize(width: 520, height: 520),
            rootView: view)
        notesWindow = window
        show(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === updateWindow {
            let dismiss = pendingDismiss
            pendingDismiss = nil
            updateWindow = nil
            dismiss?()
        } else if window === notesWindow {
            notesWindow = nil
        }
    }

    private func closeUpdateWindow(runDismiss: Bool) {
        let dismiss = runDismiss ? pendingDismiss : nil
        pendingDismiss = nil
        updateWindow?.delegate = nil
        updateWindow?.close()
        updateWindow = nil
        dismiss?()
    }

    private func closeNotesWindow() {
        notesWindow?.close()
        notesWindow = nil
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        rootView: Content
    ) -> NSWindow {
        let host = NSHostingController(
            rootView: rootView
                .frame(width: size.width, height: size.height))
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = .gaiUpdate
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = size
        window.maxSize = size
        window.setContentSize(size)
        return window
    }

    private func show(_ window: NSWindow) {
        window.center()
        window.level = .gaiUpdate
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct GaiUpdateAvailableWindow: View {
    let version: String
    let size: String?
    let releaseDate: Date?
    let remindLater: () -> Void
    let installNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.64, blue: 0.96))
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Mise a jour disponible")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("GaiTerm \(version) est pret a etre installe.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            HStack(spacing: 10) {
                infoPill("Version", version)
                if let size { infoPill("Taille", size) }
                if let releaseDate {
                    infoPill("Date", releaseDate.formatted(date: .abbreviated, time: .omitted))
                }
            }

            Text("Installe la mise a jour maintenant, ou garde ton flux de travail et GaiTerm te la reproposera plus tard.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("Me le rappeler plus tard", action: remindLater)
                    .buttonStyle(GaiUpdateSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Mettre a jour maintenant", action: installNow)
                    .buttonStyle(GaiUpdatePrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 430, height: 276, alignment: .topLeading)
        .background(GaiUpdateBackground())
        .preferredColorScheme(.dark)
    }

    private func infoPill(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.36))
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.07)))
    }
}

private struct GaiReleaseNotesWindow: View {
    let version: String
    let notes: [String]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.68, blue: 0.22))
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 7) {
                    Text("GaiTerm a ete mis a jour")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Version \(version)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(notes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(Color(red: 0.42, green: 0.64, blue: 0.96))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        Text(note)
                            .font(.system(size: 12.2))
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.055)))

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("OK", action: close)
                    .buttonStyle(GaiUpdatePrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520, height: 520, alignment: .topLeading)
        .background(GaiUpdateBackground())
        .preferredColorScheme(.dark)
    }
}

private struct GaiUpdateBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12)
            LinearGradient(
                colors: [
                    Color.white.opacity(0.045),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

private struct GaiUpdatePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 0.42, green: 0.64, blue: 0.96).opacity(configuration.isPressed ? 0.72 : 0.92)))
    }
}

private struct GaiUpdateSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.12 : 0.075)))
    }
}
