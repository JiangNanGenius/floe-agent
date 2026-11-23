// SPDX-License-Identifier: MPL-2.0

#if FLOE_UNIFIED_MAC
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// EN / zh-CN inline strings for the Mac composer input surfaces, following
/// the `MacPermissionsText` convention: the Mac host mirrors the system
/// language without adding catalog keys.
enum MacComposerInputText {
    static func t(_ zh: String, _ en: String) -> String {
        MacPermissionsText.isChinese ? zh : en
    }
}

/// AppKit owns the full draft and scrolls the visible viewport. SwiftUI's
/// repeated size probes only measure a short draft or use the height cap.
struct MacComposerTextInput: View {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    let placeholder: String
    var focusRequest: UUID?
    var isEditable = true
    var pasteAttachments: (() -> Void)?
    var submit: (() -> Void)?

    static func hasText(_ text: String) -> Bool {
        text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var body: some View {
        Editor(text: $text, placeholder: placeholder, focusRequest: focusRequest,
               isEditable: isEditable && isEnabled, pasteAttachments: pasteAttachments, submit: submit)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(verbatim: placeholder)
                        .font(FloeTheme.Typography.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private struct Editor: NSViewRepresentable {
        @Binding var text: String
        let placeholder: String
        let focusRequest: UUID?
        let isEditable: Bool
        let pasteAttachments: (() -> Void)?
        let submit: (() -> Void)?
        private static let measurementLimit = 2_048
        private static let verticalInset: CGFloat = 4
        private static var font: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize + 1) }

        final class TextView: NSTextView {
            var pasteAttachments: (() -> Void)?
            var submit: (() -> Void)?

            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                if let submit, event.keyCode == 36 || event.keyCode == 76,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                    if isEditable && !hasMarkedText() { submit() }
                    return true
                }
                return super.performKeyEquivalent(with: event)
            }

            override func paste(_ sender: Any?) {
                let types = NSPasteboard.general.types ?? []
                if let pasteAttachments, types.contains(.fileURL) || (!types.contains(.string)
                    && types.contains { UTType($0.rawValue)?.conforms(to: .image) == true }) {
                    pasteAttachments()
                } else {
                    pasteAsPlainText(sender)
                }
            }
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var editor: Editor
            var displayedText: String
            var focusRequest: UUID?

            init(_ editor: Editor) {
                self.editor = editor
                displayedText = editor.text
            }

            func textDidChange(_ notification: Notification) {
                guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
                displayedText = view.string
                editor.text = displayedText
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let view = TextView(usingTextLayoutManager: true)
            view.frame = scroll.contentView.bounds
            view.autoresizingMask = [.width]
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = true
            view.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
            view.drawsBackground = false
            view.isRichText = false
            view.importsGraphics = false
            view.allowsUndo = true
            view.font = Self.font
            view.textColor = .labelColor
            view.setAccessibilityIdentifier("thread.composer.input")
            view.setAccessibilityLabel(placeholder)
            view.string = text
            view.delegate = context.coordinator
            scroll.documentView = view
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let view = scroll.documentView as? TextView else { return }
            let coordinator = context.coordinator
            if coordinator.editor.placeholder != placeholder { view.setAccessibilityLabel(placeholder) }
            coordinator.editor = self
            if view.isEditable != isEditable { view.isEditable = isEditable }
            view.pasteAttachments = pasteAttachments
            view.submit = submit
            if !view.hasMarkedText(), coordinator.displayedText != text {
                coordinator.displayedText = text
                let selected = view.selectedRange()
                view.string = text
                let length = (text as NSString).length
                let cursor = min(selected.location, length)
                view.setSelectedRange(NSRange(location: cursor, length: min(selected.length, length - cursor)))
            }
            if let focusRequest, coordinator.focusRequest != focusRequest {
                coordinator.focusRequest = focusRequest
                DispatchQueue.main.async { [weak view, weak coordinator] in
                    guard let view, view.isEditable, coordinator?.focusRequest == focusRequest else { return }
                    view.window?.makeFirstResponder(view)
                }
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
            let width = max(proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 220, 1)
            let font = Self.font
            let line = ceil(font.ascender - font.descender + font.leading)
            let maxHeight = line * 7
            let height: CGFloat
            if text.utf16.prefix(Self.measurementLimit + 1).count > Self.measurementLimit {
                height = maxHeight
            } else {
                let probe = text + " "
                let used = (probe as NSString).boundingRect(
                    with: NSSize(width: max(1, width - 10), height: maxHeight),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                height = min(maxHeight, max(line, ceil(used.height)))
            }
            return CGSize(width: width, height: height + Self.verticalInset * 2)
        }
    }
}

enum MacComposerImageTextImportError: Error {
    case unreadableImage
    case noTextRecognized
    case recognitionFailed(String)
}

/// Local, on-device OCR text import for one explicitly selected composer
/// image. This is the Mac port of the iPad OCR utility policy: the iPad
/// `image.ocr` tool and the Notes importer both run Apple Vision locally,
/// and the iPad platform wrapper itself (the UIKit-gated `OCRTool`) is not
/// portable, so Vision runs here directly. Recognition is auxiliary
/// evidence only: it may be incomplete or wrong, and the imported text is
/// ordinary editable draft text, never instructions.
enum MacComposerImageTextImport {
    /// Mirrors the iPad on-device OCR handoff bound so one full-page photo
    /// cannot flood the composer.
    static let maximumRecognizedCharacters = 12_000

    /// The iPad image.ocr / Notes recognition language policy: Chinese
    /// first (simplified, then traditional), then English, with per-line
    /// automatic detection. The list is intersected with the languages this
    /// device reports so an absent model fails closed to what is supported
    /// instead of breaking recognition entirely.
    static let preferredRecognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    /// Reads and recognizes one staged image. The URL follows the existing
    /// security-scoped draft contract (staging already verified the bookmark);
    /// scoped access is opened only for the duration of the read.
    static func recognizedText(from url: URL) async throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw MacComposerImageTextImportError.unreadableImage
        }
        return try await Task.detached(priority: .userInitiated) {
            try recognizedText(from: data)
        }.value
    }

    /// Pure recognition on encoded image bytes; runs off the main actor.
    /// Lines come back in reading order and the result is bounded.
    static func recognizedText(from data: Data) throws -> String {
        guard !data.isEmpty else { throw MacComposerImageTextImportError.unreadableImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        if let supported = try? request.supportedRecognitionLanguages() {
            let kept = preferredRecognitionLanguages.filter { supported.contains($0) }
            if !kept.isEmpty { request.recognitionLanguages = kept }
        } else {
            request.recognitionLanguages = preferredRecognitionLanguages
        }
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(data: data, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw MacComposerImageTextImportError.recognitionFailed(error.localizedDescription)
        }
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (text, observation.boundingBox)
        }
        .sorted { lhs, rhs in
            // Vision bounding boxes are lower-left origin: smaller minY is
            // higher on the page, so a plain ascending sort reads correctly.
            if abs(lhs.1.minY - rhs.1.minY) > 0.01 { return lhs.1.minY > rhs.1.minY }
            return lhs.1.minX < rhs.1.minX
        }
        .map(\.0)
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { throw MacComposerImageTextImportError.noTextRecognized }
        return String(text.prefix(maximumRecognizedCharacters))
    }
}

/// The staged-attachment strip shared by the inline composer and the
/// expanded composer sheet. Each row keeps the existing chip chrome
/// (preview name + remove) and adds the explicit OCR text-import action
/// for image attachments. Removal stays available while a run is active:
/// staged files bind to the next queued or steered message only when the
/// user submits them, and removing one before submit must always work.
struct MacComposerInputAttachmentStrip: View {
    struct Item: Identifiable {
        let id: UUID
        let name: String
        let isImage: Bool
        let detail: Text?
    }

    let items: [Item]
    /// The item currently being OCR-imported, if any.
    let importingItemID: UUID?
    /// Removal is blocked only for genuinely terminal states (workspace
    /// teardown), never because a run is active.
    let removeDisabled: Bool
    let onRemove: (UUID) -> Void
    let onImportText: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 0) {
                        FloeComposerAttachmentChip(name: item.name,
                                                   systemImage: item.isImage ? "photo" : "doc",
                                                   detail: item.detail,
                                                   removeLabel: String(localized: "mac.workspace.removeAttachment")) {
                            onRemove(item.id)
                        }
                        if item.isImage {
                            if importingItemID == item.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                            } else {
                                Button { onImportText(item.id) } label: {
                                    Image(systemName: "text.viewfinder")
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(importingItemID != nil || removeDisabled)
                                .help(MacComposerInputText.t("导入识别文字", "Import Recognized Text"))
                                .accessibilityLabel(MacComposerInputText.t("导入识别文字", "Import Recognized Text"))
                                .accessibilityIdentifier("composer.attachment.importText.\(item.id.uuidString)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .disabled(removeDisabled)
    }
}
#endif
