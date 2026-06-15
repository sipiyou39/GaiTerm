#if os(macOS)
import AppKit
import SwiftUI

/// Editor two-tone: the line-number gutter matches the dark panel/tab gray, the
/// code area matches the lighter terminal interior.
enum GaiEditorColors {
    static let gutter = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    static let codeArea = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)
}

/// Holds the contents of the file open in the stage editor. One long-lived model
/// reused as the user switches files (`open(_:)`); reading/writing is UTF-8,
/// binary files surface a friendly message instead of garbage.
final class GaiEditorModel: ObservableObject {
    @Published private(set) var path: String?
    @Published var text: String = ""
    @Published private(set) var isModified = false
    @Published private(set) var loadError: String?

    private var original = ""

    var name: String { path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
    var language: String { path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "" }

    init() {}
    init(path: String) { open(path) }

    func open(_ newPath: String?) {
        guard newPath != path else { return }
        path = newPath
        guard let newPath else {
            text = ""; original = ""; isModified = false; loadError = nil; return
        }
        guard let data = FileManager.default.contents(atPath: newPath) else {
            loadError = "Can't read this file."; text = ""; return
        }
        guard let string = String(data: data, encoding: .utf8) else {
            loadError = "Binary file — can't edit here."; text = ""; return
        }
        original = string
        text = string
        isModified = false
        loadError = nil
    }

    func updateText(_ new: String) {
        text = new
        isModified = (new != original)
    }

    func save() {
        guard let path, loadError == nil else { return }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            original = text
            isModified = false
        } catch {
            loadError = "Save failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Line number gutter

/// Line-number gutter. We override `draw(_:)` and DON'T call `super`, so the
/// base `NSRulerView` never paints its content-edge separator — that separator
/// (not our numbers) is what was bleeding up into the stage header. We draw only
/// the numbers, on a transparent gutter.
final class GaiLineNumberRuler: NSRulerView {
    private weak var sourceTextView: NSTextView?

    init(textView: NSTextView) {
        self.sourceTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Dark gutter (panel/tab gray); clipped to the editor so it can't bleed up.
        GaiEditorColors.gutter.setFill()
        bounds.fill()

        guard let textView = sourceTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let content = textView.string as NSString
        let visible = textView.visibleRect
        let inset = textView.textContainerInset.height

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.30),
        ]

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        if charRange.location > 0 {
            content.enumerateSubstrings(
                in: NSRange(location: 0, length: charRange.location),
                options: [.byLines, .substringNotRequired]) { _, _, _, _ in lineNumber += 1 }
        }

        var index = charRange.location
        while index <= NSMaxRange(charRange) {
            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let glyphLine = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphLine, in: container)
            let y = rect.minY + inset - visible.minY

            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + 1), withAttributes: attrs)

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        }
    }
}

// MARK: - Text view

/// NSTextView subclass that forwards ⌘S to a save closure.
final class GaiSourceTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// SwiftUI wrapper around a themed, monospaced, line-numbered editor.
struct GaiCodeTextView: NSViewRepresentable {
    @ObservedObject var model: GaiEditorModel
    let accent: Color

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = GaiEditorColors.codeArea   // light gray (terminal interior)
        scrollView.borderType = .noBorder

        let textView = GaiSourceTextView()
        textView.delegate = context.coordinator
        textView.onSave = { [weak model] in model?.save() }
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = GaiEditorColors.codeArea
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor(white: 1, alpha: 0.88)
        textView.insertionPointColor = NSColor(accent)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(white: 1, alpha: 0.16)]
        textView.textContainerInset = NSSize(width: 6, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = model.text

        scrollView.documentView = textView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = GaiLineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.language = model.language
        highlight(textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.language = model.language
        if textView.string != model.text {
            textView.string = model.text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.ruler?.needsDisplay = true
            highlight(textView)
        }
        textView.insertionPointColor = NSColor(accent)
    }

    private func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        GaiSyntax.highlight(storage, language: model.language, font: font)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: GaiEditorModel
        weak var textView: NSTextView?
        weak var ruler: GaiLineNumberRuler?
        var language = ""

        init(model: GaiEditorModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            model.updateText(textView.string)
            ruler?.needsDisplay = true   // refresh line numbers after the edit
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            GaiSyntax.highlight(storage, language: language, font: font)
        }
    }
}

// MARK: - Editor pane (content only — the stage provides the frame)

/// The editor body shown inside the stage: the code view, or a friendly message
/// for files that can't be edited.
struct GaiEditorPaneContent: View {
    @ObservedObject var model: GaiEditorModel
    let accent: Color

    var body: some View {
        if let error = model.loadError {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                if let path = model.path {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GaiCodeTextView(model: model, accent: accent)
        }
    }
}
#endif
