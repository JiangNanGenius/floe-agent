//
//  CADVersionsPanelView.swift
//  FloeCADKit
//
//  Native workbench entry for user-named design versions (E34).
//
//  The panel is deliberately a native sheet: explicit name, list, compare,
//  restore and delete. It never presents raw JSON, never hides a corrupt
//  checkpoint, and states the real Undo boundary instead of implying that
//  in-memory undo survives a close/reopen or a restore.
//

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
#if STANDALONE_TYPECHECK
@testable import FloeCAD
#endif

struct CADVersionsPanelView: View {
    private struct ComparisonRecordTarget: Identifiable {
        let id = UUID()
        let section: String
        let identifier: String
    }

    let document: FloeCADDocument

    @Environment(\.dismiss) private var dismiss
    @State private var versions: [CADNamedVersionSummary] = []
    @State private var recoveries: [CADNamedVersionRecoverySummary] = []
    @State private var selectedID: UUID?
    @State private var loading = true
    @State private var busyAction: String?
    @State private var errorMessage: String?
    @State private var outcomeMessage: String?
    @State private var showCreate = false
    @State private var newName = ""
    @State private var comparison: CADNamedVersionComparison?
    @State private var pendingRestore: CADNamedVersionSummary?
    @State private var pendingDelete: CADNamedVersionSummary?
    @State private var pendingDiscardRecovery: CADNamedVersionRecoverySummary?
    @State private var recordTarget: ComparisonRecordTarget?
    @State private var recordDetail: CADNamedVersionRecordDetail?
    @State private var recordError: String?
    @State private var recordBusy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(FloeCADStrings.label(
                        "cad.versions.intro",
                        "Save this design so you can restore it later."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    DisclosureGroup(FloeCADStrings.label(
                        "cad.versions.help.title", "How versions and Undo work")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(FloeCADStrings.label(
                                "cad.versions.help.undo",
                                "Undo and Redo cover edits in this open editing session only. They are not saved, and they do not reach across closing and reopening the document."))
                            Text(FloeCADStrings.label(
                                "cad.versions.help.checkpoint",
                                "Creating a named version saves any pending edits first, then stores one complete checkpoint. It does not add an Undo step and is not an automatic copy of every CAD edit."))
                            Text(FloeCADStrings.label(
                                "cad.versions.help.restore",
                                "Restoring a version starts a new Undo boundary. The document from just before the restore is saved as a recovery version, so you can return to it."))
                            Text(FloeCADStrings.label(
                                "cad.versions.help.contents",
                                "A version includes geometry and B-rep/mesh data, materials and embedded textures, assembly, drawings, presentation and animation state. External part-reference files are not copied or deleted."))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if document.isReadOnly {
                        Label(FloeCADStrings.label(
                            "cad.versions.readOnly",
                            "This document is read-only. You can list and compare versions, but not create, restore or delete them."),
                              systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(FloeCADStrings.label("cad.versions.loading", "Loading versions…"))
                                .foregroundStyle(.secondary)
                        }
                    } else if versions.isEmpty {
                        ContentUnavailableView {
                            Label(FloeCADStrings.label("cad.versions.empty.title", "No design versions yet"),
                                  systemImage: "bookmark")
                        } description: {
                            Text(FloeCADStrings.label(
                                "cad.versions.empty.body",
                                "Save the current design as a new version."))
                        }
                    } else {
                        ForEach(versions) { version in
                            versionRow(version)
                        }
                    }
                } header: {
                    HStack {
                        Text(FloeCADStrings.label("cad.versions.list.title", "Versions"))
                        Spacer()
                        if !versions.isEmpty {
                            Text("\(versions.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !recoveries.isEmpty {
                    Section {
                        Text(FloeCADStrings.label(
                            "cad.versions.recovery.intro",
                            "This version needs recovery before you can use it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(recoveries) { recovery in
                            recoveryRow(recovery)
                        }
                    } header: {
                        HStack {
                            Text(FloeCADStrings.label("cad.versions.recovery.title",
                                                      "Recoverable versions"))
                            Spacer()
                            Text("\(recoveries.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("CADVersionRecoverySection")
                }

                if let selected = versions.first(where: { $0.id == selectedID }) {
                    Section(FloeCADStrings.label("cad.versions.details.title", "Version details")) {
                        details(selected)
                    }
                }

                if let comparison {
                    Section(FloeCADStrings.label("cad.versions.compare.title", "Comparison")) {
                        comparisonView(comparison)
                    }
                }

                if let outcomeMessage {
                    Section {
                        Label(outcomeMessage, systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("CADVersionsOutcome")
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("CADVersionsError")
                    }
                }
            }
            .navigationTitle(FloeCADStrings.label("cad.versions.title", "Design Versions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.done", "Done")) { dismiss() }
                        .accessibilityIdentifier("CADVersionsCloseButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        newName = ""
                        showCreate = true
                    } label: {
                        Label(FloeCADStrings.label("cad.versions.create.short", "New Version"),
                              systemImage: "plus")
                    }
                    .disabled(document.isReadOnly || busyAction != nil || versions.count >= 50)
                    .accessibilityIdentifier("CADVersionCreateButton")
                }
            }
        }
        .accessibilityIdentifier("CADVersionsPanel")
        .task { await reload() }
        .alert(FloeCADStrings.text("cad.versions.create.title", "New Design Version"),
               isPresented: $showCreate) {
            TextField(FloeCADStrings.text("cad.versions.create.name", "Version name"),
                      text: $newName)
                .accessibilityIdentifier("CADVersionNameField")
            Button(FloeCADStrings.text("cad.versions.create.confirm", "Create")) {
                let name = newName
                Task { await create(name) }
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("CADVersionCreateConfirm")
            Button(FloeCADStrings.text("cad.versions.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(document.hasUnsavedChanges
                 ? FloeCADStrings.text(
                    "cad.versions.create.messageDirty",
                    "Save the current changes as a version.")
                 : FloeCADStrings.text(
                    "cad.versions.create.message",
                    "Save the current design as a version."))
        }
        .alert(FloeCADStrings.text("cad.versions.restore.title", "Restore Version?"),
               isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }),
               presenting: pendingRestore) { version in
            Button(FloeCADStrings.text("cad.versions.restore.confirm", "Restore")) {
                pendingRestore = nil
                Task { await restore(version) }
            }
            .accessibilityIdentifier("CADVersionRestoreConfirm")
            Button(FloeCADStrings.text("cad.versions.cancel", "Cancel"), role: .cancel) {
                pendingRestore = nil
            }
        } message: { version in
            Text(FloeCADStrings.format(
                "cad.versions.restore.message",
                "The document will be restored in place from “%@” and a new branch checkpoint will be created. The current design is saved as a recovery version first. Undo history starts fresh; the recovery version is how you go back to the previous design.",
                version.name))
        }
        .alert(FloeCADStrings.text("cad.versions.delete.title", "Delete Version?"),
               isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { version in
            Button(FloeCADStrings.text("cad.versions.delete.confirm", "Delete"), role: .destructive) {
                pendingDelete = nil
                Task { await delete(version) }
            }
            .accessibilityIdentifier("CADVersionDeleteConfirm")
            Button(FloeCADStrings.text("cad.versions.cancel", "Cancel"), role: .cancel) {
                pendingDelete = nil
            }
        } message: { version in
            Text(FloeCADStrings.format(
                "cad.versions.delete.message",
                "This removes only the “%@” checkpoint. The current design and external project files are not changed.",
                version.name))
        }
        .alert(FloeCADStrings.text("cad.versions.recovery.delete.title",
                                   "Delete Recovery?"),
               isPresented: Binding(
                get: { pendingDiscardRecovery != nil },
                set: { if !$0 { pendingDiscardRecovery = nil } }),
               presenting: pendingDiscardRecovery) { recovery in
            Button(FloeCADStrings.text("cad.versions.delete.confirm", "Delete"),
                   role: .destructive) {
                pendingDiscardRecovery = nil
                Task { await discardRecovery(recovery) }
            }
            .accessibilityIdentifier("CADVersionRecoveryDeleteConfirm")
            Button(FloeCADStrings.text("cad.versions.cancel", "Cancel"), role: .cancel) {
                pendingDiscardRecovery = nil
            }
        } message: { recovery in
            Text(FloeCADStrings.format(
                "cad.versions.recovery.delete.message",
                "This removes only the unpublished checkpoint “%@”. The current design, visible versions and external project files are not changed.",
                recovery.name.isEmpty
                    ? FloeCADStrings.text("cad.versions.recovery.unreadable",
                                          "Unreadable checkpoint")
                    : recovery.name))
        }
        .sheet(item: $recordTarget) { target in
            recordSheet(target)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func versionRow(_ version: CADNamedVersionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedID = (selectedID == version.id) ? nil : version.id
                comparison = nil
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.isUsable
                             ? version.name
                             : FloeCADStrings.text("cad.versions.unreadable", "Unreadable version"))
                            .font(.headline)
                        Text(version.isRecovery
                             ? FloeCADStrings.text("cad.versions.badge.recovery", "Recovery")
                             : (version.parentVersionID != nil
                                ? FloeCADStrings.text("cad.versions.badge.branch", "Branch")
                                : FloeCADStrings.text("cad.versions.badge.named", "Named version")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(version.createdAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("CADVersionRow-\(version.id.uuidString)")

            if !version.isUsable {
                Text(version.issue ?? FloeCADStrings.text(
                    "cad.versions.unreadable.detail",
                    "This checkpoint did not pass verification. It cannot be compared or restored, and the current document was not changed."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(summaryLine(version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                panelHitTarget(Button {
                    Task { await compare(version) }
                } label: {
                    Label(FloeCADStrings.label("cad.versions.action.compare", "Compare"),
                          systemImage: "arrow.left.arrow.right")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!version.isUsable || busyAction != nil)
                .accessibilityIdentifier("CADVersionCompare-\(version.id.uuidString)"))

                panelHitTarget(Button {
                    pendingRestore = version
                } label: {
                    Label(FloeCADStrings.label("cad.versions.action.restore", "Restore"),
                          systemImage: "arrow.uturn.backward")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!version.isUsable || document.isReadOnly || busyAction != nil)
                .accessibilityIdentifier("CADVersionRestore-\(version.id.uuidString)"))

                panelHitTarget(Button(role: .destructive) {
                    pendingDelete = version
                } label: {
                    Label(FloeCADStrings.label("cad.versions.action.delete", "Delete"),
                          systemImage: "trash")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(document.isReadOnly || busyAction != nil)
                .accessibilityIdentifier("CADVersionDelete-\(version.id.uuidString)"))

                if busyAction == version.id.uuidString {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func recoveryRow(_ recovery: CADNamedVersionRecoverySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recovery.name.isEmpty || !recovery.isUsable
                         ? FloeCADStrings.text("cad.versions.recovery.unreadable",
                                               "Unreadable checkpoint")
                         : recovery.name)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(recovery.isRecovery
                             ? FloeCADStrings.text("cad.versions.badge.recovery", "Recovery")
                             : FloeCADStrings.text("cad.versions.badge.named", "Named version"))
                        Text(FloeCADStrings.text("cad.versions.recovery.badge", "Recovery needed"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(recovery.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if recovery.isUsable {
                Text(FloeCADStrings.format(
                    "cad.versions.row.summary",
                    "Revision %d · %d bodies · %d features",
                    recovery.sourceRevision,
                    recovery.counts["bodies"] ?? 0,
                    recovery.counts["features"] ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(recovery.issue ?? FloeCADStrings.text(
                    "cad.versions.unreadable.detail",
                    "This checkpoint did not pass verification. It cannot be compared or restored, and the current document was not changed."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(FloeCADStrings.label("cad.versions.recovery.details",
                                                 "Checkpoint details")) {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow(FloeCADStrings.text("cad.versions.details.kind", "Kind"),
                              FloeCADStrings.text("cad.versions.recovery.badge",
                                                  "Recovery needed"))
                    if !recovery.contentSHA256.isEmpty {
                        detailRow(FloeCADStrings.text("cad.versions.details.contentSHA",
                                                      "Content SHA-256"),
                                  recovery.contentSHA256)
                    }
                    if let model = recovery.modelSHA256, !model.isEmpty {
                        detailRow(FloeCADStrings.text("cad.versions.details.modelSHA",
                                                      "Model SHA-256"), model)
                    }
                    detailRow(FloeCADStrings.text("cad.versions.details.schema",
                                                  "Package format"),
                              "\(recovery.schemaVersion)")
                    detailRow(FloeCADStrings.text("cad.versions.recovery.id", "ID"),
                              recovery.id.uuidString)
                }
                .font(.caption)
            }
            .font(.caption)

            HStack(spacing: 8) {
                panelHitTarget(Button {
                    Task { await recover(recovery) }
                } label: {
                    Label(FloeCADStrings.label("cad.versions.recovery.action.recover",
                                               "Recover"),
                          systemImage: "arrow.up.doc")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!recovery.isUsable || document.isReadOnly || busyAction != nil)
                .accessibilityIdentifier("CADVersionRecovery-\(recovery.id.uuidString)"))

                panelHitTarget(Button(role: .destructive) {
                    pendingDiscardRecovery = recovery
                } label: {
                    Label(FloeCADStrings.label("cad.versions.action.delete", "Delete"),
                          systemImage: "trash")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(document.isReadOnly || busyAction != nil)
                .accessibilityIdentifier("CADVersionRecoveryDelete-\(recovery.id.uuidString)"))

                if busyAction == recovery.id.uuidString {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("CADVersionRecoveryRow-\(recovery.id.uuidString)")
    }

    @ViewBuilder
    private func details(_ version: CADNamedVersionSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(FloeCADStrings.text("cad.versions.details.name", "Name"), version.name)
            if version.isRecovery {
                detailRow(FloeCADStrings.text("cad.versions.details.kind", "Kind"),
                          FloeCADStrings.text("cad.versions.badge.recovery", "Recovery"))
            } else if let parent = version.parentVersionID {
                detailRow(FloeCADStrings.text("cad.versions.details.branch", "Branched from"),
                          versions.first { $0.id == parent }?.name
                              ?? String(parent.uuidString.prefix(8)))
            }
            detailRow(FloeCADStrings.text("cad.versions.details.revision", "Source revision"),
                      "\(version.sourceRevision)")
            detailRow(FloeCADStrings.text("cad.versions.details.schema", "Package format"),
                      "\(version.schemaVersion)")
            detailRow(FloeCADStrings.text("cad.versions.details.contents", "Contents"),
                      FloeCADStrings.format(
                        "cad.versions.details.contents.value",
                        "%d bodies · %d features · %d sketches · %d variables",
                        version.counts["bodies"] ?? 0,
                        version.counts["features"] ?? 0,
                        version.counts["sketches"] ?? 0,
                        version.counts["variables"] ?? 0))
            detailRow(FloeCADStrings.text("cad.versions.details.contentSHA", "Content SHA-256"),
                      version.contentSHA256)
            if let model = version.modelSHA256, !model.isEmpty {
                detailRow(FloeCADStrings.text("cad.versions.details.modelSHA", "Model SHA-256"), model)
            }
            Text(FloeCADStrings.label(
                "cad.versions.details.undo",
                "Undo and Redo stay in this open session. A checkpoint is durable; it is not an Undo entry."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func comparisonView(_ comparison: CADNamedVersionComparison) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FloeCADStrings.format(
                "cad.versions.compare.headline",
                "%@ (revision %d) → %@ (revision %d)",
                comparison.from.name, comparison.from.revision,
                comparison.to.name, comparison.to.revision))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                badge(comparison.identical
                      ? FloeCADStrings.text("cad.versions.compare.modelSame", "Model identical")
                      : FloeCADStrings.text("cad.versions.compare.modelDifferent", "Model changed"),
                      color: comparison.identical ? .green : .orange)
                badge(comparison.contentIdentical
                      ? FloeCADStrings.text("cad.versions.compare.contentSame", "Content identical")
                      : FloeCADStrings.text("cad.versions.compare.contentDifferent", "Content changed"),
                      color: comparison.contentIdentical ? .green : .orange)
            }
            if let note = comparison.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if comparison.differences.isEmpty {
                Text(comparison.identical
                     ? FloeCADStrings.label("cad.versions.compare.none", "No differences in stored model data.")
                     : FloeCADStrings.label("cad.versions.compare.valuesOnly",
                                            "The stored digests differ, but no addressable record difference was found."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(comparison.differences.enumerated()), id: \.offset) { _, difference in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(sectionTitle(difference.section))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(difference.change.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(difference.name)
                            .font(.caption.weight(.semibold))
                        Text(difference.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Button {
                            openRecord(difference)
                        } label: {
                            Label(FloeCADStrings.label("cad.versions.compare.record",
                                                       "Stored record"),
                                  systemImage: "doc.text.magnifyingglass")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier(
                            "CADVersionRecord-\(difference.section)-\(difference.identifier)")
                    }
                    .padding(.vertical, 2)
                }
                if comparison.totalDifferences > 0 {
                    Text(comparison.truncated
                         ? FloeCADStrings.format(
                            "cad.versions.compare.page",
                            "Showing %d of %d differences.",
                            comparison.differences.count,
                            comparison.totalDifferences)
                         : FloeCADStrings.format(
                            "cad.versions.compare.all",
                            "All %d differences are shown.",
                            comparison.totalDifferences))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let nextOffset = comparison.nextOffset {
                    Button {
                        Task { await loadMoreComparison(nextOffset) }
                    } label: {
                        Label(FloeCADStrings.label("cad.versions.compare.loadMore",
                                                   "Load more differences"),
                              systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busyAction != nil)
                    .accessibilityIdentifier("CADVersionCompareMore")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CADVersionCompareResult")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func sectionTitle(_ section: String) -> String {
        switch section {
        case "geometry": return FloeCADStrings.text("cad.versions.section.geometry", "Geometry")
        case "features": return FloeCADStrings.text("cad.versions.section.features", "Features")
        case "parameters": return FloeCADStrings.text("cad.versions.section.parameters", "Parameters")
        case "variables": return FloeCADStrings.text("cad.versions.section.variables", "Variables")
        case "materials": return FloeCADStrings.text("cad.versions.section.materials", "Materials")
        case "assembly": return FloeCADStrings.text("cad.versions.section.assembly", "Assembly")
        case "drawings": return FloeCADStrings.text("cad.versions.section.drawings", "Drawings")
        case "presentation": return FloeCADStrings.text("cad.versions.section.presentation", "Presentation")
        case "animation": return FloeCADStrings.text("cad.versions.section.animation", "Animation")
        case "sketches": return FloeCADStrings.text("cad.versions.section.sketches", "Sketches")
        case "planes": return FloeCADStrings.text("cad.versions.section.planes", "Planes")
        case "axes": return FloeCADStrings.text("cad.versions.section.axes", "Axes")
        case "images": return FloeCADStrings.text("cad.versions.section.images", "Images")
        case "symbols": return FloeCADStrings.text("cad.versions.section.symbols", "Symbols")
        case "scripts": return FloeCADStrings.text("cad.versions.section.scripts", "ShapeScript")
        case "preview": return FloeCADStrings.text("cad.versions.section.preview", "Viewport preview")
        default: return FloeCADStrings.text("cad.versions.section.metadata", "Document")
        }
    }

    private func summaryLine(_ version: CADNamedVersionSummary) -> String {
        FloeCADStrings.format(
            "cad.versions.row.summary",
            "Revision %d · %d bodies · %d features",
            version.sourceRevision,
            version.counts["bodies"] ?? 0,
            version.counts["features"] ?? 0)
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            versions = try await document.namedVersions()
            if let selectedID, !versions.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            recoveries = try await document.namedVersionRecoveries()
        } catch {
            recoveries = []
            errorMessage = error.localizedDescription
        }
    }

    private func create(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busyAction = "create"
        errorMessage = nil
        outcomeMessage = nil
        do {
            let result = try await document.createNamedVersion(name: trimmed)
            selectedID = result.version.id
            comparison = nil
            outcomeMessage = result.savedCurrentDocument
                ? FloeCADStrings.format(
                    "cad.versions.outcome.createdSaved",
                    "Created “%@” at revision %d. Pending edits were saved first.",
                    result.version.name, result.revision)
                : FloeCADStrings.format(
                    "cad.versions.outcome.created",
                    "Created “%@” at revision %d.",
                    result.version.name, result.revision)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        busyAction = nil
    }

    private func compare(_ version: CADNamedVersionSummary) async {
        guard version.isUsable else { return }
        busyAction = version.id.uuidString
        errorMessage = nil
        outcomeMessage = nil
        do {
            comparison = try await document.compareNamedVersion(version.id)
            selectedID = version.id
        } catch {
            errorMessage = error.localizedDescription
        }
        busyAction = nil
    }

    private func restore(_ version: CADNamedVersionSummary) async {
        busyAction = version.id.uuidString
        errorMessage = nil
        outcomeMessage = nil
        do {
            let result = try await document.restoreNamedVersion(
                version.id, createBranch: true)
            if result.alreadyCurrent {
                outcomeMessage = FloeCADStrings.format(
                    "cad.versions.outcome.alreadyCurrent",
                    "“%@” is already the current design.", version.name)
            } else if let branch = result.branchVersion {
                outcomeMessage = FloeCADStrings.format(
                    "cad.versions.outcome.restoredBranch",
                    "Restored “%@” at revision %d and created the branch checkpoint “%@”. The previous design is saved as a recovery version.",
                    version.name, result.revision, branch.name)
            } else {
                outcomeMessage = FloeCADStrings.format(
                    "cad.versions.outcome.restored",
                    "Restored “%@” at revision %d. The previous design is saved as a recovery version.",
                    version.name, result.revision)
                if let issue = result.branchIssue {
                    errorMessage = FloeCADStrings.format(
                        "cad.versions.error.branch",
                        "The design was restored, but its branch checkpoint could not be created: %@",
                        issue)
                }
            }
            comparison = nil
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        busyAction = nil
    }

    private func delete(_ version: CADNamedVersionSummary) async {
        busyAction = version.id.uuidString
        errorMessage = nil
        outcomeMessage = nil
        do {
            let result = try await document.deleteNamedVersion(version.id)
            if let issue = result.cleanupIssue {
                errorMessage = FloeCADStrings.format(
                    "cad.versions.error.cleanup",
                    "The version was removed from the list, but its files could not be fully deleted: %@",
                    issue)
            } else {
                outcomeMessage = FloeCADStrings.format(
                    "cad.versions.outcome.deleted",
                    "Deleted the “%@” checkpoint. The current design was not changed.",
                    version.name.isEmpty ? version.id.uuidString : version.name)
            }
            if selectedID == version.id { selectedID = nil }
            if comparison?.from.versionID == version.id || comparison?.to.versionID == version.id {
                comparison = nil
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        busyAction = nil
    }

    private func loadMoreComparison(_ offset: Int) async {
        guard var current = comparison,
              let versionID = current.from.versionID else { return }
        busyAction = "compare-more"
        errorMessage = nil
        do {
            let pins = CADNamedVersionComparisonPins(from: current.from,
                                                     to: current.to)
            let page = try await document.compareNamedVersion(
                versionID, against: current.to.versionID, offset: offset, pins: pins)
            current.differences += page.differences
            current.changedSections = Array(
                Set(current.changedSections + page.changedSections)).sorted()
            current.truncated = page.truncated
            current.totalDifferences = page.totalDifferences
            current.nextOffset = page.nextOffset
            comparison = current
        } catch {
            errorMessage = error.localizedDescription
        }
        busyAction = nil
    }

    // MARK: - Exact stored record (comparison detail)

    @ViewBuilder
    private func recordSheet(_ target: ComparisonRecordTarget) -> some View {
        NavigationStack {
            List {
                if let detail = recordDetail {
                    Section {
                        recordSideView(detail.fromRecord)
                    } header: {
                        Text(FloeCADStrings.label("cad.versions.record.before", "Before"))
                    }
                    Section {
                        recordSideView(detail.toRecord)
                    } header: {
                        Text(FloeCADStrings.label("cad.versions.record.after", "After"))
                    }
                    if let note = detail.note {
                        Section {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if detail.fromRecord.nextChunkOffset != nil
                        || detail.toRecord.nextChunkOffset != nil {
                        Section {
                            Button {
                                Task { await loadMoreRecord(target) }
                            } label: {
                                Label(FloeCADStrings.label(
                                    "cad.versions.record.loadMore",
                                    "Load more record data"),
                                      systemImage: "ellipsis.circle")
                            }
                            .disabled(recordBusy)
                            .accessibilityIdentifier("CADVersionRecordLoadMore")
                        }
                    }
                } else if recordBusy {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(FloeCADStrings.label("cad.versions.record.loading",
                                                      "Loading stored record…"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let recordError {
                    Section {
                        Text(recordError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(FloeCADStrings.label("cad.versions.record.title",
                                                  "Stored record"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.label("cad.ui.common.done", "Done")) {
                        recordTarget = nil
                    }
                    .accessibilityIdentifier("CADVersionRecordCloseButton")
                }
            }
            .task { await loadRecord(target) }
        }
        .accessibilityIdentifier("CADVersionRecordSheet")
    }

    @ViewBuilder
    private func recordSideView(_ side: CADNamedVersionRecordSide) -> some View {
        if side.present {
            Text(side.chunks.joined())
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(FloeCADStrings.label("cad.versions.record.absent",
                                      "This record is absent on this side."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func openRecord(_ difference: CADNamedVersionDifference) {
        recordDetail = nil
        recordError = nil
        recordTarget = ComparisonRecordTarget(section: difference.section,
                                              identifier: difference.identifier)
    }

    private func loadRecord(_ target: ComparisonRecordTarget) async {
        guard let comparison,
              let versionID = comparison.from.versionID else {
            recordError = errorMessage
                ?? FloeCADStrings.text("cad.versions.record.unavailable",
                                       "The comparison is no longer available.")
            return
        }
        recordBusy = true
        recordError = nil
        do {
            let pins = CADNamedVersionComparisonPins(from: comparison.from,
                                                     to: comparison.to)
            recordDetail = try await document.namedVersionRecordDetail(
                versionID, against: comparison.to.versionID,
                section: target.section, identifier: target.identifier,
                chunkLimit: 16, pins: pins)
        } catch {
            recordError = error.localizedDescription
        }
        recordBusy = false
    }

    private func loadMoreRecord(_ target: ComparisonRecordTarget) async {
        guard let comparison,
              let versionID = comparison.from.versionID,
              var detail = recordDetail else { return }
        guard let offset = detail.fromRecord.nextChunkOffset
                ?? detail.toRecord.nextChunkOffset else { return }
        recordBusy = true
        recordError = nil
        do {
            let pins = CADNamedVersionComparisonPins(from: comparison.from,
                                                     to: comparison.to)
            let page = try await document.namedVersionRecordDetail(
                versionID, against: comparison.to.versionID,
                section: target.section, identifier: target.identifier,
                chunkOffset: offset, chunkLimit: 16, pins: pins)
            detail.fromRecord.chunks += page.fromRecord.chunks
            detail.fromRecord.nextChunkOffset = page.fromRecord.nextChunkOffset
            detail.toRecord.chunks += page.toRecord.chunks
            detail.toRecord.nextChunkOffset = page.toRecord.nextChunkOffset
            detail.chunkOffset = page.chunkOffset
            recordDetail = detail
        } catch {
            recordError = error.localizedDescription
        }
        recordBusy = false
    }

    private func recover(_ recovery: CADNamedVersionRecoverySummary) async {
        guard recovery.isUsable else { return }
        busyAction = recovery.id.uuidString
        errorMessage = nil
        outcomeMessage = nil
        do {
            let result = try await document.recoverNamedVersion(recovery.id)
            selectedID = result.version.id
            comparison = nil
            outcomeMessage = FloeCADStrings.format(
                "cad.versions.recovery.outcome.recovered",
                "Recovered “%@” as a version at revision %d.",
                result.version.name, result.revision)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
        busyAction = nil
    }

    private func discardRecovery(_ recovery: CADNamedVersionRecoverySummary) async {
        busyAction = recovery.id.uuidString
        errorMessage = nil
        outcomeMessage = nil
        do {
            let result = try await document.discardNamedVersionRecovery(recovery.id)
            if let issue = result.cleanupIssue {
                errorMessage = FloeCADStrings.format(
                    "cad.versions.error.cleanup",
                    "The version was removed from the list, but its files could not be fully deleted: %@",
                    issue)
            } else {
                outcomeMessage = FloeCADStrings.format(
                    "cad.versions.outcome.deleted",
                    "Deleted the “%@” checkpoint. The current design was not changed.",
                    recovery.name.isEmpty ? recovery.id.uuidString : recovery.name)
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        busyAction = nil
    }
}
#endif
