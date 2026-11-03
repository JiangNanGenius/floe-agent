// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — qualified cloud/MCP transport admission gate.
//
// Authority (job-7cd349b4cd6d4b55 spec): "Actual default-system TLS/
// productUID cloud transport admission is Main gated until existing
// transport/TLS qualifiers pass; read exact current qualified gate rather
// than hardcoded true/forever false." And: "MCP stdio/SSH honestly
// PendingEnvironment until G03 while supported HTTP/SSE/streamable+Skills
// capabilities are wired now."
//
// The gate is a REAL mutable process-local gate with one defined flip
// authority — Main's accepted transport AND TLS qualification receipts —
// never a hardcoded constant and never a model/envelope-reachable switch.
// Until it is flipped:
//   * `ProviderTransportAdmitting.admitsCloudNetwork` == false  -> probes and
//     provider/model use answer the frozen typed `transportUnavailable`;
//   * `MCPTransportAdmitting.admitsMCPNetwork` == false -> MCP HTTP/SSE/
//     streamable servers report the same typed unavailability;
//   * MCP stdio has a SEPARATE default-closed `admitsMCPStdio` flag. The
//     original factory/domain can consume the C02 adapter, but a live pipe
//     and its admission remain a C01 qualification; SSH/Linux execution
//     transports stay PendingEnvironment.
// The ordinary AI launch gate (`RunGateAdmission`) is unaffected: a missing
// model/secret still answers typed `needsConfiguration`/`credentialUnavailable`
// regardless of transport state — readiness is never manufactured to enable
// Send.
//
// Ordinary-product integration (2026-10-20): a truthful flip propagates to
// the LIVE installed composition's immutable RunContext snapshot
// (`isTransportQualified`), so a post-install Main qualification decision is
// real admission, not a forever-false snapshot and not a fake-true default.
import Foundation

/// Process-local qualified transport gate. One instance per generation,
/// retained by the G02 composition.
public final class G02QualifiedTransportGate: @unchecked Sendable,
    ProviderTransportAdmitting, MCPTransportAdmitting {

    private let lock = NSLock()
    private var admitted: Bool
    /// The C01 separated stdio pipe has its own admission. It is never
    /// derived from the cloud/HTTP flag: a local pipe can be qualified while
    /// the network transport is closed, and vice versa.
    private var stdioAdmitted: Bool
    private var stdioProbe: (@Sendable () async -> Bool)?
    private var admissionListener: (@Sendable (Bool) -> Void)?
    /// The typed refusal reason from the last REAL startup admission
    /// evaluation (nil while admitted). Diagnostics only; never a wire
    /// secret and never a model-reachable switch.
    private var startupRefusalReason: String?

    /// The current ACTUAL qualified state. At integration time the product
    /// transport/TLS qualification is Main-gated, so the default is false.
    /// Main flips this exactly once per qualification acceptance; tests may
    /// inject either value without touching global state.
    public init(qualified: Bool = false, stdioQualified: Bool = false) {
        self.admitted = qualified
        self.stdioAdmitted = stdioQualified
    }

    /// THE PRODUCT STARTUP PATH (MAIN_PRODUCT_TRANSPORT_STARTUP_ADMISSION_
    /// DECISION_20261020): admit runtime transport capability from the ACTUAL
    /// evaluated production transport/default-system-TLS initialization
    /// facts on this process/device — never from a private engineering
    /// receipt, never from a manual flip, never from source/port presence.
    /// Called by the composition BEFORE the immutable RunContext snapshot is
    /// constructed. A refusal keeps the gate closed with its typed reason.
    public func applyStartupAdmission(_ result: G02TransportStartupAdmission.Result) {
        let listener: (@Sendable (Bool) -> Void)? = lock.withLock {
            startupRefusalReason = result.admitted ? nil : result.reason
            guard admitted != result.admitted else { return nil }
            admitted = result.admitted
            return admissionListener
        }
        listener?(result.admitted)
    }

    /// The typed refusal reason of the last real startup evaluation (nil
    /// while admitted) — honest diagnostics for the trusted host readback.
    public var startupRefusal: String? {
        lock.withLock { startupRefusalReason }
    }

    /// Engineering/test wiring authority ONLY (qualified-receipt integration
    /// and unit wiring proof). It is NOT the shipping product path: an
    /// end-user device never requires a private receipt or a manual flip.
    /// A model envelope, command payload or UI state can never reach it.
    /// Re-admission is idempotent; revocation is allowed while no owned
    /// cloud work is attached (callers re-check at operation begin).
    public func markQualified(_ value: Bool) {
        let listener: (@Sendable (Bool) -> Void)? = lock.withLock {
            guard admitted != value else { return nil }
            admitted = value
            return admissionListener
        }
        listener?(value)
    }

    /// The composition registers the truthful propagation of an admission
    /// flip into the live RunContext snapshot. One listener; replaced by a
    /// newer composition install.
    func setAdmissionListener(_ listener: (@Sendable (Bool) -> Void)?) {
        lock.withLock {
            admissionListener = listener
        }
    }

    public var admitsCloudNetwork: Bool {
        lock.withLock { admitted }
    }

    public var admitsMCPNetwork: Bool {
        lock.withLock { admitted }
    }

    /// Qualified only after the trusted C01 pipe lane is installed and
    /// qualified for this process generation. The default is closed.
    public var admitsMCPStdio: Bool {
        lock.withLock { stdioAdmitted }
    }

    /// Main's accepted C01 qualification flip. It is not reachable from a
    /// model envelope, command payload or feature UI.
    public func markMCPStdioQualified(_ value: Bool) {
        lock.withLock { stdioAdmitted = value }
    }

    /// The trusted composition installs a live peer probe, never a model flag.
    public func setMCPStdioProbe(_ probe: (@Sendable () async -> Bool)?) {
        lock.withLock { stdioProbe = probe; stdioAdmitted = false }
    }

    public func refreshMCPStdioAdmission() async -> Bool {
        guard let probe = lock.withLock({ stdioProbe }) else { return admitsMCPStdio }
        let accepted = await probe()
        lock.withLock { stdioAdmitted = accepted }
        return accepted
    }
}

extension NSLock {
    /// Swift-6-safe scoped synchronous helper: the lock is never held across
    /// an `await` and never left unbalanced by an early exit.
    @inline(__always)
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
