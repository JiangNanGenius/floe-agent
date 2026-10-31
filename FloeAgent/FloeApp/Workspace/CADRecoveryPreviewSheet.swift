// SPDX-License-Identifier: MPL-2.0
// FloeApp — E33 non-mutating recovery preview for a damaged `.floecad`
// package.
//
// The sheet is shown BEFORE any automatic previous-commit promotion. It only
// describes the verified facts the FloeCAD store produced; "Restore a Copy"
// asks the caller to create the atomic new package and open it. Nothing in
// this view writes to the damaged package, and a changed source makes the
// caller refuse rather than apply a stale preview.
//
// iPad first: a bounded reading column on regular width, grouped sections and
// natural system controls. English/Chinese copy lives in the app catalog; the
// internal hashes and parser details stay inside the Details disclosure.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeCore

/// One presentation of the recovery sheet. `.decision` offers Restore a Copy;
/// `.report` is the same truthful report reopened after a copy was created.
enum CADRecoverySheet: Identifiable {
    case decision(CADRecoveryPreview)
    case report(CADRecoveryPreview)

    var preview: CADRecoveryPreview {
        switch self {
        case .decision(let preview), .report(let preview): return preview
        }
    }

    var id: String {
        switch self {
        case .decision(let preview): return "decision.\(preview.id)"
        case .report(let preview): return "report.\(preview.id)"
        }
    }
}

/// A recovered package that exists but could not be opened. Carries the exact
/// localized explanation so the sheet can distinguish "copy created, open
/// failed" from "copy refused".
struct CADRecoveryOpenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CADRecoveryPreviewSheet: View {
    enum Mode { case decide, report }

    let preview: CADRecoveryPreview
    let mode: Mode
    /// Nil in report mode. The caller performs the CAS-checked atomic copy and
    /// opens the new package before calling `onRestored`. The caller also
    /// records the copy when the presentation is canceled after the atomic
    /// step; `onRestored` is never used as a substitute for that record.
    var restore: (() async throws -> CADRecoveryRestoreResult)?
    var onRestored: (CADRecoveryRestoreResult) -> Void
    var onClose: () -> Void
    var onRefresh: (() -> Void)? = nil

    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var sourceChanged = false
    /// The one in-flight atomic restore. Dismissing the sheet cancels the
    /// PRESENTATION, not the atomic step: the caller records the honest
    /// "copied" outcome, and a late result is never forwarded to a view that
    /// moved on.
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("cad.recovery.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    previousCard
                    damagedCard
                    ForEach(CADRecoveryRowKind.allCases, id: \.self) { kind in
                        let rows = preview.report.rows.filter { $0.kind == kind }
                        if !rows.isEmpty { rowSection(kind: kind, rows: rows) }
                    }
                    if !preview.report.notices.isEmpty { noticesCard }
                    if let errorMessage { errorCard(errorMessage) }
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(Text("cad.recovery.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(mode == .decide
                           ? FloeL10n.l("cad.recovery.action.cancel")
                           : FloeL10n.l("cad.recovery.action.done")) {
                        onClose()
                    }
                    .disabled(isRestoring)
                    .accessibilityIdentifier("cad.recovery.closeButton")
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .accessibilityIdentifier("cad.recovery.sheet")
        .interactiveDismissDisabled(isRestoring)
        .onDisappear {
            restoreTask?.cancel()
            restoreTask = nil
        }
    }

    // MARK: Previous verified save

    private var previousCard: some View {
        card {
            sectionHeader("cad.recovery.section.previous")
            if let data = preview.previewImage, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("cad.recovery.previewImage")
                    .accessibilityLabel(Text("cad.recovery.previewImage.caption"))
                Text("cad.recovery.previewImage.caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if preview.previewImage != nil {
                Text("cad.recovery.previewImage.unreadable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: preview.previous.name)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(verbatim: FloeL10n.l("cad.recovery.revision", preview.previous.revision))
                Text(verbatim: "·")
                Text(verbatim: dateText(preview.previous.modifiedAt))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if preview.previousOpensReadOnly {
                Label {
                    Text("cad.recovery.item.readOnly")
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("cad.recovery.readOnly")
            }
            diagnostics
        }
        .accessibilityIdentifier("cad.recovery.previous.section")
    }

    private var diagnostics: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                diagnosticLine("cad.recovery.details.content", preview.previous.contentSHA256)
                if let model = preview.previous.modelSHA256 {
                    diagnosticLine("cad.recovery.details.model", model)
                }
                diagnosticLine("cad.recovery.details.schema",
                               "\(preview.previous.schemaVersion)")
                diagnosticLine("cad.recovery.details.appBuild", preview.previous.appBuild)
                diagnosticLine("cad.recovery.details.fingerprint",
                               preview.sourceFingerprint)
                if let detail = preview.damage.diagnosticDetail, !detail.isEmpty {
                    diagnosticLine("cad.recovery.details.damage", detail)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("cad.recovery.action.details")
                .font(.subheadline)
        }
        .accessibilityIdentifier("cad.recovery.details")
    }

    private func diagnosticLine(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(key))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Damaged package

    private var damagedCard: some View {
        card {
            sectionHeader("cad.recovery.section.damaged")
            Text(verbatim: damageText)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let revision = preview.currentRevisionClaim {
                HStack(spacing: 6) {
                    Text(verbatim: FloeL10n.l("cad.recovery.revision", revision))
                    Text(verbatim: "·")
                    Text("cad.recovery.current.unverified")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if let modified = preview.currentModifiedAtClaim {
                Text(verbatim: dateText(modified))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let counts = preview.currentReportedCounts,
               !reportedCountsText(counts).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: reportedCountsText(counts))
                        .font(.subheadline)
                    Text("cad.recovery.current.reported")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("cad.recovery.damaged.section")
    }

    // MARK: Report groups

    private func rowSection(kind: CADRecoveryRowKind, rows: [CADRecoveryReportRow]) -> some View {
        card {
            sectionHeader(sectionTitleKey(kind))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(row.category))
                            .font(.subheadline)
                            .foregroundStyle(color(kind))
                            .frame(width: 20, alignment: .center)
                        Text(verbatim: rowText(row))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("cad.recovery.row.\(row.id)")
                }
            }
        }
        .accessibilityIdentifier("cad.recovery.section.\(kind.rawValue)")
    }

    private var noticesCard: some View {
        card {
            sectionHeader("cad.recovery.section.notes")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(preview.report.notices.enumerated()), id: \.offset) { _, notice in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .center)
                        Text(verbatim: noticeText(notice))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("cad.recovery.notes.section")
    }

    // MARK: Error / footer

    private func errorCard(_ message: String) -> some View {
        card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("cad.recovery.error")
    }

    @ViewBuilder
    private var footer: some View {
        if mode == .decide, let restore {
            HStack(spacing: 12) {
                if sourceChanged, let onRefresh {
                    Button {
                        onRefresh()
                    } label: {
                        Text("cad.recovery.action.refresh")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("cad.recovery.refreshButton")
                }
                Spacer(minLength: 0)
                if isRestoring { ProgressView() }
                Button {
                    guard restoreTask == nil else { return }
                    restoreTask = Task { await performRestore(restore) }
                } label: {
                    Text(LocalizedStringKey(isRestoring
                                            ? "cad.recovery.action.restoring"
                                            : "cad.recovery.action.restore"))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRestoring)
                .accessibilityIdentifier("cad.recovery.restoreButton")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func performRestore(
        _ restore: @escaping () async throws -> CADRecoveryRestoreResult
    ) async {
        isRestoring = true
        defer {
            isRestoring = false
            restoreTask = nil
        }
        do {
            let result = try await restore()
            // A dismissed presentation must not forward a late success to
            // whatever view now occupies this position. The caller has
            // already recorded the atomic copy itself.
            guard !Task.isCancelled else { return }
            onRestored(result)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = message(for: error)
            sourceChanged = (error as? CADRecoveryError) == .sourceChanged
        }
    }

    private func message(for error: Error) -> String {
        guard let recovery = error as? CADRecoveryError else {
            let description = error.localizedDescription
            return description.isEmpty ? FloeL10n.l("cad.recovery.error.failed") : description
        }
        switch recovery {
        case .sourceChanged:
            return FloeL10n.l("cad.recovery.error.sourceChanged")
        case .destinationExists:
            return FloeL10n.l("cad.recovery.error.destinationExists")
        case .noVerifiedPrevious, .sourceMismatch:
            return FloeL10n.l("cad.recovery.error.noPrevious")
        case .destinationOutsideSource:
            return FloeL10n.l("cad.recovery.error.outsideSource")
        case .destinationNotPackage:
            return FloeL10n.l("cad.recovery.error.notPackage")
        case .sourceNotContained:
            return FloeL10n.l("cad.recovery.error.sourceNotContained")
        case .destinationParentMissing, .destinationInsideSource,
             .copyFailed, .verificationFailed:
            return FloeL10n.l("cad.recovery.error.failed")
        }
    }

    // MARK: Copy

    private var damageText: String {
        switch preview.damage {
        case .missingManifest:
            return FloeL10n.l("cad.recovery.damage.missing_manifest")
        case .unreadableManifest:
            return FloeL10n.l("cad.recovery.damage.unreadable_manifest")
        case .unreadableDocument:
            return FloeL10n.l("cad.recovery.damage.unreadable_document")
        case .failedIntegrity:
            return FloeL10n.l("cad.recovery.damage.failed_integrity")
        case .unreadablePackage:
            return FloeL10n.l("cad.recovery.damage.unreadable_package")
        }
    }

    private func sectionTitleKey(_ kind: CADRecoveryRowKind) -> String {
        switch kind {
        case .recovered: return "cad.recovery.section.recovered"
        case .unknown: return "cad.recovery.section.unknown"
        case .retainedInOriginal: return "cad.recovery.section.retained"
        case .unavailable: return "cad.recovery.section.unavailable"
        }
    }

    private func rowText(_ row: CADRecoveryReportRow) -> String {
        switch row.category {
        case .bodies:
            return counted("cad.recovery.item.bodies", row.count ?? 0)
        case .sketches:
            return counted("cad.recovery.item.sketches", row.count ?? 0)
        case .planes:
            return counted("cad.recovery.item.planes", row.count ?? 0)
        case .axes:
            return counted("cad.recovery.item.axes", row.count ?? 0)
        case .features:
            return counted("cad.recovery.item.features", row.count ?? 0)
        case .variables:
            return counted("cad.recovery.item.variables", row.count ?? 0)
        case .images:
            return counted("cad.recovery.item.images", row.count ?? 0)
        case .symbols:
            return counted("cad.recovery.item.symbols", row.count ?? 0)
        case .drawingPages:
            guard let count = row.count else {
                return FloeL10n.l("cad.recovery.item.drawingPages.unverified")
            }
            return counted("cad.recovery.item.drawingPages", count)
        case .assembly:
            return FloeL10n.l("cad.recovery.item.assembly")
        case .materials:
            guard let count = row.count else {
                return FloeL10n.l("cad.recovery.item.materials.unverified")
            }
            return counted("cad.recovery.item.materials", count)
        case .animation:
            guard let count = row.count else {
                return FloeL10n.l("cad.recovery.item.animation.unverified")
            }
            return counted("cad.recovery.item.animation", count)
        case .scripts:
            return FloeL10n.l("cad.recovery.item.scripts")
        case .scene:
            return FloeL10n.l("cad.recovery.item.scene")
        case .previewImage:
            return FloeL10n.l("cad.recovery.item.previewImage")
        case .changesSincePrevious:
            return FloeL10n.l("cad.recovery.item.changesSincePrevious")
        case .namedVersions:
            return counted("cad.recovery.item.namedVersions", row.count ?? 0)
        case .otherItems:
            return counted("cad.recovery.item.otherItems", row.count ?? 0)
        case .newerResources:
            return counted("cad.recovery.item.newerResources", row.count ?? 0)
        case .missingDamagedPreview:
            return FloeL10n.l("cad.recovery.item.missingDamagedPreview")
        }
    }

    private func counted(_ key: String, _ count: Int) -> String {
        FloeL10n.plural(key, count: count)
    }

    /// Compact, explicitly unverified counts from the damaged manifest.
    private func reportedCountsText(_ counts: [String: Int]) -> String {
        let order = ["bodies", "sketches", "features", "variables",
                     "images", "planes", "axes", "symbols"]
        return order.compactMap { key -> String? in
            guard let count = counts[key], count > 0 else { return nil }
            return FloeL10n.plural("cad.recovery.item.\(key)", count: count)
        }.joined(separator: " · ")
    }

    private func noticeText(_ notice: CADRecoveryNotice) -> String {
        switch notice {
        case .previousWrittenByNewerSchema:
            return FloeL10n.l("cad.recovery.notice.previousNewerSchema")
        case .previousOpensReadOnly:
            return FloeL10n.l("cad.recovery.notice.previousReadOnly")
        case .manifestCountsDiffer:
            return FloeL10n.l("cad.recovery.notice.manifestCountsDiffer")
        case .unclaimedPreviousResources(let count):
            return FloeL10n.l("cad.recovery.notice.unclaimedResources", count)
        case .noPreviewImage:
            return FloeL10n.l("cad.recovery.notice.noPreviewImage")
        case .unrecognizedFieldsPreserved:
            return FloeL10n.l("cad.recovery.notice.unrecognizedFields")
        }
    }

    private func icon(_ category: CADRecoveryCategory) -> String {
        switch category {
        case .bodies: return "cube"
        case .sketches: return "scribble"
        case .planes, .axes: return "square.on.square.dashed"
        case .features: return "square.stack.3d.up"
        case .variables: return "function"
        case .images, .previewImage: return "photo"
        case .symbols: return "character.textbox"
        case .drawingPages: return "doc.richtext"
        case .assembly: return "cube.transparent"
        case .materials: return "paintpalette"
        case .animation: return "play.rectangle"
        case .scripts: return "curlybraces"
        case .scene: return "camera"
        case .changesSincePrevious: return "questionmark.circle"
        case .namedVersions: return "clock.arrow.circlepath"
        case .otherItems: return "tray.full"
        case .newerResources: return "photo.on.rectangle.angled"
        case .missingDamagedPreview: return "photo.badge.exclamationmark"
        }
    }

    private func color(_ kind: CADRecoveryRowKind) -> Color {
        switch kind {
        case .recovered: return .green
        case .unknown: return .orange
        case .retainedInOriginal: return .secondary
        case .unavailable: return .orange
        }
    }

    private func sectionHeader(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func dateText(_ date: Date) -> String {
        let locale = Locale(identifier: FloeL10n.currentLanguageCode)
        return date.formatted(Date.FormatStyle(date: .abbreviated,
                                               time: .shortened,
                                               locale: locale))
    }
}
#endif
