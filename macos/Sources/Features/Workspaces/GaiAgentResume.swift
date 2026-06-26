#if os(macOS)
import AppKit
import Foundation
import SwiftUI

enum GaiAgentKind: String, Codable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    var icon: String {
        switch self {
        case .codex: return "cpu"
        case .claude: return "sparkles"
        }
    }

    func resumeCommand(sessionID: String) -> String {
        switch self {
        case .codex:
            return "codex resume \(sessionID)"
        case .claude:
            return "claude --resume \(sessionID)"
        }
    }

    static func fromLaunchCommand(_ command: String?) -> GaiAgentKind? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let first = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        switch first {
        case "codex": return .codex
        case "claude": return .claude
        default: return nil
        }
    }
}

struct GaiAgentResumeCandidate: Identifiable, Equatable {
    let id: String
    let kind: GaiAgentKind
    let workspaceID: UUID
    let workspaceName: String
    let paneID: UUID?
    let paneName: String
    let directoryPath: String
    let updatedAt: Date
    let title: String?

    var command: String { kind.resumeCommand(sessionID: id) }

    var displayTitle: String {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean! : kind.displayName
    }

    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
    }
}

private struct GaiAgentExpectedPane {
    let kind: GaiAgentKind
    let workspaceID: UUID
    let workspaceName: String
    let paneID: UUID?
    let paneName: String
    let directoryPath: String
}

private struct GaiStoredAgentSession {
    let id: String
    let kind: GaiAgentKind
    let directoryPath: String
    let updatedAt: Date
    let title: String?
}

enum GaiAgentResumeScanner {
    private static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    static let forceEnvironmentKey = "GAI_SHOW_AGENT_RESUME"

    static func candidates(for workspaces: [GaiWorkspace]) -> [GaiAgentResumeCandidate] {
        let expected = expectedPanes(from: workspaces)
        guard !expected.isEmpty else { return [] }

        var available: [String: [GaiStoredAgentSession]] = [:]
        for session in scanCodexSessions() + scanClaudeSessions() {
            let key = matchKey(kind: session.kind, directoryPath: session.directoryPath)
            available[key, default: []].append(session)
        }
        for key in available.keys {
            available[key]?.sort { $0.updatedAt > $1.updatedAt }
        }

        var result: [GaiAgentResumeCandidate] = []
        var used = Set<String>()
        for pane in expected {
            let key = matchKey(kind: pane.kind, directoryPath: pane.directoryPath)
            guard var sessions = available[key] else { continue }
            while let session = sessions.first {
                sessions.removeFirst()
                let usedKey = "\(session.kind.rawValue):\(session.id)"
                if used.contains(usedKey) { continue }
                used.insert(usedKey)
                available[key] = sessions
                result.append(.init(
                    id: session.id,
                    kind: session.kind,
                    workspaceID: pane.workspaceID,
                    workspaceName: pane.workspaceName,
                    paneID: pane.paneID,
                    paneName: pane.paneName,
                    directoryPath: pane.directoryPath,
                    updatedAt: session.updatedAt,
                    title: session.title))
                break
            }
        }

        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    #if DEBUG
    static func debugCandidates(for workspaces: [GaiWorkspace]) -> [GaiAgentResumeCandidate] {
        guard let workspace = workspaces.first else { return [] }
        let session = workspace.sessions.first
        guard let stored = (scanCodexSessions() + scanClaudeSessions())
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
        else { return [] }

        return [.init(
            id: stored.id,
            kind: stored.kind,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            paneID: session?.id,
            paneName: session?.name ?? stored.kind.displayName,
            directoryPath: stored.directoryPath,
            updatedAt: stored.updatedAt,
            title: stored.title)]
    }
    #endif

    private static func expectedPanes(from workspaces: [GaiWorkspace]) -> [GaiAgentExpectedPane] {
        var result: [GaiAgentExpectedPane] = []
        for workspace in workspaces {
            if !workspace.sessions.isEmpty {
                for session in workspace.sessions {
                    guard let kind = GaiAgentKind.fromLaunchCommand(session.launchCommand) else { continue }
                    let path = normalizedPath(
                        session.surfaceView.pwd ??
                        session.initialDirectoryPath ??
                        workspace.defaultDirectory?.path)
                    guard !path.isEmpty else { continue }
                    result.append(.init(
                        kind: kind,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        paneID: session.id,
                        paneName: session.name,
                        directoryPath: path))
                }
                continue
            }

            if let layout = workspace.restoredPaneLayout {
                result.append(contentsOf: expectedPanes(
                    from: layout,
                    workspace: workspace))
            } else {
                for item in workspace.openPlan() {
                    guard let kind = GaiAgentKind.fromLaunchCommand(item.command) else { continue }
                    let path = normalizedPath((item.directory ?? workspace.defaultDirectory)?.path)
                    guard !path.isEmpty else { continue }
                    result.append(.init(
                        kind: kind,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        paneID: nil,
                        paneName: kind.displayName,
                        directoryPath: path))
                }
            }
        }
        return result
    }

    private static func expectedPanes(
        from layout: GaiPaneLayoutData,
        workspace: GaiWorkspace
    ) -> [GaiAgentExpectedPane] {
        switch layout {
        case .pane(let pane):
            guard let kind = GaiAgentKind.fromLaunchCommand(pane.command) else { return [] }
            let path = normalizedPath(pane.directoryPath ?? workspace.defaultDirectory?.path)
            guard !path.isEmpty else { return [] }
            return [.init(
                kind: kind,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                paneID: pane.id,
                paneName: pane.name,
                directoryPath: path)]
        case .split(_, _, let left, let right):
            return expectedPanes(from: left, workspace: workspace)
                + expectedPanes(from: right, workspace: workspace)
        }
    }

    private static func scanCodexSessions() -> [GaiStoredAgentSession] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        let index = readCodexTitles(from: home.appendingPathComponent("session_index.jsonl"))
        let cutoff = Date().addingTimeInterval(-maxAge)
        var sessions: [GaiStoredAgentSession] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let updatedAt = values?.contentModificationDate ?? .distantPast
            guard updatedAt >= cutoff else { continue }
            guard let meta = readFirstJSONLine(fileURL),
                  (meta["type"] as? String) == "session_meta",
                  let payload = meta["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String
            else { continue }

            sessions.append(.init(
                id: id,
                kind: .codex,
                directoryPath: normalizedPath(cwd),
                updatedAt: updatedAt,
                title: index[id]))
        }

        return sessions
    }

    private static func scanClaudeSessions() -> [GaiStoredAgentSession] {
        let historyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl", isDirectory: false)
        guard let content = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        let cutoffMillis = Date().addingTimeInterval(-maxAge).timeIntervalSince1970 * 1000
        var latest: [String: GaiStoredAgentSession] = [:]

        for line in content.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["sessionId"] as? String,
                  let project = object["project"] as? String,
                  let timestamp = object["timestamp"] as? Double,
                  timestamp >= cutoffMillis
            else { continue }

            let session = GaiStoredAgentSession(
                id: id,
                kind: .claude,
                directoryPath: normalizedPath(project),
                updatedAt: Date(timeIntervalSince1970: timestamp / 1000),
                title: object["display"] as? String)
            if let existing = latest[id], existing.updatedAt > session.updatedAt {
                continue
            }
            latest[id] = session
        }

        return Array(latest.values)
    }

    private static func readCodexTitles(from url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String
            else { continue }
            result[id] = name
        }
        return result
    }

    private static func readFirstJSONLine(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        guard let text = String(data: data, encoding: .utf8),
              let first = text.split(separator: "\n", maxSplits: 1).first,
              let lineData = String(first).data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
    }

    private static func matchKey(kind: GaiAgentKind, directoryPath: String) -> String {
        "\(kind.rawValue)|\(normalizedPath(directoryPath))"
    }

    private static func normalizedPath(_ path: String?) -> String {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }
}

final class GaiAgentResumeWindowController: NSObject, NSWindowDelegate {
    static let shared = GaiAgentResumeWindowController()

    private var window: NSWindow?
    private var model = GaiAgentResumeModel(candidates: [])

    func show(
        candidates: [GaiAgentResumeCandidate],
        screen: NSScreen? = nil,
        resume: @escaping (GaiAgentResumeCandidate) -> Void
    ) {
        guard !candidates.isEmpty else { return }
        close()
        model = GaiAgentResumeModel(candidates: candidates)
        model.resume = { [weak self] candidate in
            resume(candidate)
            self?.model.remove(candidate)
            if self?.model.candidates.isEmpty == true {
                self?.close()
            }
        }
        model.copy = { candidate in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(candidate.command, forType: .string)
        }
        model.dismiss = { [weak self] candidate in
            self?.model.remove(candidate)
            if self?.model.candidates.isEmpty == true {
                self?.close()
            }
        }
        model.dismissAll = { [weak self] in self?.close() }
        model.resumeAll = { [weak self] in
            guard let self else { return }
            let items = self.model.candidates
            for candidate in items {
                resume(candidate)
            }
            self.close()
        }

        let size = NSSize(width: 640, height: 360)
        let view = GaiAgentResumeWindow(model: model)
        let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        host.view.layer?.cornerRadius = GaiDrawerMetrics.cardCornerRadius
        host.view.layer?.masksToBounds = true
        host.view.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        let window = GaiAgentResumePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentViewController = host
        window.title = "Agents a reprendre"
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        // The panel shape draws its own rounded shadow. Native AppKit shadows are
        // rectangular for borderless windows and reveal a square frame at corners.
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 12)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.animationBehavior = .none
        window.minSize = size
        window.maxSize = size
        window.delegate = self
        self.window = window
        center(window, size: size, on: screen)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.center(window, size: size, on: screen)
            window.orderFrontRegardless()
        }
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func center(_ window: NSWindow, size: NSSize, on requestedScreen: NSScreen?) {
        let screen = requestedScreen ?? NSScreen.screens.first ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height)
        window.setFrame(frame, display: true)
    }

}

private final class GaiAgentResumePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class GaiAgentResumeModel: ObservableObject {
    @Published var candidates: [GaiAgentResumeCandidate]
    var resume: (GaiAgentResumeCandidate) -> Void = { _ in }
    var copy: (GaiAgentResumeCandidate) -> Void = { _ in }
    var dismiss: (GaiAgentResumeCandidate) -> Void = { _ in }
    var dismissAll: () -> Void = {}
    var resumeAll: () -> Void = {}

    init(candidates: [GaiAgentResumeCandidate]) {
        self.candidates = candidates
    }

    func remove(_ candidate: GaiAgentResumeCandidate) {
        candidates.removeAll { $0 == candidate }
    }
}

private struct GaiAgentResumeWindow: View {
    @ObservedObject var model: GaiAgentResumeModel

    private let cardWidth: CGFloat = 640
    private let cardHeight: CGFloat = 360

    private var panelColor: Color {
        Color.gaiPanelGray
    }

    private var controlColor: Color {
        Color(red: 108 / 255, green: 118 / 255, blue: 132 / 255)
    }

    var body: some View {
        ZStack {
            panelColor

            HStack(spacing: 0) {
                accentRail
                VStack(spacing: 0) {
                    header
                    ScrollView(showsIndicators: model.candidates.count > 3) {
                        VStack(spacing: 8) {
                            ForEach(model.candidates) { candidate in
                                GaiAgentResumeRow(
                                    candidate: candidate,
                                    resume: { model.resume(candidate) },
                                    copy: { model.copy(candidate) },
                                    dismiss: { model.dismiss(candidate) })
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    footer
                }
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: GaiDrawerMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GaiDrawerMetrics.cardCornerRadius, style: .continuous)
                .stroke(.white.opacity(0.11), lineWidth: 1))
        .preferredColorScheme(.dark)
    }

    private var accentRail: some View {
        VStack(spacing: 7) {
            ForEach(Array(model.candidates.prefix(5).enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(index == 0 ? controlColor.opacity(0.95) : .white.opacity(0.30))
                    .frame(width: 6, height: 6)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 34)
        .padding(.top, 34)
        .background(Color.white.opacity(0.025))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(controlColor.opacity(0.95))
                    Text("Reprendre les discussions")
                        .font(.system(size: 19, weight: .bold))
                }
                .foregroundStyle(.white)

                Text("Reprends Codex ou Claude exactement la ou tu les as laisses, dans le bon workspace et le bon pane.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack(spacing: 8) {
                Text("Sessions")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(height: 24)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.12)))

                Text("\(model.candidates.count)")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(controlColor.opacity(0.78)))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 18)
        .frame(height: 88)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Ignorer", action: model.dismissAll)
                .buttonStyle(GaiAgentSecondaryButtonStyle())
            Button(action: model.resumeAll) {
                Label("Tout reprendre", systemImage: "play.fill")
            }
            .buttonStyle(GaiAgentPrimaryButtonStyle(accent: controlColor))
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)
        }
    }
}

private struct GaiAgentResumeRow: View {
    let candidate: GaiAgentResumeCandidate
    let resume: () -> Void
    let copy: () -> Void
    let dismiss: () -> Void

    private var accent: Color { Color(red: 108 / 255, green: 118 / 255, blue: 132 / 255) }
    private var directoryName: String {
        let last = URL(fileURLWithPath: candidate.directoryPath).lastPathComponent
        return last.isEmpty ? candidate.directoryPath : last
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.white.opacity(0.56))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: candidate.kind.icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 18)
                    Text(candidate.displayTitle)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(candidate.kind.displayName)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.075))
                                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1)))
                    Spacer()
                    Text(candidate.relativeTime)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.38))
                }

                HStack(spacing: 8) {
                    Text(candidate.workspaceName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.76))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.28))
                    Text(candidate.paneName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.32))
                    Text(directoryName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 7) {
                Button(action: resume) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(GaiAgentIconButtonStyle(accent: accent, prominent: true))
                .help("Reprendre")

                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(GaiAgentIconButtonStyle(accent: accent, prominent: false))
                .help(candidate.command)

            }
        }
        .padding(.horizontal, 14)
        .frame(height: 74)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.13))
                        .frame(width: 2)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 1)))
    }
}

private struct GaiAgentPrimaryButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.58 : 0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 1)))
    }
}

private struct GaiAgentSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.10 : 0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)))
    }
}

private struct GaiAgentIconButtonStyle: ButtonStyle {
    let accent: Color
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? .white : .white.opacity(0.58))
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fillColor(pressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(strokeColor, lineWidth: 1)))
    }

    private func fillColor(pressed: Bool) -> Color {
        if prominent {
            return accent.opacity(pressed ? 0.54 : 0.36)
        }
        return Color.white.opacity(pressed ? 0.09 : 0.045)
    }

    private var strokeColor: Color {
        prominent ? accent.opacity(0.38) : .white.opacity(0.08)
    }
}
#endif
