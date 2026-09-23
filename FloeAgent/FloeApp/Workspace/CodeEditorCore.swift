// FloeApp — Shared native code/text editor core.
//
// SPDX-License-Identifier: MPL-2.0
//
// One UIKit editor implementation for every native text surface: the
// inspector's standalone editor and the workspace IDE's native text pane.
// It provides the TextKit line-number gutter, bounded regex highlighting and
// standard UIKit behavior (selection, hardware keyboard, undo manager, system
// edit menu) while protecting an in-flight input-method composition: while
// `markedTextRange` is active the text storage is never replaced and syntax
// highlighting is never re-rendered, because either write commits/cancels the
// composition and can drop or duplicate what the user typed. A programmatic
// update requested during composition is recorded and applied once the
// composition ends (`IDENativeEditorCompositionGuard`).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkspace

enum CodeLanguage: Equatable {
    case swift
    case python
    case javascript(displayName: String)
    case json
    case shell
    case cFamily(displayName: String)
    case markup(displayName: String)
    case stylesheet
    case configuration(displayName: String)
    case sql
    case generic(displayName: String)

    init?(relativePath: String) {
        let ext = WorkspaceFileType.pathExtension(for: relativePath)
        switch ext {
        case "swift": self = .swift
        case "py": self = .python
        case "js", "mjs", "cjs", "jsx": self = .javascript(displayName: "JavaScript")
        case "ts", "tsx": self = .javascript(displayName: "TypeScript")
        case "json", "jsonc": self = .json
        case "sh", "bash", "zsh", "fish": self = .shell
        case "c", "h", "m": self = .cFamily(displayName: "C / Objective-C")
        case "mm", "cc", "cpp", "cxx", "hpp": self = .cFamily(displayName: "C++")
        case "html", "htm", "xml", "vue", "svelte": self = .markup(displayName: ext.uppercased())
        case "css", "scss": self = .stylesheet
        case "yaml", "yml": self = .configuration(displayName: "YAML")
        case "toml": self = .configuration(displayName: "TOML")
        case "properties", "ini", "conf": self = .configuration(displayName: "Configuration")
        case "sql": self = .sql
        case "rs": self = .generic(displayName: "Rust")
        case "go": self = .generic(displayName: "Go")
        case "java": self = .generic(displayName: "Java")
        case "kt", "kts": self = .generic(displayName: "Kotlin")
        case "rb": self = .generic(displayName: "Ruby")
        case "php": self = .generic(displayName: "PHP")
        case "pl": self = .generic(displayName: "Perl")
        case "lua": self = .generic(displayName: "Lua")
        case "dart": self = .generic(displayName: "Dart")
        case "gradle": self = .generic(displayName: "Gradle")
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .python: "Python"
        case .javascript(let displayName), .cFamily(let displayName),
             .markup(let displayName), .configuration(let displayName),
             .generic(let displayName): displayName
        case .json: "JSON"
        case .shell: "Shell"
        case .stylesheet: "CSS"
        case .sql: "SQL"
        }
    }

    var icon: String {
        switch self {
        case .swift: "swift"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .json, .javascript: "curlybraces"
        case .shell: "terminal"
        default: "doc.text"
        }
    }

    var keywords: [String] {
        switch self {
        case .swift:
            return ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let", "nil", "nonisolated", "open", "private", "protocol", "public", "repeat", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]
        case .python:
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .javascript:
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
        case .cFamily:
            return ["auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "if", "import", "include", "inline", "int", "long", "namespace", "new", "nullptr", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"]
        case .shell:
            return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly", "select", "then", "until", "while"]
        case .sql:
            return ["ALTER", "AND", "AS", "ASC", "BEGIN", "BY", "CASE", "CREATE", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "FROM", "GROUP", "HAVING", "IN", "INDEX", "INSERT", "INTO", "IS", "JOIN", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "SELECT", "TABLE", "THEN", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE"]
        default:
            return []
        }
    }

    var usesHashComments: Bool {
        switch self {
        case .python, .shell, .configuration: true
        default: false
        }
    }

    var usesMarkupComments: Bool {
        if case .markup = self { return true }
        return false
    }

    var runnableToolName: String? {
        switch self {
        case .shell: "exec.shell"
        case .python: "exec.localPython"
        case .javascript: "exec.javascript"
        default: nil
        }
    }

    func symbols(in source: String) -> [(offset: Int, label: String)] {
        let pattern: String
        let nameGroup: Int
        switch self {
        case .python:
            pattern = #"(?m)^\s*(?:async\s+)?(class|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#
            nameGroup = 2
        case .javascript:
            pattern = #"(?m)^\s*(?:export\s+)?(?:async\s+)?(class|function|interface)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#
            nameGroup = 2
        case .swift:
            pattern = #"(?m)^\s*(?:(?:public|private|internal|fileprivate|open|final|static|nonisolated)\s+)*(actor|class|struct|enum|protocol|func)\s+([A-Za-z_][A-Za-z0-9_]*)"#
            nameGroup = 2
        default:
            return []
        }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        return expression.matches(in: source, range: NSRange(location: 0, length: nsSource.length)).compactMap { match in
            guard match.numberOfRanges > nameGroup,
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: nameGroup).location != NSNotFound else { return nil }
            let kind = nsSource.substring(with: match.range(at: 1))
            let name = nsSource.substring(with: match.range(at: nameGroup))
            return (match.range.location, "\(kind) \(name)")
        }
    }
}

struct CodeEditorCommand: Equatable {
    enum Kind: Equatable {
        case none
        case undo
        case redo
        case select(NSRange)
    }
    var revision = 0
    var kind: Kind = .none

    mutating func send(_ kind: Kind) {
        revision += 1
        self.kind = kind
    }
}

/// UIKit-backed code editor with a TextKit line-number gutter and bounded
/// syntax highlighting. Editing remains native, so keyboard selection,
/// hardware-keyboard shortcuts and the undo manager keep standard behavior.
/// An active IME composition is never disturbed by a programmatic update.
struct StructuredCodeTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    /// nil keeps the line-numbered editor without language coloring.
    let language: CodeLanguage?
    @Binding var command: CodeEditorCommand
    /// Editor zoom in points; nil uses the Dynamic Type baseline. Text and
    /// gutter are always set together.
    var fontSize: CGFloat? = nil
    var accessibilityIdentifier: String? = nil

    func makeUIView(context: Context) -> LineNumberTextView {
        let view = LineNumberTextView()
        view.backgroundColor = .clear
        view.applyEditorFont(size: fontSize)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.isEditable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = true
        view.showsHorizontalScrollIndicator = true
        view.delegate = context.coordinator
        view.text = text
        if let accessibilityIdentifier { view.accessibilityIdentifier = accessibilityIdentifier }
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: LineNumberTextView, context: Context) {
        if context.coordinator.appliedFontSize != fontSize {
            context.coordinator.appliedFontSize = fontSize
            view.applyEditorFont(size: fontSize)
        }
        context.coordinator.applyModelText(text, to: view)
        if context.coordinator.lastCommandRevision != command.revision {
            context.coordinator.lastCommandRevision = command.revision
            switch command.kind {
            case .none: break
            case .undo: view.undoManager?.undo()
            case .redo: view.undoManager?.redo()
            case .select(let range):
                let clamped = IDENativeTextEditing.clamp(range, to: view.text ?? "")
                view.selectedRange = clamped
                if clamped.length > 0 { view.scrollRangeToVisible(clamped) }
                view.becomeFirstResponder()
            }
        }
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StructuredCodeTextView
        var appliedFontSize: CGFloat?
        var isHighlighting = false
        var lastCommandRevision = 0
        /// Programmatic updates requested while an IME composition was active.
        var compositionGuard = IDENativeEditorCompositionGuard()

        init(_ parent: StructuredCodeTextView) { self.parent = parent }

        /// Applies the model's text to the view without ever writing through
        /// an active composition. A deferred value is applied when the
        /// composition ends.
        func applyModelText(_ text: String, to view: LineNumberTextView) {
            guard view.text != text else { return }
            let hasMarkedText = view.markedTextRange != nil
            guard compositionGuard.requestProgrammaticUpdate(text, hasMarkedText: hasMarkedText) else {
                // Applied by textViewDidChange once the composition ends.
                return
            }
            let selection = view.selectedRange
            view.text = text
            highlight(view)
            view.selectedRange = IDENativeTextEditing.clamp(selection, to: text)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isHighlighting else { return }
            parent.text = textView.text
            parent.selectedRange = textView.selectedRange
            guard let view = textView as? LineNumberTextView else { return }
            if view.markedTextRange != nil {
                // The composing text already reached the model through the
                // binding; never replace the storage or the colors now. The
                // commit fires another change event which highlights then.
                return
            }
            if let pending = compositionGuard.compositionDidEnd() {
                applyPendingText(pending, to: view)
                return
            }
            highlight(view)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? LineNumberTextView)?.setNeedsDisplay()
        }

        private func applyPendingText(_ text: String, to view: LineNumberTextView) {
            let selection = view.selectedRange
            parent.text = text
            view.text = text
            highlight(view)
            view.selectedRange = IDENativeTextEditing.clamp(selection, to: text)
        }

        func highlight(_ view: LineNumberTextView) {
            guard !isHighlighting else { return }
            // Re-rendering the storage during a composition would cancel it;
            // the commit's change event renders the final text instead.
            guard view.markedTextRange == nil else { return }
            isHighlighting = true
            defer { isHighlighting = false }
            let source = view.text ?? ""
            view.updateGutterWidth(for: source)
            let selection = view.selectedRange
            let full = NSRange(location: 0, length: (source as NSString).length)
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: EditorTheme.font,
                .foregroundColor: UIColor.label
            ]
            // Keep typing responsive for unusually large source files. They
            // retain the editor, line numbers and horizontal scrolling while
            // syntax color is intentionally bounded to 512 Ki UTF-16 units.
            guard full.length <= 512 * 1024, let language = parent.language else {
                applyPlainStorage(view, length: full.length, attributes: baseAttributes)
                return
            }
            let attributed = NSMutableAttributedString(
                string: source,
                attributes: baseAttributes
            )
            func apply(_ pattern: String, color: UIColor, options: NSRegularExpression.Options = []) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                regex.enumerateMatches(in: source, range: full) { match, _, _ in
                    if let range = match?.range { attributed.addAttribute(.foregroundColor, value: color, range: range) }
                }
            }
            let words = language.keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            if !words.isEmpty {
                apply("\\b(?:\(words))\\b", color: .systemPurple, options: language == .sql ? [.caseInsensitive] : [])
            }
            apply(#"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#, color: .systemBlue)
            apply(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .systemRed)
            if language.usesMarkupComments {
                apply(#"<!--[\s\S]*?-->"#, color: .systemGreen)
            } else if language.usesHashComments {
                apply(#"(?m)#.*$"#, color: .systemGreen)
            } else {
                apply(#"(?m)//.*$|/\*[\s\S]*?\*/"#, color: .systemGreen)
            }
            view.attributedText = attributed
            view.typingAttributes = baseAttributes
            view.selectedRange = IDENativeTextEditing.clamp(selection, to: source)
            view.setNeedsDisplay()
        }

        /// Plain (uncolored) storage for a file over the highlight bound or
        /// without a language. Rewriting the whole attributed string on every
        /// keystroke would allocate the full file text per key press, so the
        /// storage is only reset when it is not already plain.
        private func applyPlainStorage(
            _ view: LineNumberTextView,
            length: Int,
            attributes: [NSAttributedString.Key: Any]
        ) {
            if !isPlainStorage(view, length: length) {
                let selection = view.selectedRange
                let attributed = NSMutableAttributedString(string: view.text ?? "", attributes: attributes)
                view.attributedText = attributed
                view.selectedRange = IDENativeTextEditing.clamp(selection, to: view.text ?? "")
            }
            view.typingAttributes = attributes
            view.setNeedsDisplay()
        }

        private func isPlainStorage(_ view: LineNumberTextView, length: Int) -> Bool {
            guard length > 0 else { return true }
            guard let storage = view.attributedText, storage.length == length,
                  let color = storage.attribute(.foregroundColor, at: length - 1, effectiveRange: nil) as? UIColor,
                  let font = storage.attribute(.font, at: length - 1, effectiveRange: nil) as? UIFont else {
                return false
            }
            return color == UIColor.label && font == EditorTheme.font
        }
    }
}

enum EditorTheme {
    static var font: UIFont { font(size: nil) }
    static var gutterFont: UIFont { gutterFont(size: nil) }

    /// The editor's monospaced font at an explicit point size. `nil` uses the
    /// Dynamic Type body baseline, so the default follows accessibility text
    /// size and the zoom preference only overrides within safe bounds.
    static func font(size: CGFloat?) -> UIFont {
        .monospacedSystemFont(ofSize: resolvedSize(size), weight: .regular)
    }

    /// The gutter scales with the editor so line numbers, cursor geometry and
    /// text stay synchronized at every zoom level.
    static func gutterFont(size: CGFloat?) -> UIFont {
        .monospacedSystemFont(ofSize: max(9, resolvedSize(size) * 0.73), weight: .regular)
    }

    static func resolvedSize(_ size: CGFloat?) -> CGFloat {
        let requested = size ?? UIFont.preferredFont(forTextStyle: .body).pointSize
        return min(max(requested, IDEEditorFontSize.bounds.lowerBound), IDEEditorFontSize.bounds.upperBound)
    }
}

/// Persisted editor text-zoom preference. 0 means "follow Dynamic Type"; an
/// explicit value is clamped to a readable 12...28pt range.
enum IDEEditorFontSize {
    static let bounds: ClosedRange<CGFloat> = 12...28
    static let step: CGFloat = 1
    static let automatic: CGFloat = 0

    static func resolved(_ stored: CGFloat) -> CGFloat {
        stored > 0 ? min(max(stored, bounds.lowerBound), bounds.upperBound) : EditorTheme.resolvedSize(nil)
    }

    static func increased(_ stored: CGFloat) -> CGFloat {
        min(resolved(stored) + step, bounds.upperBound)
    }

    static func decreased(_ stored: CGFloat) -> CGFloat {
        max(resolved(stored) - step, bounds.lowerBound)
    }

    static func canIncrease(_ stored: CGFloat) -> Bool { resolved(stored) < bounds.upperBound }
    static func canDecrease(_ stored: CGFloat) -> Bool { resolved(stored) > bounds.lowerBound }
}

final class LineNumberTextView: UITextView {
    private var gutterWidth: CGFloat = 44
    /// The gutter font follows the editor zoom so line numbers, cursor
    /// geometry and text never drift apart.
    private var currentGutterFont: UIFont = EditorTheme.gutterFont(size: nil)
    private var currentLineCount = 1

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth + 8, bottom: 12, right: 12)
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    /// Applies the persisted zoom to text, gutter and inset together.
    func applyEditorFont(size: CGFloat?) {
        font = EditorTheme.font(size: size)
        currentGutterFont = EditorTheme.gutterFont(size: size)
        recomputeGutterWidth()
    }

    /// Keeps four-digit line numbers visible; the gutter only grows.
    func updateGutterWidth(for text: String) {
        currentLineCount = IDENativeTextEditing.lineCount(in: text)
        recomputeGutterWidth()
    }

    private func recomputeGutterWidth() {
        let digits = max(2, String(currentLineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: currentGutterFont]).width
        let required = CGFloat(digits) * digitWidth + 22
        guard required > gutterWidth + 0.5 else { return }
        gutterWidth = required
        textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth + 8, bottom: 12, right: 12)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        UIColor.secondarySystemBackground.setFill()
        context.fill(CGRect(x: contentOffset.x, y: rect.minY, width: gutterWidth, height: rect.height))

        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounds, in: textContainer)
        guard glyphRange.length > 0 else {
            context.restoreGState()
            return
        }
        let firstCharacter = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        let firstPrefix = (text as NSString).substring(to: min(firstCharacter, (text as NSString).length))
        var line = firstPrefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let value = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: currentGutterFont,
                .foregroundColor: UIColor.secondaryLabel
            ]
            let size = value.size(withAttributes: attributes)
            value.draw(
                at: CGPoint(
                    x: contentOffset.x + gutterWidth - size.width - 7,
                    y: fragment.minY + textContainerInset.top
                ),
                withAttributes: attributes
            )
            line += 1
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        context.restoreGState()
    }
}
#endif
