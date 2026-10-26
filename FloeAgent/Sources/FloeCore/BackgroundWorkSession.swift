// FloeCore — background work session model and policy.
//
// SPDX-License-Identifier: MPL-2.0
//
// A work session is the user's explicit, foreground-minted request to let
// Floe process the CURRENT durable queues — running tasks, queued/running
// background jobs and enabled due schedules — now, using the existing
// permission and atomic-claim machinery. The session never fabricates work,
// never shows invented progress, and is never started by a system wake:
// a cold launch, a background refresh or a download relaunch restores the
// persisted metadata (interrupted/armed) at most — it is NOT authority to
// auto-reacquire continued background execution. This file is the pure,
// Foundation-only contract; the app-side controller executes exactly these
// decisions against the real stores.

import Foundation

/// Honest session surface state. Every state maps to observable facts:
/// `running` requires real work, `waiting` names the real blocker, and
/// `interrupted` is a restored metadata boundary, never a live claim.
public enum BackgroundWorkSessionState: String, Codable, Sendable, Equatable, CaseIterable {
    /// The user never started a session (or cleared it). Nothing is promised.
    case idle
    /// The user stopped an existing session; its record survives for the next
    /// explicit start but holds no background claim.
    case armed
    /// Real work is executing under the session: a live run, a running job or
    /// a claimed-due schedule occurrence.
    case running
    /// The session is live but currently blocked on a named external fact.
    case waiting
    /// A persisted running/waiting session whose process exited. Metadata
    /// only; no background execution authority.
    case interrupted

    public var isActiveSurface: Bool { self == .running || self == .waiting }
}

/// The real blocker while `waiting`. Only facts the stores can confirm.
public enum BackgroundWorkSessionWaitReason: String, Codable, Sendable, Equatable {
    /// A run is paused on a pending approval the user has not answered.
    case approvals
    /// Queued work is deduped against environment claims a live owner holds;
    /// the session waits instead of double-claiming the environment.
    case environmentBusy
    /// A due or durable owner needs connectivity the device does not have.
    case network
    /// The session is live and correctly idle between real due times
    /// (enabled schedules whose next fire has not arrived).
    case dueWork
}

/// How the current process came to exist. Only `.foregroundLaunch` (a real
/// UI scene) may host an explicit user start; wakes restore metadata.
public enum BackgroundWorkWakeKind: String, Codable, Sendable, Equatable {
    case foregroundLaunch
    case backgroundRefresh
    case downloadRelaunch
}

/// What asked for a session start. Continued background execution is legal
/// only for an explicit foreground user action — the same fail-closed rule
/// the run-level continued-processing origin already enforces.
public enum BackgroundWorkSessionStartOrigin: String, Sendable, Equatable {
    case userInterface
    case systemWake
    case automatic
}

/// The exact durable counts behind a session decision. These are real store
/// numbers (never a fabricated percent), and they are the only inputs the
/// state machine reads.
public struct BackgroundWorkSessionCounts: Codable, Equatable, Sendable {
    /// Live executing runs (not approval-paused, not suspended awaiting the
    /// user — the same eligibility the background-location assist uses).
    public var liveRuns: Int
    /// Runs paused on a pending approval.
    public var pendingApprovals: Int
    /// Durable background jobs currently running.
    public var runningJobs: Int
    /// Durable background jobs queued but not started.
    public var queuedJobs: Int
    /// Claimed-or-due schedule occurrences the current pass is executing.
    public var claimedScheduleOccurrences: Int
    /// Enabled schedules that exist (context for `dueWork` waits).
    public var enabledSchedules: Int
    /// Linux/environments whose durable background hold is owned by a live
    /// server or accepted work (dedupe: the session never re-claims these).
    public var heldEnvironmentClaims: Int

    public init(
        liveRuns: Int = 0,
        pendingApprovals: Int = 0,
        runningJobs: Int = 0,
        queuedJobs: Int = 0,
        claimedScheduleOccurrences: Int = 0,
        enabledSchedules: Int = 0,
        heldEnvironmentClaims: Int = 0
    ) {
        self.liveRuns = max(0, liveRuns)
        self.pendingApprovals = max(0, pendingApprovals)
        self.runningJobs = max(0, runningJobs)
        self.queuedJobs = max(0, queuedJobs)
        self.claimedScheduleOccurrences = max(0, claimedScheduleOccurrences)
        self.enabledSchedules = max(0, enabledSchedules)
        self.heldEnvironmentClaims = max(0, heldEnvironmentClaims)
    }

    /// True when a task, a server (durable job / held environment) or
    /// accepted schedule work really owns background execution. This is the
    /// ownership fact the background-location release consults.
    public var hasAcceptedWork: Bool {
        liveRuns > 0 || runningJobs > 0 || claimedScheduleOccurrences > 0 || heldEnvironmentClaims > 0
    }

    /// Every admitted work item the session currently tracks. This is the
    /// real denominator for honest continued-task progress (drain ratio of
    /// actual store counts) — never an invented percentage.
    public var totalAdmitted: Int {
        liveRuns + runningJobs + queuedJobs + claimedScheduleOccurrences
    }
}

/// Raised by a session counts read when a durable store cannot be consulted.
/// UNKNOWN is deliberately distinct from EMPTY: folding a failed read into
/// zeros would fake a drained queue (releasing a real continued-processing
/// qualification prematurely) or fake a drain progress ratio. The controller
/// preserves the last VALID counts and defers every state change until the
/// next confirmed read; a failed read never claims completion of anything.
public struct BackgroundWorkSessionCountsUnknownError: Error, Sendable {
    /// The failed durable component, for logs and diagnostics only (never
    /// user-facing copy).
    public let component: String
    public init(component: String) { self.component = component }
}

/// The pure session decisions. The app controller applies exactly these, so
/// the contract is testable without a device, a window or the full app.
public enum BackgroundWorkSessionPolicy {
    /// Only an explicit foreground user action may start a session. A wake
    /// or an automatic path is never start authority.
    public static func mayStart(origin: BackgroundWorkSessionStartOrigin) -> Bool {
        origin == .userInterface
    }

    /// Metadata restoration after the process (re)starts. Running/waiting
    /// become `interrupted` (a dead process owns no background execution);
    /// armed and idle survive as themselves. Never returns `running`.
    public static func restoredState(
        afterWake wake: BackgroundWorkWakeKind,
        previous: BackgroundWorkSessionState
    ) -> BackgroundWorkSessionState {
        _ = wake
        switch previous {
        case .running, .waiting: return .interrupted
        case .armed, .idle, .interrupted: return previous
        }
    }

    /// A cold or download wake is NOT authority to auto-reacquire continued
    /// background execution. Only a real user action in the foreground may
    /// re-establish it (through the normal run/session paths).
    public static func mayAutoAcquireContinuedBackground(afterWake wake: BackgroundWorkWakeKind) -> Bool {
        _ = wake
        return false
    }

    /// Whether a NEW continued-processing submission may be minted for the
    /// session right now: real current-process foreground provenance,
    /// bootstrap-ready launch preferences, and ACTUAL admitted work. A
    /// restored saved flag or a wake can never satisfy this, and a session
    /// with nothing admitted must never hold an idle system task.
    public static func maySubmitQualification(
        isForegroundActive: Bool,
        launchPreferencesLoaded: Bool,
        counts: BackgroundWorkSessionCounts
    ) -> Bool {
        isForegroundActive && launchPreferencesLoaded && counts.hasAcceptedWork
    }

    /// The honest state for a live session given the real counts:
    ///  • active work (a task, a server job or accepted claimed schedule work)
    ///    → `.running`;
    ///  • otherwise a named blocker if one really exists, in order
    ///    approvals → environment dedupe → connectivity → future due times;
    ///  • otherwise the session stays live-waiting on due work.
    public static func activeState(for counts: BackgroundWorkSessionCounts) -> (
        state: BackgroundWorkSessionState,
        waitReason: BackgroundWorkSessionWaitReason?
    ) {
        if counts.hasAcceptedWork {
            return (.running, nil)
        }
        if counts.pendingApprovals > 0 {
            return (.waiting, .approvals)
        }
        if counts.queuedJobs > 0 && counts.heldEnvironmentClaims > 0 {
            return (.waiting, .environmentBusy)
        }
        if counts.enabledSchedules > 0 {
            return (.waiting, .dueWork)
        }
        return (.waiting, .dueWork)
    }

    /// Whether the persisted background-location assist may be released:
    /// true only when no task, server or accepted work owns it anymore. The
    /// app pushes the resulting facts to the location service, which owns
    /// the real CoreLocation session lifecycle.
    public static func shouldReleaseBackgroundLocation(counts: BackgroundWorkSessionCounts) -> Bool {
        !counts.hasAcceptedWork
    }

    /// A saved/armed toggle is a stored choice, not an acceptance: the
    /// session is only "qualifying" while real counts show real work.
    /// Presentation must never render a stored state as verified progress.
    public static func showsAsAccepted(counts: BackgroundWorkSessionCounts) -> Bool {
        counts.hasAcceptedWork
    }
}

/// The persisted session record. One atomic JSON object under
/// `settingsKey`; a partially written record can never mix generations.
public struct BackgroundWorkSessionSnapshot: Codable, Equatable, Sendable {
    /// Single `app_settings` key carrying the whole object. (Promotion into
    /// `AppSettingsKey` is a root-owned file; the literal is the contract.)
    public static let settingsKey = "agent.backgroundWorkSession.v1"

    public var state: BackgroundWorkSessionState
    public var waitReason: BackgroundWorkSessionWaitReason?
    public var counts: BackgroundWorkSessionCounts
    /// When the CURRENT user action started the session (nil = never).
    public var startedAt: Date?
    /// Last durable update — presentation and diagnostics only.
    public var updatedAt: Date
    /// Bumped on every user start/stop so a late callback (a finished pass,
    /// a wake restore for an older generation) can never overwrite a newer
    /// explicit choice.
    public var generation: UInt64

    public init(
        state: BackgroundWorkSessionState = .idle,
        waitReason: BackgroundWorkSessionWaitReason? = nil,
        counts: BackgroundWorkSessionCounts = BackgroundWorkSessionCounts(),
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        generation: UInt64 = 0
    ) {
        self.state = state
        self.waitReason = waitReason
        self.counts = counts
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case waitReason
        case counts
        case startedAt
        case updatedAt
        case generation
    }

    /// Lenient decode: any missing or corrupt field falls back to the calm
    /// default (idle, no counts) while every readable choice survives. A
    /// corrupt record never crashes launch and never fabricates a session.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(
            BackgroundWorkSessionState.self, forKey: .state
        ) ?? .idle
        waitReason = try container.decodeIfPresent(
            BackgroundWorkSessionWaitReason.self, forKey: .waitReason
        )
        counts = try container.decodeIfPresent(
            BackgroundWorkSessionCounts.self, forKey: .counts
        ) ?? BackgroundWorkSessionCounts()
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
    }
}
