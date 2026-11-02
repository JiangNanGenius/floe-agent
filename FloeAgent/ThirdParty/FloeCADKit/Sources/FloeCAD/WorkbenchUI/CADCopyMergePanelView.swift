#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
#if STANDALONE_TYPECHECK
@testable import FloeCAD
#endif

/// Local state owns a read-only comparison. Applying goes through the live
/// document's existing rebuild, one Undo command and revision-checked save.
@MainActor
struct CADCopyMergePanelView: View {
    let document: FloeCADDocument
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [CADNamedVersionSummary] = []
    @State private var baseID: UUID?
    @State private var source: URL?
    @State private var showPicker = false
    @State private var review: CADTwoCopyMergeReview?
    @State private var resolutions: [String: String] = [:]
    @State private var busy = false
    @State private var applying = false
    @State private var error: String?
    @State private var comparisonTask: Task<Void, Never>?

    private func text(_ key: String, _ fallback: String) -> String {
        FloeCADStrings.text("cad.merge.\(key)", fallback)
    }

    private var canApply: Bool {
        guard let review else { return false }
        return !busy && review.unsupportedIDs.isEmpty
            && review.conflictIDs.allSatisfy { resolutions[$0] != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(text("intro", "Compare two copies from a shared design version, then choose what to merge."))
                        .font(.callout).foregroundStyle(.secondary)
                    Picker(text("base", "Shared starting version"), selection: $baseID) {
                        Text(text("chooseVersion", "Choose a version")).tag(UUID?.none)
                        ForEach(versions.filter(\.isUsable)) { version in
                            Text(version.name).tag(Optional(version.id))
                        }
                    }
                    .disabled(busy || review != nil)
                    .accessibilityIdentifier("CADMergeBasePicker")
                    Button { showPicker = true } label: {
                        LabeledContent(text("other", "Other copy"), value: source?.lastPathComponent ?? text("chooseCopy", "Choose a copy"))
                    }
                    .disabled(busy || review != nil)
                    .accessibilityIdentifier("CADMergeSourcePicker")
                    if versions.isEmpty {
                        Text(text("needVersion", "Create a design version before making separate copies."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if document.hasUnsavedChanges {
                        Text(text("saveFirst", "Save your changes before comparing copies."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button(text("compare", "Compare Copies")) { compare() }
                        .disabled(busy || baseID == nil || source == nil || document.hasUnsavedChanges || review != nil)
                        .accessibilityIdentifier("CADMergeCompareButton")
                }
                if busy { ProgressView().accessibilityIdentifier("CADMergeProgress") }
                if let review {
                    Section(text("changes", "Changes")) {
                        if review.rows.isEmpty {
                            Text(text("noChanges", "There are no changes to merge."))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(review.rows) { row in rowView(row) }
                    }
                    if !review.unsupportedIDs.isEmpty {
                        Section {
                            Label(text("unsupported", "These changes cannot be merged yet."), systemImage: "exclamationmark.triangle")
                                .font(.callout)
                            Text(text("keepCopies", "Both copies are unchanged. Keep them separate to preserve these edits."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button(text("compareAgain", "Compare Again")) { clearReview() }
                            .disabled(busy)
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.callout)
                            .accessibilityIdentifier("CADMergeError")
                    }
                }
            }
            .navigationTitle(text("title", "Merge Design Copies"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("cancel", "Cancel")) { clearReview(); dismiss() }
                        .disabled(applying)
                        .accessibilityIdentifier("CADMergeCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text("apply", "Merge")) { apply() }
                        .disabled(!canApply)
                        .accessibilityIdentifier("CADMergeApplyButton")
                }
            }
        }
        .accessibilityIdentifier("CADCopyMergePanel")
        .interactiveDismissDisabled(applying)
        .task {
            do { versions = try await document.namedVersions() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item, .folder], allowsMultipleSelection: false) { result in
            do { source = try result.get().first; error = nil }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear {
            comparisonTask?.cancel()
            if let review { document.cancelCopyMerge(planID: review.id) }
        }
    }

    @ViewBuilder
    private func rowView(_ row: CADTwoCopyMergeRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name).font(.headline)
            Text(status(row.status)).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(text("details", "Details")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text("current", "Current copy")).font(.caption).foregroundStyle(.secondary)
                    Text(row.current).font(.callout).textSelection(.enabled)
                    Text(text("incoming", "Other copy")).font(.caption).foregroundStyle(.secondary)
                    Text(row.incoming).font(.callout).textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if row.status == "conflict" {
                Picker(text("use", "Use"), selection: Binding(
                    get: { resolutions[row.id] ?? "" },
                    set: { resolutions[row.id] = $0.isEmpty ? nil : $0 })) {
                    Text(text("chooseResolution", "Choose a copy")).tag("")
                    Text(text("current", "Current copy")).tag("current")
                    Text(text("incoming", "Other copy")).tag("incoming")
                }
                .pickerStyle(.menu)
                .disabled(busy)
                .accessibilityIdentifier("CADMergeResolution-\(row.id)")
            }
        }
        .padding(.vertical, 4)
    }

    private func status(_ value: String) -> String {
        switch value {
        case "current": return text("onlyCurrent", "Changed in the current copy")
        case "incoming": return text("onlyIncoming", "Changed in the other copy")
        case "same": return text("sameChange", "The same change in both copies")
        case "conflict": return text("conflict", "Choose which change to keep")
        default: return text("unsupported", "These changes cannot be merged yet.")
        }
    }

    private func clearReview() {
        comparisonTask?.cancel()
        comparisonTask = nil
        if let review { document.cancelCopyMerge(planID: review.id) }
        review = nil; resolutions = [:]; error = nil
    }

    private func compare() {
        guard let source, let baseID else { return }
        busy = true; error = nil
        comparisonTask = Task { @MainActor in
            defer { busy = false }
            do {
                let value = try await document.compareCopy(at: source, baseVersionID: baseID)
                if Task.isCancelled { document.cancelCopyMerge(planID: value.id); return }
                review = value
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func apply() {
        guard let review, canApply else { return }
        busy = true; applying = true; error = nil
        Task { @MainActor in
            defer { busy = false; applying = false }
            do {
                _ = try await document.mergeCopy(planID: review.id, resolutions: resolutions)
                self.review = nil
                dismiss()
            } catch {
                self.error = error.localizedDescription
                // Failed or stale plans cannot be replayed accidentally. The
                // user can compare again; the service owns exact rollback.
                document.cancelCopyMerge(planID: review.id)
                self.review = nil
            }
        }
    }
}
#endif
