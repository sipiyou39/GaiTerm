import AppKit
import SwiftUI
import Sparkle

private extension NSWindow.Level {
    static let gaiUpdate = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 14)
}

private struct GaiReleaseNoteSection: Identifiable {
    let id: String
    let introducedVersion: String
    let icon: String
    let title: String
    let summary: String
    let points: [String]
    let color: Color
}

private enum GaiUpdateReleaseNotes {
    static let shownVersionKey = "GaiLastShownReleaseNotesVersion"
    static let seenVersionKey = "GaiLastSeenReleaseNotesVersion"
    static let forceEnvironmentKey = "GAI_SHOW_RELEASE_NOTES"
    static let versionEnvironmentKey = "GAI_RELEASE_NOTES_VERSION"
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"

    static var displayVersion: String {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment[versionEnvironmentKey], !forced.isEmpty {
            return forced
        }
        #endif
        return version
    }

    static let sections: [GaiReleaseNoteSection] = [
        .init(
            id: "agent-terminal-directory",
            introducedVersion: "2.0.2",
            icon: "folder.fill",
            title: "Change de dossier, garde ton terminal",
            summary: "Le terminal reste visible et prêt à écrire après la sélection d'un dossier.",
            points: [
                "Le nouveau terminal remplace maintenant correctement l'ancienne instance dans la fenêtre de l'agent.",
                "Le focus revient automatiquement pour reprendre le travail immédiatement.",
                "Les événements tardifs de l'ancien terminal sont ignorés afin de ne jamais perturber le nouveau.",
            ],
            color: Color(red: 0.50, green: 0.66, blue: 1.0)),
        .init(
            id: "agent-drag-and-shortcut",
            introducedVersion: "2.0.1",
            icon: "hand.draw.fill",
            title: "Des déplacements sans surprise",
            summary: "Le terminal s'efface pendant le geste et reste fermé ensuite.",
            points: [
                "Dès qu'un agent commence réellement à bouger, son terminal se ferme en douceur.",
                "Relâcher l'agent ne rouvre rien : un nouveau clic sur le doudou est nécessaire.",
                "Presse puis relâche Shift + Option (⇧⌥) pour masquer ou afficher tous les agents, depuis n'importe quelle application.",
            ],
            color: Color(red: 0.57, green: 0.38, blue: 0.90)),
        .init(
            id: "doudou-company",
            introducedVersion: "2.0.0",
            icon: "building.2.fill",
            title: "Bienvenue chez DouDou Company",
            summary: "GaiTerm devient une petite entreprise d'agents numeriques.",
            points: [
                "Chaque agent possede son propre terminal, son nom, sa couleur, sa taille et son dossier de travail.",
                "La bibliotheque centrale permet d'embaucher, renommer, regler et retrouver tous tes agents au meme endroit.",
                "L'identite visuelle, l'icone et les menus ont ete entierement repenses sans casser le canal de mise a jour existant.",
            ],
            color: Color(red: 0.57, green: 0.38, blue: 0.90)),
        .init(
            id: "desktop-agents",
            introducedVersion: "2.0.0",
            icon: "person.3.fill",
            title: "Des agents vivants sur le bureau",
            summary: "Tes doudous restent proches de leur terminal et reagissent au travail.",
            points: [
                "Clique sur un agent pour ouvrir ou refermer son terminal, deja pret a recevoir ta saisie.",
                "Deplace un agent librement : son terminal se ferme en douceur pendant le geste et se replace proprement.",
                "Un agent s'anime pendant son travail, puis saute et devient vert lorsque sa reponse est terminee.",
                "Le raccourci Shift + Option masque ou affiche toute l'equipe.",
            ],
            color: Color(red: 0.45, green: 0.78, blue: 0.67)),
        .init(
            id: "agent-terminal",
            introducedVersion: "2.0.0",
            icon: "terminal.fill",
            title: "Un terminal, un agent",
            summary: "Une interface plus simple, rapide et impossible a confondre.",
            points: [
                "Un seul terminal est ouvert a la fois, en format compact ou plein ecran, avec un rendu haute fluidite.",
                "Le dossier et le nom se modifient directement depuis le header, sans panneaux split ni commandes inutiles.",
                "Un clic a l'exterieur referme le terminal; le cadenas permet de le garder ouvert.",
                "Supprimer un agent demande toujours confirmation avant de tuer son terminal.",
            ],
            color: Color(red: 0.50, green: 0.66, blue: 1.0)),
        .init(
            id: "agent-lifecycle",
            introducedVersion: "2.0.0",
            icon: "waveform.path.ecg",
            title: "Suivi de travail robuste",
            summary: "DouDou Company comprend le cycle de travail de tes CLI.",
            points: [
                "Codex, Claude Code, Agy et OpenCode signalent leur activite par des evenements authentifies et ordonnes.",
                "Les sous-agents et les evenements repetes ne declenchent plus de fausses fins de travail.",
                "Le son de fin est reglable agent par agent et fonctionne avec l'animation de completion.",
            ],
            color: Color(red: 0.96, green: 0.65, blue: 0.32)),
        .init(
            id: "agent-resume",
            introducedVersion: "1.0.9",
            icon: "clock.arrow.circlepath",
            title: "Reprise Codex et Claude",
            summary: "Tes conversations CLI peuvent repartir au bon endroit.",
            points: [
                "Au lancement, DouDou Company detecte les sessions Codex et Claude liees aux panes restaurees.",
                "Tu peux reprendre une session precise, tout reprendre d'un coup, ou ignorer la reprise.",
                "Les panes se restaurent sans relancer automatiquement une ancienne conversation : rien ne repart sans ton clic.",
                "La fenetre de reprise reste au premier plan et s'ouvre au centre de l'ecran.",
            ],
            color: Color(red: 0.58, green: 0.66, blue: 0.78)),
        .init(
            id: "agent-resume-folders",
            introducedVersion: "1.0.10",
            icon: "folder.badge.gearshape",
            title: "Reprise par dossier",
            summary: "Chaque pane garde son identite agent meme si tu changes son dossier.",
            points: [
                "Changer le dossier d'un pane Codex ou Claude ne casse plus son lien avec la reprise de session.",
                "Au redemarrage, DouDou Company peut matcher chaque conversation avec le dossier propre a son pane, pas seulement avec le dossier du workspace.",
                "Le terminal est toujours rouvert proprement, mais l'identite Codex/Claude reste attachee au pane.",
            ],
            color: Color(red: 0.58, green: 0.78, blue: 1.0)),
        .init(
            id: "workspace-order",
            introducedVersion: "1.0.9",
            icon: "rectangle.stack.fill",
            title: "Workspaces reorganises",
            summary: "La liste de gauche devient vraiment pilotable.",
            points: [
                "Tu peux glisser un workspace pour changer son ordre.",
                "Le drag est magnetique et stable : l'element deplace sort de la liste pendant le geste, les autres se replacent proprement.",
                "L'ordre choisi est conserve au redemarrage.",
            ],
            color: Color(red: 0.42, green: 0.66, blue: 1.0)),
        .init(
            id: "pane-drag",
            introducedVersion: "1.0.9",
            icon: "square.split.2x2.fill",
            title: "Panes deplacables",
            summary: "La stage peut etre reorganisee sans reconstruire ton workspace.",
            points: [
                "Attrape le header d'un pane puis depose-le sur une zone de la stage.",
                "Les grandes zones pointillees montrent exactement la place que prendra le pane.",
                "Tu peux swapper deux panes ou splitter a gauche, droite, haut ou bas.",
                "Chaque nouveau split reequilibre automatiquement les panes pour garder des tailles propres.",
            ],
            color: Color(red: 1.0, green: 0.45, blue: 0.76)),
        .init(
            id: "persistence",
            introducedVersion: "1.0.9",
            icon: "externaldrive.fill",
            title: "Memoire de session",
            summary: "DouDou Company revient avec ton espace de travail au lieu de repartir a zero.",
            points: [
                "Les workspaces se rouvrent par defaut au lancement.",
                "La disposition des panes, leurs noms, dossiers, commandes CLI et options de notification sont restaurees.",
                "A la creation d'un workspace, le premier pane s'ouvre dans le dossier que tu as choisi.",
                "Les reglages cloche et eclair restent attaches au pane.",
            ],
            color: Color(red: 0.96, green: 0.74, blue: 0.30)),
        .init(
            id: "panel-sizing",
            introducedVersion: "1.0.9",
            icon: "arrow.left.and.right",
            title: "Largeurs ajustables",
            summary: "Drawer et stage s'adaptent a ton ecran et a tes noms de fichiers.",
            points: [
                "Le drawer peut etre agrandi sans descendre sous sa largeur minimale historique.",
                "La stage peut aussi etre redimensionnee sans selectionner le terminal.",
                "Le bouton lien synchronise les deux largeurs quand tu veux garder le meme ecart.",
            ],
            color: Color(red: 0.48, green: 0.88, blue: 0.70)),
        .init(
            id: "notifications-update",
            introducedVersion: "1.0.9",
            icon: "bell.badge.fill",
            title: "Notifications et mises a jour",
            summary: "Les alertes restent utiles sans polluer ton flux.",
            points: [
                "Les sons CLI sont joues par DouDou Company, meme quand les bannieres macOS ne suffisent pas.",
                "Rouge signale une reponse non lue, orange signale une CLI qui attend ton input.",
                "La confirmation de fermeture passe au premier plan, devant la stage, pour pouvoir terminer les processus sans blocage.",
                "La fenetre de mise a jour reste simple; les notes detaillees apparaissent seulement apres installation.",
            ],
            color: Color(red: 1.0, green: 0.35, blue: 0.35)),
    ]

    static func sectionsToShow(after previousVersion: String?, upTo currentVersion: String) -> [GaiReleaseNoteSection] {
        let available = sections.filter {
            versionCompare($0.introducedVersion, currentVersion) <= 0
        }
        if let previousVersion {
            return available.filter {
                versionCompare($0.introducedVersion, previousVersion) > 0
            }
        }

        // A fresh install should introduce every section from the current
        // product generation without replaying obsolete 1.x workspace notes.
        let currentMajor = versionParts(currentVersion).first ?? 0
        return available.filter {
            versionParts($0.introducedVersion).first == currentMajor
        }
    }

    private static func versionCompare(_ lhs: String, _ rhs: String) -> Int {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(String(digits)) ?? 0
            }
    }
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
            title: "DouDou Company Update",
            size: NSSize(width: 430, height: 230),
            rootView: view)
        updateWindow = window
        window.delegate = self
        show(window)
    }

    func showReleaseNotesIfNeeded(force: Bool = false) {
        #if DEBUG
        if ProcessInfo.processInfo.environment[GaiUpdateReleaseNotes.forceEnvironmentKey] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.showReleaseNotes(
                    version: GaiUpdateReleaseNotes.displayVersion,
                    sections: GaiUpdateReleaseNotes.sectionsToShow(
                        after: nil,
                        upTo: GaiUpdateReleaseNotes.displayVersion))
            }
            return
        }
        #endif

        let version = GaiUpdateReleaseNotes.version
        let defaults = UserDefaults.ghostty
        let previousSeenVersion = defaults.string(forKey: GaiUpdateReleaseNotes.seenVersionKey)
        defaults.set(version, forKey: GaiUpdateReleaseNotes.seenVersionKey)

        guard defaults.string(forKey: GaiUpdateReleaseNotes.shownVersionKey) != version else {
            return
        }
        guard force || previousSeenVersion != version else {
            return
        }

        let sections = GaiUpdateReleaseNotes.sectionsToShow(after: previousSeenVersion, upTo: version)
        guard !sections.isEmpty else { return }

        defaults.set(version, forKey: GaiUpdateReleaseNotes.shownVersionKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.showReleaseNotes(version: version, sections: sections)
        }
    }

    private func showReleaseNotes(
        version: String = GaiUpdateReleaseNotes.displayVersion,
        sections: [GaiReleaseNoteSection] = GaiUpdateReleaseNotes.sections
    ) {
        closeNotesWindow()
        let view = GaiReleaseNotesWindow(
            version: version,
            sections: sections,
            close: { [weak self] in self?.closeNotesWindow() })
        let window = makeWindow(
            title: "DouDou Company Release Notes",
            size: NSSize(width: 760, height: 690),
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
        center(window)
        window.level = .gaiUpdate
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            self.center(window)
            window.orderFrontRegardless()
        }
    }

    private func center(_ window: NSWindow) {
        guard let visible = NSScreen.screens.first?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrame(NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height), display: true)
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
                    Text("DouDou Company \(version) est pret a etre installe.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.68))
                }
            }

            Text("DouDou Company peut l'installer maintenant, ou te le rappeler plus tard.")
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
        .frame(width: 430, height: 230, alignment: .topLeading)
        .background(GaiUpdateBackground())
        .preferredColorScheme(.dark)
    }
}

private struct GaiReleaseNotesWindow: View {
    let version: String
    let sections: [GaiReleaseNoteSection]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            compactHeader

            GaiReleaseNotesListScrollView(sections: sections)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                Text("Ces notes cumulent les changements depuis ta derniere version.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                Button("Continuer", action: close)
                    .buttonStyle(GaiUpdatePrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(width: 760, height: 690, alignment: .topLeading)
        .background(GaiUpdateBackground())
        .preferredColorScheme(.dark)
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(red: 1, green: 0.68, blue: 0.22))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(0.075)))

            Text("DouDou Company \(version)")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text("Reprise agents, drag & drop, memoire de session, redimensionnement et notifications.")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text("Mise a jour installee")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(height: 24)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(0.075)))
        }
        .frame(height: 34)
    }
}

private struct GaiReleaseNotesListScrollView: NSViewRepresentable {
    let sections: [GaiReleaseNoteSection]

    func makeNSView(context _: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScrollElasticity = .allowed

        let host = NSHostingView(rootView: GaiReleaseNotesList(sections: sections))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.setContentHuggingPriority(.required, for: .vertical)
        scrollView.documentView = host

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            host.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let host = scrollView.documentView as? NSHostingView<GaiReleaseNotesList> else { return }
        host.rootView = GaiReleaseNotesList(sections: sections)
    }
}

private struct GaiReleaseNotesList: View {
    let sections: [GaiReleaseNoteSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections) { section in
                GaiReleaseNoteCard(section: section)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.trailing, 10)
        .padding(.bottom, 8)
    }
}

private struct GaiReleaseNoteCard: View {
    let section: GaiReleaseNoteSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(section.color.opacity(0.18))
                    Image(systemName: section.icon)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(section.color)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.system(size: 14.2, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(section.summary)
                        .font(.system(size: 12.2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(section.points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(section.color.opacity(0.9))
                            .frame(width: 4.2, height: 4.2)
                            .padding(.top, 6)
                        Text(point)
                            .font(.system(size: 11.8))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.075), lineWidth: 1)))
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
