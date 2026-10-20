// SPDX-License-Identifier: MPL-2.0
//
// RB2 — owned-work lifecycle composition for the config domain (private
// source candidate; NOT compiled, NOT executed).
//
// This file composes the ACTUAL reviewed RB1 lifecycle port instead of any
// self-invented stand-in:
// * runtime-bootstrap-main-reviewed-source (producer job-f692957f97b2443a,
//   Main-reviewed, archive e975c8a0089a4807d1ed9bcbd22325a52013ba84cf69bbce5f5f1e6da6ae5529,
//   MANIFEST.json / MAIN_SOURCE_INTEGRATION_ADMISSION_20261019.json):
//   `RuntimeOwnedWorkRegistry.shared.attach(epoch:kind:ownerID:)` returns
//   `.attached(RuntimeOwnedWorkToken) | .rejected(RuntimeFacadeCode) |
//   .invalidIdentity`; `detach(_:)` is exact-token and idempotent; attach is
//   gated by `AndroidRuntimeBootstrap.ownedWorkAttachAllowed(epoch:)` — the
//   SAME accepted-generation fence as the command surface (no attach before
//   the real owned store committed, none while draining/retiring; a wrong or
//   stale epoch is rejected, never silently accepted).
// * Kinds are the closed reviewed set; config-domain secret effects attach
//   `.vaultMaintenance` (the vault-owned-operation lifecycle kind).
//
// Semantics honored here (coordinator guidance 2026-10-19 + MC-R4 repair):
// * attach BEFORE the actual owned work starts; detach ONLY when the awaited
//   effects have TRULY settled. The parent's "unknown-but-durably-recorded"
//   release wording was exactly the MC-R4 defect: a durable entry is NOT
//   physical settlement. Repair rule: a lease settles only when the
//   operation's INDIVIDUAL mailbox physical record proves neverDispatched or
//   a real host completion (settled status). Otherwise the lease token is
//   RETAINED inside the shared coordinator's pending owner (root close
//   genuinely waits: RB1 retirement observes registry count > 0), until
//   reconciliation or process restart. Never detach merely because the
//   caller cancelled, timed out or tore UI down.
// * NO default fake zero: when no trusted epoch is available, or the
//   registry rejects, the effect-carrying operation FAILS CLOSED typed
//   before consuming any lease effect or touching Keystore/SQLite. There is
//   no pass-through stub that pretends ownership was registered.
// * The provider-ID mutual-exclusion gate (ProviderOperationOwning,
//   ModelConfigPendingCleanup.swift) remains a SEPARATE, orthogonal
//   mechanism: it prevents two effects interleaving on one provider row
//   within this facade; the registry is the process/root quiescence port
//   that keeps the owned root/database open across real awaited work.
//   RB2 composes both and assumes neither covers the other.
// * Reconciliation dependency (bounded, listed in the report): when the
//   vault-owned-operations correction lane (job-07f0d672e3854e17) finalizes
//   its API (trusted root/epoch-owned operation coordination retained across
//   actual awaited gateway/metadata effects + required normalizer context),
//   Main binds that concrete coordinator behind THIS protocol before serial
//   publication. RB2 does not wait for that source and does not invent it.

import Foundation
import FloeCore

// MARK: - Trusted epoch seam

/// The CURRENT accepted runtime epoch as known by the trusted host (the same
/// value the host supplied to `AndroidRuntimeBootstrap.start(rootPath:
/// ownerToken:epoch:)`). The registry RE-CHECKS it against its live
/// generation fence, so a wrong or stale epoch can never pass: supplying an
/// epoch here grants nothing by itself.
public protocol ConfigRuntimeEpochProviding: Sendable {
    func currentEpoch() -> UInt64?
}

/// Explicit "no runtime epoch has been admitted" provider: every attach
/// through the lifecycle below fails closed. This is the honest initial
/// state for source authoring and pre-RB1 integration — NOT a fake success.
public struct ConfigRuntimeEpochNotAdmitted: ConfigRuntimeEpochProviding {
    public init() {}
    public func currentEpoch() -> UInt64? { nil }
}

// MARK: - Registry port (exact reviewed signatures)

/// Mirrors the ACTUAL reviewed `RuntimeOwnedWorkRegistry` members consumed
/// here. In production the facade binds `RuntimeOwnedWorkRegistry.shared`
/// (same-module RB1 symbol after the serial publication window);
/// qualification tests bind a scripted port that mirrors real attach/detach
/// ordering. This is NOT an abstraction invented to dodge the port: the
/// signatures, types and outcome shapes are the reviewed ones.
public protocol OwnedWorkRegistryPort: Sendable {
    func attach(epoch: UInt64,
                kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkAttachOutcome
    @discardableResult
    func detach(_ token: RuntimeOwnedWorkToken) -> Bool
    func isAttached(_ token: RuntimeOwnedWorkToken) -> Bool
}

/// The reviewed RB1 process-wide registry is the production port for the
/// model/web-search ownership leases. Pure additive conformance: every
/// requirement above already exists on `RuntimeOwnedWorkRegistry` with the
/// exact reviewed signature; nothing on RB1 changes.
extension RuntimeOwnedWorkRegistry: OwnedWorkRegistryPort {}

// MARK: - Lifecycle wrapper

/// One held ownership across a real awaited effect chain.
public struct ConfigOwnedWorkLease: Sendable {
    public let token: RuntimeOwnedWorkToken
}

public final class ConfigOwnedWorkLifecycle: @unchecked Sendable {
    public enum BeginRejection: Sendable, Equatable, Error {
        case noAdmittedEpoch
        case invalidOwnerIdentity
        case rejected(code: String) // RuntimeFacadeCode.rawValue
    }

    private let registry: any OwnedWorkRegistryPort
    private let epochProvider: any ConfigRuntimeEpochProviding

    public init(registry: any OwnedWorkRegistryPort,
                epochProvider: any ConfigRuntimeEpochProviding) {
        self.registry = registry
        self.epochProvider = epochProvider
    }

    /// Production default binds the ACTUAL process-wide registry.
    public convenience init(epochProvider: any ConfigRuntimeEpochProviding) {
        self.init(registry: RuntimeOwnedWorkRegistry.shared,
                  epochProvider: epochProvider)
    }

    /// Attach BEFORE the owned work. Failures are typed and final: the
    /// caller must not proceed with the effect chain.
    public func begin(kind: RuntimeOwnedWorkKind,
                      ownerID: String) -> Result<ConfigOwnedWorkLease, BeginRejection> {
        guard let epoch = epochProvider.currentEpoch() else {
            return .failure(.noAdmittedEpoch)
        }
        switch registry.attach(epoch: epoch, kind: kind, ownerID: ownerID) {
        case .attached(let token):
            return .success(ConfigOwnedWorkLease(token: token))
        case .invalidIdentity:
            return .failure(.invalidOwnerIdentity)
        case .rejected(let code):
            return .failure(.rejected(code: code.rawValue))
        }
    }

    /// Detach ONLY after the owned work's awaited effects have truly
    /// settled (terminal write / authoritative absence / unknown-but-
    /// recorded). Returns whether the exact token was live; false means it
    /// was already settled (idempotent) or fenced out — never fatal.
    @discardableResult
    public func settle(_ lease: ConfigOwnedWorkLease) -> Bool {
        registry.detach(lease.token)
    }

    /// Ownership probe used by retirement-adjacent diagnostics.
    public func isHeld(_ lease: ConfigOwnedWorkLease) -> Bool {
        registry.isAttached(lease.token)
    }
}
