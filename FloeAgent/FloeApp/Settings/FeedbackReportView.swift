// FloeApp — User-authored feedback plus explicit diagnostics consent.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import UIKit
import FloeCore

struct FeedbackReportView: View {
    @ObservedObject var center: SettingsCenter
    @Environment(\.dismiss) private var dismiss
    @State private var problem = ""
    @State private var includesDiagnostics = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submittedID: String?
    @State private var copiedReference = false
    @State private var pendingPackageURL: URL?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var imageAttachments: [FeedbackImageAttachment] = []
    @State private var isLoadingImages = false
    /// Reuse one client id across retries so the server can de-duplicate the
    /// same report instead of treating every tap as a new upload.
    @State private var submissionID = UUID()
    @State private var retryAvailableAt: Date?

    private var trimmedProblem: String {
        problem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let submittedID {
                ContentUnavailableView {
                    Label("feedback.success.title", systemImage: "checkmark.circle")
                } description: {
                    VStack(spacing: 6) {
                        Text("feedback.success.reference")
                        Text(verbatim: submittedID)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("feedback.reference")
                    }
                } actions: {
                    Button {
                        UIPasteboard.general.string = submittedID
                        copiedReference = true
                    } label: {
                        if copiedReference {
                            Label("action.copied", systemImage: "checkmark")
                        } else {
                            Label("action.copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            } else {
                reportForm.disabled(isSubmitting)
            }
        }
        .navigationTitle(FloeL10n.l("feedback.title"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSubmitting)
        .toolbar {
            if submittedID != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                        .accessibilityIdentifier("feedback.done")
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("feedback.submit")
                        }
                    }
                    .disabled(
                        isSubmitting
                            || trimmedProblem.isEmpty
                            || problem.count > FeedbackUploadService.maximumProblemCharacters
                            || isLoadingImages
                            || retryAvailableAt.map { Date() < $0 } == true
                    )
                    .accessibilityIdentifier("feedback.submit")
                }
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            Task { await loadImages(items) }
        }
    }

    private var reportForm: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if problem.isEmpty {
                        Text("feedback.problem.placeholder")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $problem)
                        .frame(minHeight: 150)
                        .accessibilityIdentifier("feedback.problem")
                }
                Text("\(problem.count)/\(FeedbackUploadService.maximumProblemCharacters)")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(
                        problem.count > FeedbackUploadService.maximumProblemCharacters
                            ? FloeTheme.destructive : .secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } header: {
                Text("feedback.problem.title")
            } footer: {
                Text("feedback.problem.footer")
            }

            Section {
                Toggle("feedback.logs.include", isOn: $includesDiagnostics)
                    .accessibilityIdentifier("feedback.include_diagnostics")
                if includesDiagnostics {
                    Label("feedback.logs.redacted", systemImage: "lock.shield")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("feedback.logs.title")
            } footer: {
                Text("feedback.logs.footer")
            }

            Section {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: FeedbackUploadService.maximumImageCount,
                    matching: .images
                ) {
                    Label("feedback.images.add", systemImage: "photo.badge.plus")
                }
                .disabled(isSubmitting || isLoadingImages)
                .accessibilityIdentifier("feedback.add_images")

                ForEach(imageAttachments) { attachment in
                    HStack(spacing: 12) {
                        if let image = UIImage(data: attachment.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.filename)
                                .lineLimit(1)
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(attachment.data.count),
                                countStyle: .file
                            ))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            imageAttachments.removeAll { $0.id == attachment.id }
                            selectedPhotoItems = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .accessibilityLabel("feedback.images.remove")
                    }
                }
                if isLoadingImages {
                    HStack {
                        ProgressView()
                        Text("feedback.images.processing")
                    }
                }
            } header: {
                Text("feedback.images.title")
            } footer: {
                Text("feedback.images.footer")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(FloeTheme.destructive)
                    if let pendingPackageURL {
                        ShareLink(item: pendingPackageURL) {
                            Label("Export saved report", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    private func submit() async {
        guard !isSubmitting, submittedID == nil else { return }
        isSubmitting = true
        errorMessage = nil
        pendingPackageURL = nil
        defer { isSubmitting = false }

        let diagnostics: String?
        if includesDiagnostics {
            diagnostics = SecretRedactor.redact(await DiagnosticsExporter.render(center: center))
        } else {
            diagnostics = nil
        }

        let submission = FeedbackSubmission(
            id: submissionID,
            problem: trimmedProblem,
            diagnostics: diagnostics,
            imageAttachments: imageAttachments
        )
        do {
            let receipt = try await FeedbackUploadService.upload(submission)
            PendingFeedbackReportStore.remove(id: submission.id)
            submittedID = receipt.reportID
        } catch {
            errorMessage = error.localizedDescription
            if let uploadError = error as? FeedbackUploadError,
               case .rateLimited(let seconds) = uploadError,
               let seconds {
                retryAvailableAt = Date().addingTimeInterval(TimeInterval(seconds))
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    retryAvailableAt = nil
                }
            }
            pendingPackageURL = try? PendingFeedbackReportStore.save(submission)
        }
    }

    @MainActor
    private func loadImages(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isLoadingImages = true
        errorMessage = nil
        defer { isLoadingImages = false }
        do {
            var processed: [FeedbackImageAttachment] = []
            for (index, item) in items.prefix(FeedbackUploadService.maximumImageCount).enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw FeedbackUploadError.invalidImage
                }
                processed.append(try FeedbackImageProcessor.makeAttachment(data: data, index: index))
            }
            guard processed.reduce(0, { $0 + $1.data.count })
                    <= FeedbackUploadService.maximumTotalImageBytes else {
                throw FeedbackUploadError.imageTooLarge
            }
            imageAttachments = processed
        } catch {
            imageAttachments = []
            selectedPhotoItems = []
            errorMessage = error.localizedDescription
        }
    }
}
#endif
