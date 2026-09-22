// FloeExecution — one authoritative Linux component/environment state.
//
// The Settings screen, the terminal empty state and the shell previously
// derived contradictory pictures (an installed, even running guest could
// still render the "Download and Start" card). This type is the single
// derivation from verified facts:
//
//  - image install + digest verification (`LinuxGuestImageInstallationService`),
//  - per-environment disk preparation/migration provenance,
//  - the live guest runtime (`LinuxGuestStatus`),
//  - the shared, cancellable download job.
//
// The derivation is a pure function: tests prove that a verified installed
// or running component can never render the not-installed card, without a
// device, a VM or SwiftUI.

import Foundation

public enum LinuxGuestInstallState: Sendable, Equatable {
    /// No App-shared image storage is configured in this build.
    case storageUnavailable
    /// The verified image is absent/unverified and no download is running.
    /// The UI offers exactly one download entry (never a second one).
    case needsDownload(verificationFailure: String?)
    /// The shared download/install job is running (`fraction` 0...1 when the
    /// server sent a Content-Length) or being cancelled.
    case downloading(fraction: Double?, cancelling: Bool)
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
    public var imageInstalled: Bool
    public var imageVerificationFailure: String?
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

    public init(
        storageAvailable: Bool = false,
        imageInstalled: Bool = false,
        imageVerificationFailure: String? = nil,
        imageDistributable: Bool = false,
        componentUpdateDetail: String? = nil,
        guestEnvironmentID: String? = nil,
        guestRunning: Bool = false,
        guestLastError: String? = nil,
        guestDiskResizeFailure: String? = nil,
        downloadRunning: Bool = false,
        downloadFraction: Double? = nil,
        downloadCancelling: Bool = false
    ) {
        self.storageAvailable = storageAvailable
        self.imageInstalled = imageInstalled
        self.imageVerificationFailure = imageVerificationFailure
        self.imageDistributable = imageDistributable
        self.componentUpdateDetail = componentUpdateDetail
        self.guestEnvironmentID = guestEnvironmentID
        self.guestRunning = guestRunning
        self.guestLastError = guestLastError
        self.guestDiskResizeFailure = guestDiskResizeFailure
        self.downloadRunning = downloadRunning
        self.downloadFraction = downloadFraction
        self.downloadCancelling = downloadCancelling
    }
}

public enum LinuxGuestInstallStateDerivation {
    /// The single source of truth. Precedence is deliberate:
    ///
    /// 1. A running guest is `running` — nothing else may render (the
    ///    not-installed card is unreachable once the engine reports running).
    /// 2. An in-flight shared download is `downloading`.
    /// 3. No storage → `storageUnavailable`.
    /// 4. Missing/unverified image → `needsDownload` (exactly one entry).
    /// 5. Verified image + a disk resize failure → `repairRequired`.
    /// 6. Verified image + a newer component → `updateAvailable` (start
    ///    performs the update).
    /// 7. A guest last start error → `repairRequired` with the reason.
    /// 8. Otherwise verified + stopped → `installedStopped`.
    public static func state(from facts: LinuxGuestInstallFacts) -> LinuxGuestInstallState {
        if facts.guestRunning, let environmentID = facts.guestEnvironmentID {
            return .running(environmentID: environmentID)
        }
        if facts.downloadRunning || facts.downloadCancelling {
            return .downloading(fraction: facts.downloadFraction, cancelling: facts.downloadCancelling)
        }
        guard facts.storageAvailable else {
            return .storageUnavailable
        }
        guard facts.imageInstalled, facts.imageVerificationFailure == nil else {
            return .needsDownload(verificationFailure: facts.imageVerificationFailure)
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
