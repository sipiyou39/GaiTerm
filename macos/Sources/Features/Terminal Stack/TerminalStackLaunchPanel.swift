#if os(macOS)
import AppKit
import SwiftUI

final class TerminalStackLaunchPanel: NSObject, NSWindowDelegate {
    private static var current: TerminalStackLaunchPanel?

    private var panel: NSPanel?
    private var completion: ((Int) -> Void)?

    static func present(defaultCount: Int = 3, completion: @escaping (Int) -> Void) {
        current?.panel?.close()
        let launcher = TerminalStackLaunchPanel()
        current = launcher
        launcher.show(defaultCount: defaultCount, completion: completion)
    }

    private func show(defaultCount: Int, completion: @escaping (Int) -> Void) {
        self.completion = completion

        let size = NSSize(width: 430, height: 310)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        panel.contentView = NSHostingView(rootView: TerminalStackLaunchView(
            initialCount: defaultCount,
            onCancel: { [weak self] in self?.finish(count: 1) },
            onStart: { [weak self] count in self?.finish(count: count) }
        ))

        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(count: Int) {
        let sanitized = min(max(count, 1), 8)
        let completion = completion
        self.completion = nil
        panel?.close()
        completion?(sanitized)
        Self.current = nil
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

private struct TerminalStackLaunchView: View {
    @State private var count: Int
    var onCancel: () -> Void
    var onStart: (Int) -> Void

    init(initialCount: Int, onCancel: @escaping () -> Void, onStart: @escaping (Int) -> Void) {
        _count = State(initialValue: initialCount)
        self.onCancel = onCancel
        self.onStart = onStart
    }

    var body: some View {
        ZStack {
            VisualEffectMaterial(material: .hudWindow, blendingMode: .behindWindow)
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("GaiTerm")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                    Text("Combien de terminaux ?")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Ils seront replis en pile a gauche. Tu peux les deployer, previsualiser, puis afficher celui que tu veux.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.64))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(width: 330)
                }

                HStack(spacing: 16) {
                    stepButton(systemName: "minus") {
                        count = max(1, count - 1)
                    }
                    Text("\(count)")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 86)
                    stepButton(systemName: "plus") {
                        count = min(8, count + 1)
                    }
                }

                HStack(spacing: 10) {
                    Button("Un seul normal", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(width: 132, height: 38)
                        .background(.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))

                    Button {
                        onStart(count)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "rectangle.stack.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text("Creer la pile")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.black.opacity(0.88))
                        .frame(width: 146, height: 38)
                        .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.90))
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct VisualEffectMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}
#endif
