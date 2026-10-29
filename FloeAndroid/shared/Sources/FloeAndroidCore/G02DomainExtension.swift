// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — explicit owner-bound optional-domain
// extension seam (temporary, privacy, and any later G02 domain package).
//
// MAIN architecture decision (MAIN_PRODUCT_FIRST_EXECUTION_DECISION_20261020
// and the ordinary-product scheduling change): the ordinary production base
// (provider configuration, credential vault, conversation history, memory/
// personalization, skills/MCP/capabilities, attachment staging, run domain,
// settings defaults/usage) must construct and register INDEPENDENTLY of the
// not-yet-integrated temporary/privacy domain packages. Those optional
// graphs must NOT:
//   * gate first-provider configuration or an ordinary Run,
//   * be advertised ready before their real package binds,
//   * fall back to ordinary persistence to impersonate temporary mode,
//   * be replaced with fake implementations or no-op successful ports.
//
// This file is the ONE minimal seam those successors bind into:
//   * a successor package vends a real `G02DomainExtension` and registers
//     it with `G02RuntimeComposition.shared.registerExtension(...)`;
//   * after the ordinary base installs (or immediately, when registered on
//     an already-live generation), the composition calls `attach` with the
//     live installed composition and the accepted generation;
//   * until `attach` succeeds, the extension's domains stay `blocked` with
//     precise missing dependencies, their handlers stay unregistered, and
//     every command addressing them keeps the frozen fail-closed
//     `runtimeUnavailable` refusal (RB1 invariant — no matrix widening);
//   * `beginRetirement(epoch:)` runs at RootStop with the EXACT epoch; a
//     stale epoch's retirement can never uninstall or clear a newer
//     generation's graph, fences or confirmations (the composition checks
//     epoch ownership before touching process-lane state).
//
// An `attach` failure MUST self-rollback: no binder keys, no registry
// processors, no owned work may outlive a failed attach. The ordinary base
// stays installed and truthful; the extension's domains stay blocked.
import Foundation

/// Stable identity of one optional-domain extension package.
public struct G02DomainExtensionID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// One optional G02 domain package bound to the accepted generation.
protocol G02DomainExtension: Sendable {

    var id: G02DomainExtensionID { get }

    /// The closed G02 domain keys owned by this extension. Only keys in
    /// `G02DomainKey.allCases` are valid; the readiness vocabulary never
    /// widens.
    var domains: [G02DomainKey] { get }

    /// Expected handler keys for one owned domain. Consulted ONLY after a
    /// successful `attach` — never to advertise an unbound extension.
    func expectedHandlerKeys(for domain: G02DomainKey) -> [String]

    /// Constructs the extension's REAL domain services over the SAME owned
    /// cluster (one original DatabaseManager) and registers its handlers on
    /// the accepted generation. Returns false on honest failure with NO
    /// partial state left behind (self-rollback); the ordinary base remains
    /// installed and the extension's domains remain blocked.
    func attach(to installed: G02InstalledComposition,
                gen: AndroidRuntimeBootstrap.Generation) async -> Bool

    /// Exact-epoch RootStop: fence new admissions and cancel the services
    /// the extension owns. Invoked before the run domain retires so
    /// cross-domain fences (e.g. a privacy global fence) still see the live
    /// run domain. Implementations must be epoch-exact: a call for an epoch
    /// they never attached is a no-op.
    func beginRetirement(epoch: UInt64) async

    /// Optional: claims whether a conversation is a live temporary session.
    /// Only the temporary extension answers true; every other extension
    /// (and the unbound ordinary product) keeps the default `false` — the
    /// truth, never a fabricated temporary flag.
    func isTemporaryConversation(_ conversationID: UUID, epoch: UInt64) async -> Bool

    /// Pre-drain retirement-preservation gate (workspace domain, Main
    /// 2026-10-24): true ONLY while this extension is attached for EXACTLY
    /// this epoch and may hold dirty bytes that need durable preservation
    /// before the root closes. The default is false — most domains have no
    /// such promise, and the ordinary shutdown path stays untouched.
    func requiresRetirementPreservation(epoch: UInt64) -> Bool

    /// The actual preservation pass, invoked BEFORE the first drain wait.
    /// Implementations perform REAL IO and return; the attached gate lease
    /// keeps the original drain honest until `release` proves every byte
    /// settled verified. No defaults fabricate work: the default is a no-op.
    func runRetirementPreservationIO(epoch: UInt64) async
}

extension G02DomainExtension {
    func isTemporaryConversation(_ conversationID: UUID, epoch: UInt64) async -> Bool {
        false
    }
    func requiresRetirementPreservation(epoch: UInt64) -> Bool {
        false
    }
    func runRetirementPreservationIO(epoch: UInt64) async {
        // No optional-domain package owes preservation unless it opts in.
    }
}

/// Registry of integrated optional-domain extensions. Ordinary product
/// ships with zero registered extensions: temporary and privacy domains are
/// honestly blocked-not-ready and their commands fail closed, while normal
/// chat works end to end.
public enum G02DomainExtensionKey {
    /// Temporary-chat domain package (RB5 successor). Not yet integrated.
    public static let temporary = G02DomainExtensionID("temporary")
    /// Privacy-clear domain package (privacy successor). Not yet integrated.
    public static let privacy = G02DomainExtensionID("privacy")
    /// G04 workspace file/editor domain package (workspace-facade successor,
    /// accepted additive D12/D14 ledger). Registered through the SAME
    /// prebootstrap seam; a failed attach never gates the ordinary base.
    public static let workspace = G02DomainExtensionID("workspace")
    /// G06 independent Notes assistant; failure never blocks the ordinary base.
    public static let notes = G02DomainExtensionID("notes")
}
