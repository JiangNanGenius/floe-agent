// FloeAgentRuntime — single Linux engine workload slot ownership (Android).
//
// Module placement (Main ruling 2026-10-28): this admission vocabulary lives
// in FloeAgentRuntime, NOT FloeTools. `FloeAndroidLinuxAuthority` (the
// separate-UID runtime library) also links FloeTools directly and through
// FloeEnvironments, so adding it there would change that library's native
// compilation inputs and invalidate an otherwise unchanged child/runtime
// reuse for a feature that owns no runtime-component work. AgentRuntime is
// the only consumer of the registry, and FloeAndroidCore already depends on
// FloeAgentRuntime (shared/Package.swift:617), so the terminal owner can
// produce the fact with no dependency cycle and no new product edge.
//
// The Android Linux engine runs every workload in ONE dedicated runtime UID
// behind ONE serialized slot (`AndroidLinuxShellBackend.gateHolder`). A manual
// interactive terminal is human-owned work that holds that slot for its whole
// lifetime, so a model-proposed `exec.shell` in the SAME conversation can
// never start while the terminal is live: the backend answers
// `.notStarted` (exit 75) and nothing ran.
//
// This file is the single trusted vocabulary for that conflict. It owns NO
// process, NO slot, NO session and NO permission:
//
//  * `LinuxEngineSlotConflict` is a pure FACT (conversation + the native-
//    issued UI session identity + its Root generation). It is never
//    model-visible, never a tool, and never a grant.
//  * `LinuxEngineSlotConflictRule` is the pure admission rule so the decision
//    is testable without the Core composition. A conflict exists ONLY when
//    this conversation's own LIVE interactive terminal is the workload the
//    engine actually still holds a lease for. Another conversation's session,
//    a language/run session, an already-released lease or an unqualified
//    engine is NEVER reported as this conversation's terminal.
//  * `LinuxEngineSlotRegistry` is the real registry IMPLEMENTATION. It is
//    instance state, so the exact production logic is exercisable on a fresh
//    isolated registry per test without touching the process-wide producer.
//  * `LinuxEngineSlotAuthority` is the thin composition-root facade over
//    `LinuxEngineSlotRegistry.shared` — the one instance the runtime reads
//    and the terminal owner publishes into. There is no second registry, no
//    test-only reset and no bypass.
//
// Ruling implemented here (Main, 2026-10-28): the single slot / independent
// UID / lease / permission contracts are PRESERVED. Nothing in this file
// raises a concurrency cap, starts a duplicate worker, stops a terminal, or
// grants anything. It only makes the conflict an EXPLICIT human decision on
// the existing approval surface: no execution policy, reusable grant or
// full-access window may silently take the slot away from a manual terminal.
// The real close/join/settlement and the single approve-then-dispatch stay
// with the trusted host, before the command is dispatched — so a failed
// command is never replayed.

import Foundation

// MARK: - Fact

/// The trusted host fact behind the model admission gate: THIS conversation
/// owns a LIVE interactive terminal that is the workload actually holding the
/// single runtime-UID Linux engine slot.
public struct LinuxEngineSlotConflict: Sendable, Equatable, Hashable {
    public let conversationID: UUID
    /// The native-issued UI session identity that holds the slot (the SAME
    /// trusted interaction identity the terminal owner minted; never a
    /// fabricated model Run). Opaque: never displayed as prose, never
    /// model-visible, never persisted as an authority.
    public let sessionToken: String
    /// The Root generation that owns the session — the exact-epoch fence a
    /// later handoff must re-validate before it touches anything.
    public let nativeEpoch: UInt64

    public init(conversationID: UUID, sessionToken: String, nativeEpoch: UInt64) {
        self.conversationID = conversationID
        self.sessionToken = sessionToken
        self.nativeEpoch = nativeEpoch
    }

    /// The exact machine-readable conflict class carried over the EXISTING
    /// approval-escalation `reason` channel (no wire schema change, no new
    /// event kind, no new model-visible vocabulary). The trusted host maps
    /// this token to its own short localized copy and never renders it raw.
    public static let approvalReasonToken = "linuxEngineSlotHeldByOwnInteractiveTerminal"
}

// MARK: - Pure admission rule

/// The decision, isolated from the Core composition so it is deterministic
/// and unit-testable. Every input is a REAL read from an existing owner; the
/// rule only combines them and can therefore never widen authority.
public enum LinuxEngineSlotConflictRule {
    /// - Parameters:
    ///   - liveInteractiveSessionTokens: the conversation's own sessions that
    ///     its terminal owner still reports as alive AND interactive. At most
    ///     one exists (`G04TerminalLimits.maximumSessionsPerConversation == 1`),
    ///     so picking the first engine-owned match is not a policy choice.
    ///   - engineSlotBusy: the backend's own `isEngineSlotBusy()` truth.
    ///   - ownedEngineSessionKeys: `sessionKey` of every engine lease whose
    ///     real release has NOT been proven yet (`ownedSessions()`).
    /// - Returns: the conflict, or nil. Nil is the honest answer for an
    ///   unqualified engine, a released lease, a foreign conversation, a
    ///   language/run session and an unbound generation.
    public static func conflict(
        conversationID: UUID,
        nativeEpoch: UInt64,
        liveInteractiveSessionTokens: [String],
        engineSlotBusy: Bool,
        ownedEngineSessionKeys: [String]
    ) -> LinuxEngineSlotConflict? {
        // Generation 0 is "unbound": no ownership exists to report.
        guard nativeEpoch != 0 else { return nil }
        // A free slot is never a conflict, whatever the projection says.
        guard engineSlotBusy else { return nil }
        guard !ownedEngineSessionKeys.isEmpty else { return nil }
        let owned = Set(ownedEngineSessionKeys)
        guard let token = liveInteractiveSessionTokens.first(where: {
            !$0.isEmpty && owned.contains($0)
        }) else { return nil }
        return LinuxEngineSlotConflict(
            conversationID: conversationID,
            sessionToken: token,
            nativeEpoch: nativeEpoch
        )
    }
}

// MARK: - Which model tools need the slot

/// The model-facing tool names that must ACQUIRE the single engine slot before
/// they can start anything, so only those are ever gated by a conflict. Tools
/// that operate on an already-open session (`shell.exchange` / `shell.close` /
/// `shell.signal`) do not acquire it and stay unchanged.
public enum LinuxEngineSlotTools {
    public static let slotAcquiring: Set<String> = ["exec.shell", "shell.open"]

    public static func acquiresSlot(_ toolName: String) -> Bool {
        slotAcquiring.contains(toolName)
    }
}

// MARK: - Trusted producer

/// Implemented by the REAL terminal owner of the live generation. It answers
/// only from its own session table plus the backend's lease truth; it never
/// stops, kills, retries or grants anything.
public protocol LinuxEngineSlotConflictProbe: Sendable {
    func interactiveTerminalHoldingEngineSlot(
        conversationID: UUID
    ) async -> LinuxEngineSlotConflict?
}

// MARK: - Registry (the real implementation; instance state)

/// One trusted-producer registry. Instance state on purpose: the SAME
/// production logic can be exercised on a fresh isolated registry (tests, or
/// any future second composition) without mutating the process-wide producer,
/// and there is no test-only reset or bypass on the shared instance.
///
/// Fencing rules (Main review 2026-10-28):
///  * `register` accepts only a generation STRICTLY NEWER than the monotonic
///    accepted high-water mark — the same rule the terminal host mailbox binds
///    by, so neither a late retiring generation nor a delayed stale
///    registration can replace or resurrect a newer producer.
///  * `retire` is exact-generation and clears the producer WITHOUT resetting
///    that high-water mark. Erasing it would let `register(10) → retire(10)`
///    be followed by a delayed `register(9)`, publishing an ABA generation
///    that could match an older probe still in flight.
///  * a read is fenced twice: the registered generation is captured BEFORE the
///    await and re-checked AFTER it, so a generation replaced mid-flight can
///    never publish its stale session identity into this run's approval, and a
///    probe answering for a different conversation is discarded.
public final class LinuxEngineSlotRegistry: @unchecked Sendable {
    /// The process-wide composition-root instance: the runtime reads it and
    /// the live terminal owner publishes into it.
    public static let shared = LinuxEngineSlotRegistry()

    private let lock = NSLock()
    private var probe: (any LinuxEngineSlotConflictProbe)?
    /// The LIVE registered generation; 0 = nothing is registered.
    private var epoch: UInt64 = 0
    /// MONOTONIC accepted-generation high-water mark; never reset by `retire`.
    private var reservedEpoch: UInt64 = 0

    public init() {}

    /// Binds a generation's real terminal owner. False = refused (a generation
    /// this registry already accepted, or an older one, never overwrites or
    /// resurrects a newer one — including after a retirement).
    @discardableResult
    public func register(
        _ probe: any LinuxEngineSlotConflictProbe,
        epoch: UInt64
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch != 0, epoch > reservedEpoch else { return false }
        self.probe = probe
        self.epoch = epoch
        reservedEpoch = epoch
        return true
    }

    /// Exact-generation retirement. False = this generation is not the live
    /// registered one, so nothing was cleared. The high-water mark survives.
    @discardableResult
    public func retire(epoch: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard epoch != 0, epoch == self.epoch, probe != nil else { return false }
        probe = nil
        self.epoch = 0
        return true
    }

    /// The live registered generation, or nil when nothing is registered.
    public var registeredEpoch: UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard probe != nil, epoch != 0 else { return nil }
        return epoch
    }

    /// The monotonic high-water mark of every generation this registry ever
    /// accepted (0 = none). Retained across retirement.
    public var reservedHighWaterEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return reservedEpoch
    }

    private func current() -> (probe: any LinuxEngineSlotConflictProbe, epoch: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let probe, epoch != 0 else { return nil }
        return (probe, epoch)
    }

    /// The runtime's only read. `toolName` is filtered here so a caller can
    /// never widen the gate to a tool that does not need the slot. No
    /// registered producer means nil — a conflict is NEVER invented, so the
    /// ordinary approval path stays byte-identical.
    public func interactiveTerminalConflict(
        conversationID: UUID,
        toolName: String
    ) async -> LinuxEngineSlotConflict? {
        guard LinuxEngineSlotTools.acquiresSlot(toolName) else { return nil }
        guard let registered = current() else { return nil }
        guard let conflict = await registered.probe
            .interactiveTerminalHoldingEngineSlot(conversationID: conversationID)
        else { return nil }
        guard current()?.epoch == registered.epoch else { return nil }
        guard conflict.conversationID == conversationID,
              conflict.nativeEpoch == registered.epoch
        else { return nil }
        return conflict
    }
}

// MARK: - Composition-root facade

/// The thin facade the runtime and the terminal-owner composition use over
/// `LinuxEngineSlotRegistry.shared`. It adds no state and no second registry:
/// every call delegates to the one process-wide instance.
public enum LinuxEngineSlotAuthority {
    /// The shared composition-root registry (observability; no reset exists).
    public static var shared: LinuxEngineSlotRegistry { LinuxEngineSlotRegistry.shared }

    @discardableResult
    public static func register(
        _ probe: any LinuxEngineSlotConflictProbe,
        epoch: UInt64
    ) -> Bool {
        LinuxEngineSlotRegistry.shared.register(probe, epoch: epoch)
    }

    @discardableResult
    public static func retire(epoch: UInt64) -> Bool {
        LinuxEngineSlotRegistry.shared.retire(epoch: epoch)
    }

    public static var registeredEpoch: UInt64? {
        LinuxEngineSlotRegistry.shared.registeredEpoch
    }

    public static var reservedHighWaterEpoch: UInt64 {
        LinuxEngineSlotRegistry.shared.reservedHighWaterEpoch
    }

    public static func interactiveTerminalConflict(
        conversationID: UUID,
        toolName: String
    ) async -> LinuxEngineSlotConflict? {
        await LinuxEngineSlotRegistry.shared.interactiveTerminalConflict(
            conversationID: conversationID,
            toolName: toolName
        )
    }
}
