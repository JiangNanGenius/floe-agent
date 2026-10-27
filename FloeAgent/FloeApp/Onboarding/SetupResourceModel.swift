// FloeApp — Non-blocking resource preparation for the setup guide.
//
// SPDX-License-Identifier: MPL-2.0
//
// The guide owns no downloader. Every row here mirrors a job that an EXISTING
// service already owns and reports only what that service really measured.
// Leaving the page unsubscribes the view and nothing else: the same job is
// still there when the user returns. Next, Later and Finish never wait for a
// download, a verification, an unpack or an install, and a failed, paused or
// unfinished resource never blocks navigation.
//
// Two facts are deliberately SEPARATE, because conflating them lies: the
// state of the ACTIVE job (identified by the pack/model/image the job itself
// is working on) and the readiness of the user's CURRENT SELECTION. An
// already-installed voice stays "ready" while a different voice downloads,
// and a running job is never hidden because some other pack is installed.

import Foundation

/// The owner's own view of what a job is doing. Every value here comes from
/// an existing service; nothing is inferred from a UI timer.
enum SetupResourcePhase: String, Sendable, Equatable {
    /// The owner reports no work for this subject at all.
    case idle
    /// Queued or starting, with no byte report yet.
    case queued
    /// Bytes are moving.
    case transferring
    /// Bytes arrived; the owner is hashing or checking them.
    case verifying
    /// Verified; the owner is unpacking, installing or committing.
    case installing
    /// The owner is parked on a decision only the user can make. The job is
    /// still alive, so it must stay visible, and it still never blocks.
    case awaitingConfirmation
    /// The owner's own success proof.
    case finished
}

extension SetupResourcePhase {
    /// True while the owner still has live work, including a parked decision.
    var isLive: Bool {
        switch self {
        case .queued, .transferring, .verifying, .installing, .awaitingConfirmation: true
        case .idle, .finished: false
        }
    }
}

/// One owner report, reduced to the facts the guide may show.
struct SetupResourceReport: Equatable, Sendable {
    var kind: SetupResourceRow.Kind
    var titleKey: String
    /// The subject the JOB is working on, from the owner. nil when the owner
    /// reports no job for this subject.
    var jobSubjectID: String? = nil
    var phase: SetupResourcePhase = .idle
    var totalBytes: Int64? = nil
    var transferredBytes: Int64? = nil
    var bytesPerSecond: Int64? = nil
    /// The owner's own published fraction, when it reports one.
    var ownerFraction: Double? = nil
    /// True only when the owner proved installed bytes — never because a
    /// transfer reached 100%.
    var isInstalled: Bool = false
    var isPaused: Bool = false
    var wasCancelled: Bool = false
    var failureMessage: String? = nil = nil
}

/// What a preparation job is actually doing. The order matters: a finished
/// transfer is never reported as Ready until the owning service's own
/// verification or install step proved the bytes.
enum SetupResourceStage: Equatable, Sendable {
    case notRequested
    case queued
    case downloading
    case verifying
    case installing
    case awaitingConfirmation
    case ready
    case paused
    case cancelled
    case failed(String)

    var isPreparing: Bool {
        switch self {
        case .queued, .downloading, .verifying, .installing, .awaitingConfirmation: true
        default: false
        }
    }

    /// False for EVERY stage, including failure. Expressed as a property so
    /// the non-blocking rule exists in exactly one place and is testable.
    var blocksNavigation: Bool { false }

    var summaryTitleKey: String {
        switch self {
        case .notRequested: "setup.resource.stage.available"
        case .queued: "setup.resource.stage.queued"
        case .downloading: "setup.resource.stage.downloading"
        case .verifying: "setup.resource.stage.checking"
        case .installing: "setup.resource.stage.installing"
        case .awaitingConfirmation: "setup.resource.stage.awaiting_confirmation"
        case .ready: "setup.resource.stage.ready"
        case .paused: "setup.resource.stage.paused"
        case .cancelled: "setup.resource.stage.cancelled"
        case .failed: "setup.resource.stage.failed"
        }
    }

    /// Product summary bucket. Preparation always reads as "Preparing",
    /// never as a completion, and never as something that stops the user.
    var summaryBucket: SetupSummaryEntry.Outcome {
        switch self {
        case .ready: .saved
        case .queued, .downloading, .verifying, .installing, .awaitingConfirmation: .preparing
        case .failed: .needsAttention
        case .notRequested, .paused, .cancelled: .later
        }
    }
}

/// One visible resource row: the state of ONE OWNER-SPECIFIC job.
/// `totalBytes == nil` means the owning service could not determine a total;
/// the UI then shows an indeterminate bar and never invents a size or a
/// percentage.
struct SetupResourceRow: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case speechRecognition
        case voicePack
        case onDeviceModel
        case localRuntime
        case contentUpdate
        /// A Skill Hub "Get" the user started. Kept separate from signed
        /// content updates on purpose: they are different owners with
        /// different proofs, and labelling one as the other would lie.
        case skillHub
    }

    /// Stable identity of the job this row mirrors, e.g.
    /// `setup.resource.voicePack.<modelID>`. It follows the OWNER's job, never
    /// the current user selection, so a selection change can never mask an
    /// active transfer.
    let id: String
    let kind: Kind
    let titleKey: String
    /// The concrete pack/model/image the job is working on, as reported by
    /// the owning service. nil when no job has been reported yet.
    var jobSubjectID: String? = nil
    var stage: SetupResourceStage = .notRequested
    var totalBytes: Int64? = nil
    var transferredBytes: Int64? = nil
    var bytesPerSecond: Int64? = nil

    /// nil = indeterminate: an unknown total renders an indeterminate bar and
    /// never a fabricated percentage.
    var fraction: Double? {
        if let ownerFraction { return min(1, max(0, ownerFraction)) }
        guard let total = totalBytes, total > 0, let done = transferredBytes, done >= 0
        else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    var percentText: String? {
        guard let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    var isReady: Bool { stage == .ready }

    var canRetry: Bool {
        switch stage {
        case .failed, .cancelled, .paused: true
        default: false
        }
    }

    var canCancel: Bool { stage.isPreparing }
}

/// The user's CURRENT choice for one resource kind and whether that choice is
/// actually usable right now. Independent of any running job.
struct SetupSelectionState: Equatable, Sendable {
    var kind: SetupResourceRow.Kind
    /// What the user has selected now (nil = nothing selected yet).
    var selectedSubjectID: String? = nil = nil
    /// Installed subject ids as reported by the owner. Readiness is looked up
    /// here, never inferred from a byte counter.
    var installedSubjectIDs: Set<String> = []
    /// The subject the user picked that is still being prepared. The owning
    /// service applies it only if the selection is unchanged at completion.
    var pendingSubjectID: String? = nil = nil

    /// True only when the selected subject is really installed.
    var isSelectedReady: Bool {
        guard let selectedSubjectID else { return false }
        return installedSubjectIDs.contains(selectedSubjectID)
    }

    /// A selection is usable, or will be once its own job finishes.
    var isSatisfied: Bool { isSelectedReady || pendingSubjectID != nil }
}

/// Pure derivation. Kept free of services so the rules are testable and so no
/// view can accidentally invent a stage.
enum SetupResourceStageRules {
    static func stage(for report: SetupResourceReport) -> SetupResourceStage {
        if let failure = report.failureMessage { return .failed(failure) }
        if report.wasCancelled { return .cancelled }
        if report.isPaused && report.phase != .finished { return .paused }
        // An install proof always wins over a byte counter.
        if report.isInstalled, report.phase != .transferring, report.phase != .queued {
            return .ready
        }
        switch report.phase {
        case .idle:
            return report.isInstalled ? .ready : .notRequested
        case .queued:
            return .queued
        case .transferring:
            return afterTransfer(
                transferredBytes: report.transferredBytes,
                totalBytes: report.totalBytes,
                verified: false,
                installed: report.isInstalled
            )
        case .verifying:
            // A complete transfer is a check, not a stall.
            return report.isInstalled ? .ready : .verifying
        case .installing:
            return report.isInstalled ? .ready : .installing
        case .awaitingConfirmation:
            // A parked decision is honest work in progress, never a fake
            // completion and never a blocker.
            return report.isInstalled ? .ready : .awaitingConfirmation
        case .finished:
            return report.isInstalled ? .ready : .verifying
        }
    }

    /// A transfer that reached 100% is still not Ready: the bytes have to
    /// verify and the install step has to succeed first.
    static func afterTransfer(
        transferredBytes: Int64?,
        totalBytes: Int64?,
        verified: Bool,
        installed: Bool
    ) -> SetupResourceStage {
        if installed { return .ready }
        guard let total = totalBytes, total > 0, let done = transferredBytes else {
            return .downloading
        }
        if done < total { return .downloading }
        return verified ? .installing : .verifying
    }

    /// Ready comes only from the owning service's real success proof.
    static func fromInstallState(installed: Bool, failureMessage: String?) -> SetupResourceStage {
        if let failureMessage { return .failed(failureMessage) }
        return installed ? .ready : .notRequested
    }

    /// A pending selection survives preparation only while it is still the
    /// user's current choice. A changed mind is authoritative: nothing is
    /// applied late and nothing is substituted (no cloud fallback, no
    /// audition of a voice the user did not pick).
    static func shouldApplyPendingSelection(
        pendingSubjectID: String?,
        currentSubjectID: String?,
        isInstalled: Bool
    ) -> Bool {
        guard isInstalled, let pendingSubjectID, let currentSubjectID else { return false }
        return pendingSubjectID == currentSubjectID
    }

    /// The row identity must follow the JOB, never the selection: two
    /// different packs produce two different identities even when the user
    /// has already installed the one they currently use.
    static func rowID(kind: SetupResourceRow.Kind, subjectID: String?) -> String {
        guard let subjectID else { return "setup.resource.\(kind.rawValue)" }
        return "setup.resource.\(kind.rawValue).\(subjectID)"
    }

    /// Builds the row for one report. A report with no job subject still gets
    /// a stable identity, so an idle resource can be offered.
    static func row(for report: SetupResourceReport) -> SetupResourceRow {
        SetupResourceRow(
            id: rowID(kind: report.kind, subjectID: report.jobSubjectID),
            kind: report.kind,
            titleKey: report.titleKey,
            jobSubjectID: report.jobSubjectID,
            stage: stage(for: report),
            // An unknown total stays nil: the row renders indeterminate.
            totalBytes: report.totalBytes,
            transferredBytes: report.transferredBytes,
            // A rate is shown only while the owner reports a live transfer,
            // and only the value that owner measured.
            bytesPerSecond: report.phase == .transferring ? report.bytesPerSecond : nil,
            ownerFraction: report.ownerFraction
        )
    }

    /// Builds the selection facts for one kind. Readiness is a lookup in the
    /// owner's installed set, never a byte comparison.
    /// Builds the selection facts for one kind. Readiness is a lookup in the
    /// owner's installed set, never a byte comparison. `pendingSubjectID`
    /// carries the owner's own remembered choice for a subject that is not
    /// installed yet, so a guide can show "will apply when ready" without
    /// re-deciding anything.
    static func selection(
        kind: SetupResourceRow.Kind,
        selectedSubjectID: String?,
        installedSubjectIDs: Set<String>,
        activeJobSubjectID: String?,
        pendingSubjectID: String? = nil
    ) -> SetupSelectionState {
        let isSelectedReady = selectedSubjectID.map { installedSubjectIDs.contains($0) } ?? false
        let pending: String?
        if let pendingSubjectID, !installedSubjectIDs.contains(pendingSubjectID) {
            pending = pendingSubjectID
        } else if let selectedSubjectID, !isSelectedReady {
            pending = selectedSubjectID
        } else {
            // The owner may be preparing something the user has not selected;
            // that stays on the job row, never on the selection.
            pending = nil
        }
        _ = activeJobSubjectID
        return SetupSelectionState(
            kind: kind,
            selectedSubjectID: selectedSubjectID,
            installedSubjectIDs: installedSubjectIDs,
            pendingSubjectID: pending
        )
    }
}

/// The stable identities the guide surfaces when the matching owner reports
/// them as relevant.
enum SetupResourceID {
    static let localRuntime = SetupResourceStageRules.rowID(kind: .localRuntime, subjectID: nil)
    static let contentUpdate = SetupResourceStageRules.rowID(kind: .contentUpdate, subjectID: nil)
    static func voicePack(_ modelID: String) -> String {
        SetupResourceStageRules.rowID(kind: .voicePack, subjectID: modelID)
    }
    static func onDeviceModel(_ catalogID: String) -> String {
        SetupResourceStageRules.rowID(kind: .onDeviceModel, subjectID: catalogID)
    }
}

/// Pure navigation summary: what is saved, what is still preparing, what the
/// user postponed and what needs attention. Built only from guide state plus
/// mirrored rows, so it is testable without a running app.
struct SetupSummaryEntry: Identifiable, Equatable, Sendable {
    enum Outcome: String, Sendable {
        case saved
        case defaulted
        case preparing
        case later
        case needsAttention

        var titleKey: String { "setup.summary.outcome.\(rawValue)" }
    }

    let section: SetupGuideSection
    let outcome: Outcome
    /// True when the summary row leads to a real editor instead of a status
    /// line only.
    let canJump: Bool

    var id: String { section.rawValue }
    var titleKey: String { section.titleKey }
}

enum SetupGuideSummaryBuilder {
    /// A live job lifts its own section to "preparing" without changing any
    /// user decision, and a finished/failed job never blocks anything else.
    static func statuses(
        for state: SetupGuideState,
        resources: [SetupResourceRow]
    ) -> [SetupGuideSection: SetupSectionStatus] {
        var statuses = state.statuses
        for row in resources where row.stage.isPreparing {
            let owner = ownerSection(of: row)
            switch statuses[owner] {
            case nil, .unset, .defaulted: statuses[owner] = .preparing
            default: break
            }
        }
        return statuses
    }

    static func entries(
        state: SetupGuideState,
        resources: [SetupResourceRow] = []
    ) -> [SetupSummaryEntry] {
        let statuses = statuses(for: state, resources: resources)
        return SetupGuideSection.configurable.map { section in
            let outcome: SetupSummaryEntry.Outcome
            switch statuses[section] ?? .unset {
            case .configured: outcome = .saved
            case .defaulted: outcome = .defaulted
            case .preparing: outcome = .preparing
            case .deferred: outcome = .later
            case .needsAttention: outcome = .needsAttention
            case .unset: outcome = .later
            }
            return SetupSummaryEntry(section: section, outcome: outcome, canJump: true)
        }
    }

    static func ownerSection(of row: SetupResourceRow) -> SetupGuideSection {
        switch row.kind {
        case .speechRecognition, .voicePack: .voice
        case .onDeviceModel: .chatModels
        case .localRuntime: .files
        case .contentUpdate, .skillHub: .skills
        }
    }
}
