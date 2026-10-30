// FloeAndroidShellTools — bounded terminal-latency phase diagnostics
// (job-c5eec0e0881346ff, G07.1 terminal04).
//
// WHY: a real Samsung device run of a trivial `exec.shell` echo was observed
// to report `exit=0 durationMs=25577 effectiveTimeoutSeconds=10.0`. That
// number is the ORIGINAL journal/tool duration of ONE backend dispatch
// (`AndroidLinuxShellBackend.run`), and by itself it cannot say WHICH part of
// the terminal path it is: the local engine-gate queue, the engine start
// request (host pump grant + runtime recover/import/spawn), stdin delivery,
// the process/poll window, or the terminal-proof/workspace-settlement
// handling. This file adds the CLIENT half of that composition.
//
// HONESTY RULES (the reason this is a closed, tiny value type):
// * Only the ACTUAL monotonic spans this backend itself observes are
//   reported. A phase that was never reached is ABSENT — never zeroed.
// * A single fixed `unobserved=...` fact names what the client CANNOT
//   separate: the engine's internal start composition and its workspace
//   export settlement inside the released-terminal wait. Nobody may read
//   `start` or `run` as pure process execution.
// * No command text, no paths, no identifiers, no output bytes and no
//   payloads can enter the rendered string: the vocabulary is the closed
//   `Phase`/`Terminal` sets plus bounded integers.
// * Diagnostic only. Recording phases never gates admission, changes a
//   deadline, changes an outcome or releases anything; every consumer keeps
//   the pre-existing receipt fields and their meaning.
import Foundation

/// One bounded, monotonic record of the client-visible phases of a single
/// one-shot run. Built by the backend that actually performed the dispatch;
/// rendered once at the terminal point.
public struct TerminalLatencyPhases: Sendable {

    /// Closed phase vocabulary, in the ONLY order a run reaches them.
    public enum Phase: String, CaseIterable, Sendable, Equatable {
        /// Local engine-slot queue: from dispatch start until the single
        /// runtime-UID workload slot is held by this dispatch.
        case gate
        /// The `shell.start` request round trip (host pump grant + engine
        /// start). Its INTERNAL composition is engine-owned; see `unobserved`.
        case start
        /// Explicit one-shot stdin pages + the single trailing EOF page.
        case stdin
        /// Release wait: cursor polling until the engine's `leaseReleased`
        /// terminal proof (includes the engine's own stop proof and export).
        case run
        /// Terminal-proof handling on the client (outcome mapping, recovery
        /// metadata projection, gate release) up to the return.
        case settle
    }

    /// How the run actually ended. Closed set: an unclassified ending is not
    /// representable, so a caller must pick the honest branch it returns.
    public enum Terminal: String, Sendable, Equatable {
        case exited
        case timedOut
        case cancelled
        case failed
        case notStarted
    }

    /// What the client provably cannot separate inside the phases above.
    /// Constant by construction: it is a limitation of the observation
    /// point, not a measurement.
    public static let unobservedComponents = "engineStartInternals,engineStopAndExport"

    private let originNanos: UInt64
    private var lastNanos: UInt64
    private var spans: [(phase: Phase, millis: Int)] = []
    private var marked: Set<Phase> = []

    /// Current monotonic clock reading (uptime, unaffected by wall-clock
    /// changes). Exposed so the backend and tests use the same source.
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public init(originNanos: UInt64) {
        self.originNanos = originNanos
        self.lastNanos = originNanos
    }

    /// Closes the CURRENT phase at `nanos` and opens the next one. A phase is
    /// recorded exactly once; a repeated mark for the same phase keeps the
    /// FIRST measured span (a re-entry can never overwrite real timing). A
    /// mark that would run backwards (clock anomaly) records 0 ms instead of
    /// inventing or subtracting time.
    public mutating func mark(_ phase: Phase, at nanos: UInt64) {
        guard !marked.contains(phase) else { return }
        marked.insert(phase)
        let millis = nanos >= lastNanos ? Int((nanos - lastNanos) / 1_000_000) : 0
        spans.append((phase, millis))
        if nanos >= lastNanos { lastNanos = nanos }
    }

    /// Bounded, deterministic rendering for an explicitly-opened diagnostic
    /// surface (never ordinary product copy, never the model-visible receipt).
    /// Fixed vocabulary + at most five bounded integers, so the result stays
    /// far below 512 UTF-8 bytes without truncating any measured value.
    public func render(terminal: Terminal) -> String {
        let total = lastNanos >= originNanos ? (lastNanos - originNanos) / 1_000_000 : 0
        var parts: [String] = ["latency v1", "terminal=\(terminal.rawValue)"]
        for span in spans {
            parts.append("\(span.phase.rawValue)=\(span.millis)ms")
        }
        parts.append("total=\(total)ms")
        parts.append("unobserved=" + Self.unobservedComponents)
        return parts.joined(separator: " ")
    }
}
