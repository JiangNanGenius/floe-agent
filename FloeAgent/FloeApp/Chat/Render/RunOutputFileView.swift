// FloeApp — Receipt-backed run output file card.
//
// SPDX-License-Identifier: MPL-2.0
//
// The S3-D transport already seals a `RunOutputFile` receipt to the real
// run/call/tool and freezes its bytes under `RunOutputs/`. This view is the
// in-surface delivery for those receipts: a tool result stays findable after
// the diagnostic details collapse, and the row only becomes actionable after
// `RunOutputSnapshotStore` re-verifies the canonical snapshot (containment,
// plain file, exact size, streaming SHA-256) — never by trusting a path from
// tool text.
//
// Ownership: the card receives only the completion-critical tool-result
// payload it belongs to. It filters receipts by the event's own run, the
// persisted call id and tool name, and the runtime-sealed task binding
// (conversation). A receipt from another run/call/tool/task is never shown;
// global Get Run Files keeps its own, stricter notes/temporary exclusion.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeModels
import FloeTools

/// The trusted identity of the tool-result row that carries the receipts.
/// Values come from the persisted event envelope, never from model text.
struct RunOutputReceiptContext: Sendable, Hashable {
    /// The event's persisted run identity.
    var runID: UUID
    /// The owning conversation, when the surface can prove it. ThreadEventView
    /// may not know it; nil then relies on the runtime-sealed non-nil taskID.
    var conversationID: UUID?
    /// Persisted provider call id (`payload["id"]`).
    var callID: String?
    /// Persisted tool name (`payload["tool"]`).
    var toolName: String?
}

/// Pure ownership gate for receipts rendered inside one tool-result row.
/// Kept separate from the view so the focused tests can exercise the exact
/// production predicate without rendering SwiftUI.
enum RunOutputReceiptGate {
    static func accepts(_ receipt: RunOutputFile, in context: RunOutputReceiptContext) -> Bool {
        guard receipt.role == .userFile,
              receipt.runID == context.runID,
              let callID = context.callID, !callID.isEmpty,
              let toolName = context.toolName, !toolName.isEmpty,
              receipt.producerCallID == callID,
              receipt.producerTool == toolName,
              // The runtime seal always writes the run's real task binding and
              // rejects a receipt that claims a different one. A missing task
              // is never adopted here.
              let taskID = receipt.taskID,
              // Canonical path for its own identity + stable identity derived
              // from (runID, callID, slot). A copied/foreign receipt fails.
              receipt.isCanonicalForCurrentRun,
              receipt.hasRuntimeConsistentIdentity else { return false }
        if let conversationID = context.conversationID, taskID != conversationID { return false }
        return true
    }

    static func accepted(_ receipts: [RunOutputFile],
                         in context: RunOutputReceiptContext) -> [RunOutputFile] {
        receipts.filter { accepts($0, in: context) }
    }
}

/// A compact list of verified run-owned files for one tool result. Rows are
/// intentionally independent of `isExpanded`: the result stays reachable
/// even when the tool's diagnostic evidence is collapsed.
struct RunOutputFilesCard: View {
    let receipts: [RunOutputFile]
    let context: RunOutputReceiptContext

    var body: some View {
        let accepted = RunOutputReceiptGate.accepted(receipts, in: context)
        if !accepted.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(accepted) { receipt in
                    RunOutputFileView(receipt: receipt, context: context)
                }
            }
        }
    }
}

/// One receipt row with a bounded inline bitmap when available. Thumbnail
/// verification is independent of the fresh check on every preview/share.
struct RunOutputFileView: View {
    let receipt: RunOutputFile
    let context: RunOutputReceiptContext
    /// Test seam only: production resolves the real artifact root.
    var artifactRoot: URL? = nil

    @State private var state: VerificationState = .unverified
    @State private var pendingAction: PendingAction?
    @State private var presentation: Presentation?
    @State private var verificationGeneration = 0
    @State private var imagePreview: InlinePreview?

    private struct InlinePreview {
        let request: RunOutputImagePreviewRequest
        let image: UIImage
    }

    private var imageRequest: RunOutputImagePreviewRequest {
        RunOutputImagePreviewRequest(receipt: receipt, context: context, artifactRoot: artifactRoot)
    }

    private struct ActionVerificationID: Hashable {
        let request: RunOutputImagePreviewRequest
        let generation: Int
    }

    private enum VerificationState: Equatable {
        case unverified
        case verifying
        case verified(URL)
        case failed
    }

    private enum PendingAction {
        case preview
        case share
    }

    private struct Presentation: Identifiable {
        enum Kind { case preview, share }
        let id = UUID()
        let url: URL
        let kind: Kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imagePreview, imagePreview.request == imageRequest {
                Button { activate(.preview) } label: {
                    Image(uiImage: imagePreview.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 250, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ChatBilingualCatalog.localized(
                    key: "chat.run_output_file_view.preview",
                    en: "Preview \(receipt.displayName)",
                    zh: "预览 \(receipt.displayName)")))
            }
            fileRow
        }
        .task(id: imageRequest) {
            let request = imageRequest
            imagePreview = nil
            let preview = await RunOutputImagePreviewLoader.load(request)
            guard !Task.isCancelled, request == imageRequest else { return }
            if let preview, let image = UIImage(data: preview.pngData) {
                imagePreview = InlinePreview(request: preview.request, image: image)
            }
        }
        .onChange(of: imageRequest) { _, _ in
            state = .unverified
            pendingAction = nil
            presentation = nil
        }
        .task(id: ActionVerificationID(request: imageRequest, generation: verificationGeneration)) {
            guard pendingAction != nil else { return }
            await verify()
        }
        .sheet(item: $presentation) { item in
            switch item.kind {
            case .preview:
                NavigationStack {
                    QuickLookView(url: item.url)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(receipt.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                if receipt.mimeType.hasPrefix("image/") {
                                    SaveImageToPhotosButton(imageURL: item.url, expectedSHA256: receipt.sha256)
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("workspace.workspace_canvas_view.done") { presentation = nil }
                                    .frame(minHeight: FloeTheme.minimumTarget)
                            }
                        }
                }
            case .share:
                RunOutputShareSheet(url: item.url)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(FloeTheme.primary)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: Int64(receipt.byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            actions
        }
        .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .verifying:
            ProgressView()
                .controlSize(.small)
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(ChatBilingualCatalog.localized(
                    key: "chat.run_output_file_view.verifying",
                    en: "Verifying file", zh: "正在验证文件")))
        case .unverified, .verified(_):
            HStack(spacing: 4) {
                Button {
                    activate(.preview)
                } label: {
                    Image(systemName: "eye")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ChatBilingualCatalog.localized(
                    key: "chat.run_output_file_view.preview",
                    en: "Preview \(receipt.displayName)",
                    zh: "预览 \(receipt.displayName)")))
                Button {
                    activate(.share)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ChatBilingualCatalog.localized(
                    key: "chat.run_output_file_view.share",
                    en: "Share \(receipt.displayName)",
                    zh: "分享 \(receipt.displayName)")))
            }
            .font(.body)
            .foregroundStyle(FloeTheme.primary)
        case .failed:
            Button {
                state = .verifying
                pendingAction = .preview
                verificationGeneration &+= 1
            } label: {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(FloeTheme.destructive)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ChatBilingualCatalog.localized(
                key: "chat.run_output_file_view.retry",
                en: "File unavailable; verify again",
                zh: "文件不可用，重新验证")))
        }
    }

    private func activate(_ action: PendingAction) {
        pendingAction = action
        state = .verifying
        verificationGeneration &+= 1
    }

    @MainActor
    private func verify() async {
        let request = imageRequest
        let generation = verificationGeneration
        guard RunOutputReceiptGate.accepts(request.receipt, in: request.context) else {
            state = .failed
            pendingAction = nil
            return
        }
        let verification = await Task.detached(priority: .utility) {
            RunOutputSnapshotStore.verify(request.receipt, artifactRoot: request.artifactRoot)
        }.value
        guard !Task.isCancelled, request == imageRequest,
              generation == verificationGeneration else { return }
        switch verification {
        case .verified(let url):
            state = .verified(url)
            if let action = pendingAction {
                pendingAction = nil
                present(action, url: url)
            }
        case .missing, .changed, .oversized, .rejected:
            state = .failed
            pendingAction = nil
        }
    }

    private func present(_ action: PendingAction, url: URL) {
        switch action {
        case .preview:
            presentation = Presentation(url: url, kind: .preview)
        case .share:
            presentation = Presentation(url: url, kind: .share)
        }
    }

    private var symbolName: String {
        switch receipt.mimeType {
        case "application/pdf": return "doc.richtext"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "doc.text"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "tablecells"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "rectangle.on.rectangle"
        case "text/markdown", "text/plain": return "doc.plaintext"
        case "application/zip": return "archivebox"
        case let type where type.hasPrefix("image/"): return "photo"
        case let type where type.hasPrefix("audio/"): return "waveform"
        case let type where type.hasPrefix("video/"): return "film"
        default: return "doc"
        }
    }
}
private struct RunOutputShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
