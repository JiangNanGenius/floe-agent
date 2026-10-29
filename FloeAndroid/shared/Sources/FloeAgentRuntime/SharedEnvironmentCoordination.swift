// FloeAgentRuntime — shared execution-environment concurrency coordination.
//
// The native execution backends are multi-client: the TinyEMU Linux guest
// already multiplexes concurrent commands and PTY sessions over one console
// channel. What the runtime must guarantee is that several clients of one
// root task — the parent run and its delegated children — are coordinated at
// the boundaries that are genuinely unsafe:
//
// * **Consumers** — every dispatched call that touches one environment
//   registers a short-lived consumer ticket for the duration of that call.
//   Consumer tickets never block each other, so unrelated commands, reads and
//   sessions keep running concurrently (the native guest behavior).
// * **Lifecycle** — start/stop/soft-restart/hard-restart/repair of one
//   environment take an exclusive lifecycle ticket. A lifecycle operation
//   waits (bounded) for any other lifecycle operation and for in-flight
//   consumers to drain first; if they do not drain within the bound it fails
//   with the real active-consumer list instead of tearing down a VM another
//   client is still using.
//
// Deliberately NOT a VM-per-child, and NOT a lock held for a client's whole
// lifetime: a consumer ticket exists only while one call is executing, and a
// lifecycle ticket only while one lifecycle operation runs.
//
// The coordinator is per runtime instance (one root task). It carries only
// opaque labels and environment identifiers; it never reads model data and
// never grants permission.

import Foundation
import FloeCore
import FloeTools

/// Explicit refusal of an environment lifecycle operation because other
/// clients are still using the shared backend. The runtime maps this to a
/// truthful failed tool result; the operation never silently proceeds.
public struct EnvironmentBusyError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// Runtime-side concurrency coordination for one root task's shared
/// execution environments.
public actor SharedEnvironmentCoordinator {
    /// One short-lived consumer of an environment, held for the duration of a
    /// single tool call. Tickets are opaque and compare by identity.
    public struct ConsumerTicket: Sendable, Hashable {
        public let id: UUID
        public let environmentID: String
        public let label: String

        init(id: UUID = UUID(), environmentID: String, label: String) {
            self.id = id
            self.environmentID = environmentID
            self.label = label
        }
    }

    /// One exclusive lifecycle operation on an environment.
    public struct LifecycleTicket: Sendable, Hashable {
        public let id: UUID
        public let environmentID: String
        public let label: String

        init(id: UUID = UUID(), environmentID: String, label: String) {
            self.id = id
            self.environmentID = environmentID
            self.label = label
        }
    }

    /// Bounded wait between admission attempts.
    static let pollIntervalNanoseconds: UInt64 = 20_000_000

    private var consumers: [ConsumerTicket] = []
    private var lifecycles: [LifecycleTicket] = []

    public init() {}

    // MARK: Consumers

    /// Admits one in-flight consumer call of an environment.
    ///
    /// Admission is direct when no lifecycle operation owns the environment.
    /// While a lifecycle operation (start/stop/restart/repair) holds its
    /// exclusive ticket, a late consumer MUST NOT dispatch into the backend:
    /// it waits, bounded by the same timeout/cancellation policy as the
    /// lifecycle op, and then fails with the real holder instead of racing a
    /// stop/restart. Consumers never block each other — once the lifecycle
    /// clears, concurrent consumers are admitted immediately.
    public func acquireConsumer(
        environmentID: String,
        label: String,
        timeout: TimeInterval,
        cancellation: CancellationToken? = nil
    ) async throws -> ConsumerTicket {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if cancellation?.isCancelled == true {
                throw FloeError.cancelled
            }
            if let lifecycle = lifecycles.first(where: { $0.environmentID == environmentID }) {
                guard Date() < deadline else {
                    throw EnvironmentBusyError(
                        message: "Environment \(environmentID) is restarting: \(lifecycle.label). "
                            + "The call \(label) was not started because a lifecycle operation owns this environment; "
                            + "retry when it has finished."
                    )
                }
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                continue
            }
            return admitConsumer(environmentID: environmentID, label: label)
        }
    }

    /// Immediate consumer admission. Only valid when the caller already knows
    /// no lifecycle operation owns the environment (the acquisition path
    /// checks this); production callers use `acquireConsumer`.
    private func admitConsumer(environmentID: String, label: String) -> ConsumerTicket {
        let ticket = ConsumerTicket(environmentID: environmentID, label: label)
        consumers.append(ticket)
        return ticket
    }

    /// Test seam: immediate admission, used only by coordinator unit tests
    /// that deliberately model an already-running consumer.
    func beginConsumer(environmentID: String, label: String) -> ConsumerTicket {
        admitConsumer(environmentID: environmentID, label: label)
    }

    /// Releases a consumer ticket. Unknown tickets are ignored, so a double
    /// release can never release another client's registration.
    public func endConsumer(_ ticket: ConsumerTicket) {
        consumers.removeAll { $0.id == ticket.id }
    }

    /// Number of calls currently executing against one environment. Used for
    /// truthful lifecycle feedback (and tests); never a permission signal.
    public func activeConsumerCount(environmentID: String) -> Int {
        consumers.filter { $0.environmentID == environmentID }.count
    }

    /// Labels of the calls currently executing against one environment, in
    /// registration order. Surfaced in explicit lifecycle refusal messages.
    public func activeConsumerLabels(environmentID: String) -> [String] {
        consumers.filter { $0.environmentID == environmentID }.map(\.label)
    }

    // MARK: Lifecycle

    /// Acquires exclusive ownership of an environment's lifecycle.
    ///
    /// Admission requires: no other lifecycle operation on the same
    /// environment, and no in-flight consumer of that environment. The wait is
    /// bounded; on timeout (or cancellation) this throws an explicit error
    /// carrying the real active labels — the caller must surface it instead of
    /// proceeding to disrupt work that is still running.
    public func acquireLifecycle(
        environmentID: String,
        label: String,
        timeout: TimeInterval,
        cancellation: CancellationToken? = nil
    ) async throws -> LifecycleTicket {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if cancellation?.isCancelled == true {
                throw FloeError.cancelled
            }
            let blockedByLifecycle = lifecycles.contains { $0.environmentID == environmentID }
            let activeConsumers = consumers.filter { $0.environmentID == environmentID }
            if !blockedByLifecycle, activeConsumers.isEmpty {
                let ticket = LifecycleTicket(environmentID: environmentID, label: label)
                lifecycles.append(ticket)
                return ticket
            }
            guard Date() < deadline else {
                var holders: [String] = []
                if blockedByLifecycle {
                    holders.append("another lifecycle operation")
                }
                holders.append(contentsOf: activeConsumers.map(\.label))
                throw EnvironmentBusyError(
                    message: "Environment \(environmentID) is busy: \(holders.joined(separator: ", ")). "
                        + "The lifecycle operation \(label) was not started because active clients were still using this environment; "
                        + "retry when they have finished."
                )
            }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    /// Releases a lifecycle ticket. Unknown tickets are ignored.
    public func releaseLifecycle(_ ticket: LifecycleTicket) {
        lifecycles.removeAll { $0.id == ticket.id }
    }

    /// True when nothing is in flight (tests / diagnostics).
    public func isIdle() -> Bool {
        consumers.isEmpty && lifecycles.isEmpty
    }

    /// Test seam: the live consumer labels across every environment.
    public func allConsumerLabels() -> [String] {
        consumers.map(\.label)
    }
}
