// FloeExecution — one authoritative Linux component/environment state.
//
// The Settings screen, the terminal empty state and the shell previously
// derived contradictory pictures (an installed, even running guest could
// still render the "Download and Start" card). This type is the single
// derivation from verified facts:
//
//  - image install + typed verification issue (`LinuxGuestImageInstallationService`),
//  - per-environment disk preparation/migration provenance,
//  - the live guest runtime (`LinuxGuestStatus`),
//  - the shared, cancellable download job.
//
// The derivation is a pure function: tests prove that a verified installed
// or running component can never render the not-installed card, without a
// device, a VM or SwiftUI.

import Foundation

/// What one App-shared Linux image job is doing right now. The phase is owned
/// by the service operation (download → archive verification → extraction →
/// image verification/finalization, or local reconstruction/checks); the UI
/// only mirrors it, so a progress bar can never claim "downloading" while the
/// service is hashing or extracting, and a later phase never renders as the
/// previous phase's percentage.
public enum LinuxGuestImageTransferPhase: String, Sendable, Equatable, CaseIterable {
    /// Re-verifying already-installed bytes (no download).
    case checking
    /// Rebuilding the bootable view from locally verified blobs (no download).
    case reconstructing
    /// Downloading the pinned archive (byte progress is available).
    case downloading
    /// Hashing the downloaded archive against the pinned SHA-512 (progress is
    /// available in archive bytes).
    case verifyingArchive
    /// Extracting the verified archive into staging.
    case extracting
    /// Hashing the staged/promoted image artifacts against the manifest.
    case verifyingImage
    /// Atomic promotion / Runtime v2 refresh of the verified image.
    case finalizing
}

/// Shared progress bookkeeping for the image job. A phase change starts a new
/// 0...1 scale (download bytes and archive-verify bytes are different totals);
/// within one phase the fraction is monotonic so a mirror retry or a redundant
/// callback can never move the bar backwards.
public enum LinuxGuestImageProgress {
    public static func monotonic(previous: Double?, next: Double) -> Double {
        let bounded = min(1, max(0, next))
        guard let previous else { return bounded }
        return max(min(1, max(0, previous)), bounded)
    }
}

/// Gated phase/progress state for one shared image job.
///
/// Phase and progress reports reach the UI through independent MainActor
/// hops, so they can arrive in a different order than they were produced.
/// Every report carries a sequence stamped by the service operation: a report
/// older than the last applied one is dropped, and `finish()` makes the state
/// terminal so nothing can resurrect a completed or cancelled job. A new job
/// for the same id starts a new epoch, so an in-flight report from the
/// previous job is dropped as well.
public struct LinuxGuestImageJobProgress: Sendable, Equatable {
    public let epoch: UUID
    public private(set) var sequence: UInt64
    public private(set) var phase: LinuxGuestImageTransferPhase?
    public private(set) var fraction: Double?
    public private(set) var isFinished = false

    public init(epoch: UUID) {
        self.epoch = epoch
        self.sequence = 0
    }

    /// Applies one report. Returns false when it is stale (wrong epoch, older
    /// sequence, or after `finish()`), in which case the caller must not touch
    /// the UI mirrors.
    @discardableResult
    public mutating func apply(
        epoch: UUID,
        sequence: UInt64,
        phase: LinuxGuestImageTransferPhase,
        fraction: Double?
    ) -> Bool {
        guard !isFinished, epoch == self.epoch, sequence >= self.sequence else { return false }
        self.sequence = sequence
        if self.phase != phase {
            self.phase = phase
            self.fraction = nil
        }
        if let fraction {
            self.fraction = LinuxGuestImageProgress.monotonic(previous: self.fraction, next: fraction)
        }
        return true
    }

    /// Terminal transition: the job ended (success, failure or cancellation).
    /// Later reports, however delayed, are ignored.
    public mutating func finish() {
        isFinished = true
        phase = nil
        fraction = nil
    }
}

public enum LinuxGuestInstallState: Sendable, Equatable {
    /// Durable image storage is still being initialized (first launch before
    /// the root is ready). Distinct from a permanent unavailability so the
    /// UI shows progress, not a dead end.
    case storageInitializing
    /// No App-shared image storage could be initialized yet, but a recoverable
    /// initialization can retry; data already on disk was retained.
    case storageUnavailable
    /// The verified image is absent/unverified and no download is running.
    /// The UI offers exactly one download entry (never a second one).
    case needsDownload(verificationFailure: String?)
    /// The shared download/install job is running (`fraction` 0...1 when the
    /// server sent a Content-Length) or being cancelled.
    case downloading(fraction: Double?, cancelling: Bool)
    /// The image directory exists but failed verification. `transient` is true
    /// only for a known transient file I/O condition: first re-verify; if it
    /// persists, the repair re-downloads the pinned image through the safe
    /// staged promote. Never deletes user environments/deltas.
    case imageRepairRequired(transient: Bool, message: String)
    /// Image verified; no guest is running. Start action. When `environment`
    /// is present the start targets that environment; otherwise first Linux
    /// use auto-prepares through the shared preparation service.
    case installedStopped(environmentID: String?)
    /// Guest booted; running truth comes from the engine, not a flag.
    case running(environmentID: String)
    /// The guest failed to start (or its disk ext4 resize failed). The
    /// message carries the engine's honest reason; repair retries start.
    case repairRequired(environmentID: String?, message: String)
    /// The installed image ships a newer runner/component than the disk's
    /// in-guest copy; a start performs the in-guest update automatically.
    case updateAvailable(environmentID: String?, detail: String?)
}

/// Facts gathered by the app layer. Every field is optional/nil when the
/// corresponding service cannot answer; the derivation never invents state.
public struct LinuxGuestInstallFacts: Sendable, Equatable {
    public var storageAvailable: Bool
    /// Durable image storage initialization is in progress (loading vs a
    /// permanent unavailability).
    public var storageInitializing: Bool
    public var imageInstalled: Bool
    public var imageVerificationIssue: LinuxImageVerificationIssue?
    public var imageDistributable: Bool
    public var componentUpdateDetail: String?
    public var guestEnvironmentID: String?
    public var guestRunning: Bool
    public var guestLastError: String?
    public var guestDiskResizeFailure: String?
    /// True while the shared download job for the pinned image is running.
    public var downloadRunning: Bool
    public var downloadFraction: Double?
    public var downloadCancelling: Bool
    /// The shared image job's own failure message (a real error, never a
    /// cancellation). When the image still fails verification, this newest
    /// signal must stay visible: the older verification reason alone would
    /// hide why the repair just failed.
    public var downloadFailureMessage: String?

    /// Backward-compatible read of the verification failure message.
    public var imageVerificationFailure: String? { imageVerificationIssue?.message }

    public init(
        storageAvailable: Bool = false,
        storageInitializing: Bool = false,
        imageInstalled: Bool = false,
        imageVerificationIssue: LinuxImageVerificationIssue? = nil,
        imageDistributable: Bool = false,
        componentUpdateDetail: String? = nil,
        guestEnvironmentID: String? = nil,
        guestRunning: Bool = false,
        guestLastError: String? = nil,
        guestDiskResizeFailure: String? = nil,
        downloadRunning: Bool = false,
        downloadFraction: Double? = nil,
        downloadCancelling: Bool = false,
        downloadFailureMessage: String? = nil
    ) {
        self.storageAvailable = storageAvailable
        self.storageInitializing = storageInitializing
        self.imageInstalled = imageInstalled
        self.imageVerificationIssue = imageVerificationIssue
        self.imageDistributable = imageDistributable
        self.componentUpdateDetail = componentUpdateDetail
        self.guestEnvironmentID = guestEnvironmentID
        self.guestRunning = guestRunning
        self.guestLastError = guestLastError
        self.guestDiskResizeFailure = guestDiskResizeFailure
        self.downloadRunning = downloadRunning
        self.downloadFraction = downloadFraction
        self.downloadCancelling = downloadCancelling
        self.downloadFailureMessage = downloadFailureMessage
    }
}

/// One-shot completion gate for the shared Linux image job. A card owner's
/// continuation (start the guest) must fire only when THIS image's job
/// transitioned from running to finished with a real-file verified status —
/// never for an unrelated package-job revision, and never for a cancellation
/// or failure. `observe` returns true at most once per genuine transition.
public struct LinuxGuestInstallCompletionGate: Sendable, Equatable {
    private var observedRunning = false

    public init() {}

    public mutating func observe(running: Bool, failed: Bool, verified: Bool) -> Bool {
        defer { observedRunning = running }
        guard observedRunning, !running, !failed, verified else { return false }
        return true
    }
}

public enum LinuxGuestInstallStateDerivation {
    /// The single source of truth. Precedence is deliberate:
    ///
    /// 1. A running guest is `running` — nothing else may render (the
    ///    not-installed card is unreachable once the engine reports running).
    /// 2. An in-flight shared download is `downloading`.
    /// 3. Storage still initializing → `storageInitializing`; no storage →
    ///    `storageUnavailable` (a recoverable init can retry).
    /// 4. Missing image → `needsDownload` (exactly one entry).
    /// 5. Installed image with a verification issue → `imageRepairRequired`
    ///    (re-verify; then re-download the pinned image safely).
    /// 6. Verified image + a disk resize failure → `repairRequired`.
    /// 7. Verified image + a newer component → `updateAvailable` (start
    ///    performs the update).
    /// 8. A guest last start error → `repairRequired` with the reason.
    /// 9. Otherwise verified + stopped → `installedStopped`.
    public static func state(from facts: LinuxGuestInstallFacts) -> LinuxGuestInstallState {
        if facts.guestRunning, let environmentID = facts.guestEnvironmentID {
            return .running(environmentID: environmentID)
        }
        if facts.downloadRunning || facts.downloadCancelling {
            return .downloading(fraction: facts.downloadFraction, cancelling: facts.downloadCancelling)
        }
        if facts.storageInitializing {
            return .storageInitializing
        }
        guard facts.storageAvailable else {
            return .storageUnavailable
        }
        guard facts.imageInstalled else {
            return .needsDownload(verificationFailure: facts.imageVerificationIssue?.message)
        }
        if let issue = facts.imageVerificationIssue {
            let transient: Bool
            if case .ioFailure(_, let io) = issue {
                transient = io.isTransientAccessFailure
            } else {
                transient = false
            }
            // A failed repair is the newest and most actionable signal; keep
            // it visible alongside the underlying verification reason instead
            // of letting the older message hide it.
            let message: String
            if let failure = facts.downloadFailureMessage, !failure.isEmpty {
                message = failure + "\n" + issue.message
            } else {
                message = issue.message
            }
            return .imageRepairRequired(transient: transient, message: message)
        }
        if let resize = facts.guestDiskResizeFailure, !resize.isEmpty {
            return .repairRequired(environmentID: facts.guestEnvironmentID, message: resize)
        }
        if let update = facts.componentUpdateDetail, !update.isEmpty {
            return .updateAvailable(environmentID: facts.guestEnvironmentID, detail: update)
        }
        if let error = facts.guestLastError, !error.isEmpty {
            return .repairRequired(environmentID: facts.guestEnvironmentID, message: error)
        }
        return .installedStopped(environmentID: facts.guestEnvironmentID)
    }
}
