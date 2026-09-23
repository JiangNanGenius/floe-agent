// FloeExecution — Linux guest logical-run ownership and scoped transient
// release.
//
// A local-model task that runs a Linux tool through `exec.shell` starts the
// environment's guest on demand; the tool result returns while the guest
// keeps running (the fast path for the next command). When the SAME logical
// run then needs the heavy runtime back for its continuation, that guest is
// its own disposable tool guest — but only as long as nothing else claims it.
// These types carry the registry's verified facts about one environment's
// guest so the heavy-runtime arbiter can tell "this run's own transient tool
// guest" apart from work that still requires an explicit user decision
// (another run's guest, a user-started guest, an interactive terminal, a
// managed service, port forwards, a quarantined stop).
//
// The release itself is deliberately narrower than `stopGuest`: it revalidates
// ownership and transience inside the registry, waits for the run's own
// commands to finish, and refuses instead of destroying anything that stopped
// being transient. Only a route that reaches `.released` may let the model map
// weights; every other outcome keeps the guest and the physical-exclusion
// guarantee intact.

import Foundation

/// Verified facts about one environment's Linux presence, reported by the
/// registry that owns it. Every field is a measurement, never an inference:
/// `ownerRunID` is the durable task UUID string recorded when the guest was
/// started on demand for that run's tool, `starting`/`quarantined` mirror the
/// real lifecycle state, and the counters describe real in-flight work.
public struct LinuxGuestActivityDetail: Sendable, Equatable {
    public var environmentID: String
    /// Logical run (durable task UUID string) whose tool started this guest;
    /// nil when the guest was started by the user or outside a tool run, and
    /// such a guest is never auto-released.
    public var ownerRunID: String?
    public var running: Bool
    public var starting: Bool
    public var quarantined: Bool
    /// In-flight one-shot guest commands.
    public var activeCommandCount: Int
    /// Open interactive terminal sessions.
    public var activeTerminalCount: Int
    /// Managed background services spawned and not yet killed.
    public var activeServiceCount: Int
    /// Requested host port forwards (persistent intent, not a transient guest).
    public var requestedForwardCount: Int

    public init(
        environmentID: String,
        ownerRunID: String? = nil,
        running: Bool = false,
        starting: Bool = false,
        quarantined: Bool = false,
        activeCommandCount: Int = 0,
        activeTerminalCount: Int = 0,
        activeServiceCount: Int = 0,
        requestedForwardCount: Int = 0
    ) {
        self.environmentID = environmentID
        self.ownerRunID = ownerRunID
        self.running = running
        self.starting = starting
        self.quarantined = quarantined
        self.activeCommandCount = activeCommandCount
        self.activeTerminalCount = activeTerminalCount
        self.activeServiceCount = activeServiceCount
        self.requestedForwardCount = requestedForwardCount
    }

    /// A guest started on demand by a logical run's tool that has no other
    /// active owner: no running command, no interactive terminal, no managed
    /// service, no requested forward and no quarantined stop. This is the only
    /// state the arbiter may release without a user decision.
    public var isTransientToolGuest: Bool {
        ownerRunID != nil
            && running
            && !starting
            && !quarantined
            && activeCommandCount == 0
            && activeTerminalCount == 0
            && activeServiceCount == 0
            && requestedForwardCount == 0
    }
}

/// Outcome of a scoped transient release. Only `.released` proves the guest is
/// gone (its handle closed and its Runtime v2 state flushed/released);
/// `.refused` leaves the guest exactly as it was, and
/// `.stopFailedQuarantined` keeps the quarantine contract of a failed stop.
public enum LinuxGuestTransientReleaseOutcome: Sendable, Equatable {
    case released
    case refused(reason: String)
    case stopFailedQuarantined(detail: String)

    public var isReleased: Bool {
        if case .released = self { return true }
        return false
    }

    /// Short honest description for logs (never includes credentials or paths).
    public var diagnosticSummary: String {
        switch self {
        case .released:
            return "released"
        case .refused(let reason):
            return "refused: \(reason)"
        case .stopFailedQuarantined(let detail):
            return "stopFailedQuarantined: \(detail)"
        }
    }
}

public extension LinuxGuestActivityDetail {
    /// Case-insensitive logical-run identity match. Both sides use the durable
    /// run UUID string; parsing normalizes formatting so a differently cased id
    /// can never silently mismatch.
    static func runIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if let left = UUID(uuidString: lhs), let right = UUID(uuidString: rhs) {
            return left == right
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
