// SPDX-License-Identifier: MPL-2.0
//
// FloeAndroidCore — LinuxReadinessIngress: the trusted, epoch-bound LIVE
// readiness ingress/invalidation authority for the Linux shell capability
// (G03-R3, job-3d39b56695c44bd2).
//
// What it replaces (and why the old seam was unacceptable):
// * The R2 production composition used `LinuxShellInjectedReadiness { ... }`
//   reading `LinuxShellQualificationFields` that ANY in-process caller could
//   set wholesale (`setQualificationFields(LinuxShellQualificationFields(
//   allFalse: false))` was literally an allTrue override), and that defaulted
//   permanently false because nothing ever fed it real facts. There was no
//   trusted way for the real host to say "this generation's runtime is
//   actually connected/installed/mapped" — the seam stayed compiled-false
//   forever and discovery had no live predicate to share with dispatch.
// * THIS authority is the replacement ingestion surface: every qualification
//   field must be INGESTED, per generation, as a typed bounded proof over the
//   real package distinct-UID / certificate / version / binder identity,
//   the live mailbox epoch, rootfs installation, the workspace mapping/lease
//   authority (read back from the ORIGINAL engine receipts — never a flag),
//   and the acknowledged single-workload contract. There is NO model-reachable
//   handler, NO bulk-true override, NO "installed-only" predicate, NO test
//   flag and NO host-interpreter fallback: an un-ingested field stays FALSE
//   and every consumer ANDs the fields with the live checks below.
// * Stale epoch, a lost/unqualified fact, a failed map or a stop must fence
//   dispatch AND discovery COHERENTLY while cleanup/poll stay usable:
//   every fact is stored keyed by its accepted generation epoch; reads
//   re-verify the live authorities (mailbox still bound to the SAME epoch,
//   native readback when present still equals it, the distinct runtime UID is
//   still not this process's UID, the authority/engine install still exists);
//   `invalidate` removes facts (used by generation fence and admission
//   suspend); nothing here closes the cleanup lane or the mailbox poller.
// * Qualification and ordinary route discovery read the SAME live
//   predicate: `RuntimeFacadeLinuxBindings.isCapabilityQualified` (dispatch +
//   registration + jobs advertisement) and `derivedFields()`/`liveReadiness`
//   all come from this one authority; the capability hub consults the same
//   gate for the linuxGuest family.
//
// Accepted epoch rule: `rootEpoch` must be non-zero, must equal the live
// mailbox generation when one is bound (the mailbox bind is itself a
// trusted-host, host-minted value), and must equal
// `G02NativeRootEpoch.readback()` whenever that readback exists. With no
// live generation at all (readback nil AND mailbox unbound) ingestion is
// REFUSED — there is nothing to be ready about, and refusing keeps the
// previous generation's facts from being overwritten under a guessed epoch.
//
// Diagnostics echo bounded tokens/digests only; raw proof values other than
// the host-supplied digests/versions are never logged or returned.
import Foundation
import CoreFoundation
import FloeCore
import FloeAndroidShellTools
import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Kinds + proofs

public enum LinuxReadinessFieldKind: String, CaseIterable, Sendable {
    case runtimeUidBoundary
    case engineConnected
    case mailboxEpoch
    case rootfsInstalled
    case workspaceMappingSynced
    case leaseAuthorityQualified
    case singleWorkloadAcknowledged
}

/// The typed ingress surface. Each case carries ONLY the constituents that
/// field actually needs; anything malformed is refused with a bounded code.
public enum LinuxReadinessProof: Sendable, Equatable {
    case runtimeUidBoundary(runtimeUID: Int32, certificateDigest: String,
                            packageVersion: String, binderIdentity: String)
    case engineConnected(binderIdentity: String, engineProtocolVersion: String)
    case mailboxEpoch
    case rootfsInstalled(receiptDigest: String, rootfsVersion: String)
    case workspaceMappingSynced(receiptDigest: String)
    case leaseAuthorityQualified(receiptDigest: String)
    case singleWorkloadAcknowledged(contractVersion: String)

    public var fieldKind: LinuxReadinessFieldKind {
        switch self {
        case .runtimeUidBoundary: return .runtimeUidBoundary
        case .engineConnected: return .engineConnected
        case .mailboxEpoch: return .mailboxEpoch
        case .rootfsInstalled: return .rootfsInstalled
        case .workspaceMappingSynced: return .workspaceMappingSynced
        case .leaseAuthorityQualified: return .leaseAuthorityQualified
        case .singleWorkloadAcknowledged: return .singleWorkloadAcknowledged
        }
    }

    /// Canonical stable text for the stored proof digest (diagnosis of WHICH
    /// ingestion settled, never the values themselves beyond what the host
    /// already advertised as digests).
    var canonicalText: String {
        switch self {
        case .runtimeUidBoundary(let uid, let cert, let version, let binder):
            return "rub|\(uid)|\(cert)|\(version)|\(binder)"
        case .engineConnected(let binder, let proto):
            return "ec|\(binder)|\(proto)"
        case .mailboxEpoch:
            return "mb"
        case .rootfsInstalled(let digest, let version):
            return "rf|\(digest)|\(version)"
        case .workspaceMappingSynced(let digest):
            return "wm|\(digest)"
        case .leaseAuthorityQualified(let digest):
            return "la|\(digest)"
        case .singleWorkloadAcknowledged(let contract):
            return "sw|\(contract)"
        }
    }
}

public enum LinuxReadinessIngressOutcome: Sendable, Equatable {
    case accepted(field: LinuxReadinessFieldKind, epoch: UInt64)
    case refused(code: String)
}

// MARK: - Authority

public final class LinuxReadinessIngress: @unchecked Sendable {
    public static let shared = LinuxReadinessIngress()

    private struct AcceptedFact {
        let epoch: UInt64
        let proofDigest: String
        let ingestedAt: Date
    }

    /// The ONE verified peer a generation's readiness tuple may describe.
    /// Established ONLY by the runtime-UID boundary fact; every other fact
    /// must belong to the same anchored peer (no cross-peer qualification).
    private struct PeerAnchor {
        let epoch: UInt64
        let runtimeUID: Int32
        let certificateDigest: String
        let binderIdentity: String
    }

    private let lock = NSLock()
    private var facts: [LinuxReadinessFieldKind: AcceptedFact] = [:]
    private var peerAnchor: PeerAnchor?
    private var lastRefusal: String?
    /// The generation whose admissions are SUSPENDED. While set and equal
    /// to the live accepted epoch, POSITIVE readiness is blocked for every
    /// consumer (derivedFields fail closed, ingestion of new facts is
    /// refused): a late host callback can never re-qualify a suspended
    /// Root/mailbox generation that is still bound only for cleanup and
    /// proof drain. The block lifts ONLY on a real admission transition:
    /// `resumeAdmissions(at:)` from the trusted host for the SAME live
    /// epoch, or automatically once the live accepted epoch MOVES (a new
    /// generation re-binds with a strictly newer epoch — its facts then
    /// must be re-ingested from scratch anyway). Cleanup lanes are
    /// untouched by this fence.
    private var suspendedEpoch: UInt64 = 0

    init() {}

    // MARK: Live epoch authority

    /// The accepted generation for INGRESS: the live (non-closed) mailbox
    /// epoch (trusted host value) cross-checked with the native readback
    /// when present. Nil only when NO live authority exists at all.
    static func liveAcceptedEpoch() -> UInt64? {
        let readback = G02NativeRootEpoch.readback()
        let snapshot = LinuxShellMailbox.shared.snapshotForTesting()
        if snapshot.epoch != 0, !snapshot.closed {
            if let readback, readback != snapshot.epoch {
                // A readback present but DIFFERENT from the mailbox bind is
                // a mismatched generation: nothing is "live accepted".
                return nil
            }
            return snapshot.epoch
        }
        return readback
    }

    /// A live native/mailbox readback must EXIST and EQUAL `epoch`. Absence
    /// of a live authority is a REFUSAL (never "no conflict => accept"):
    /// without a live generation there is nothing to be ready about, and we
    /// must not let a caller overwrite the previous generation's facts under
    /// a guessed/unbound epoch. Returns the live epoch, or a typed refusal.
    private static func requireLiveEpoch(_ epoch: UInt64) -> LinuxReadinessIngressOutcome? {
        if let live = liveAcceptedEpoch() {
            guard live == epoch else {
                return .refused(code: "epochNotLive")
            }
            return nil
        }
        // No live authority. Two honest shapes must stay distinguishable
        // (frozen contract: CLOSED mailbox refuses `mailboxClosed` AT
        // INGESTION; absence of authority refuses `noLiveAuthority`):
        //  * A CLOSED mailbox that still carries THIS exact bound epoch is
        //    a positively FENCED generation (bound, then fenced by close).
        //    On the mailbox-only host shape (no bootstrap readback) it is
        //    the only named authority left, so the typed `mailboxClosed`
        //    refusal fires here — never masked as a generic absence, and
        //    never reachable as dead code.
        //  * An epoch no live or fenced mailbox generation names (never
        //    bound, epoch 0, or a foreign epoch) is an ABSENCE:
        //    `noLiveAuthority` (absence is never authority).
        // The bootstrap-live shape (native readback answers while the
        // shell mailbox is closed) is untouched: `liveAcceptedEpoch()`
        // returns non-nil there and the per-field mailbox/lease guards
        // below keep producing their frozen codes unchanged.
        let fenced = LinuxShellMailbox.shared.snapshotForTesting()
        if fenced.closed, fenced.epoch == epoch {
            return .refused(code: "mailboxClosed")
        }
        return .refused(code: "noLiveAuthority")
    }

    // MARK: Ingress (trusted host only)

    public func ingest(_ proof: LinuxReadinessProof, rootEpoch: UInt64) -> LinuxReadinessIngressOutcome {
        let kind = proof.fieldKind
        guard rootEpoch != 0 else {
            return refuse("epochZero")
        }
        // POSITIVE live authority required (Main review 2026-10-22): absence
        // of a conflict is NOT authority. No live generation => refuse.
        if let refusal = Self.requireLiveEpoch(rootEpoch) { return refusal }
        // A suspended generation stays readiness-blocked even while its
        // Root/mailbox remain bound for cleanup/proof: late callbacks cannot
        // re-qualify it. Lifts only on resumeAdmissions(same epoch) or a new
        // (different) live epoch.
        lock.lock()
        let suspended = suspendedEpoch
        lock.unlock()
        guard suspended == 0 || suspended != rootEpoch else {
            return refuse("admissionSuspended")
        }
        // Per-field structural + LIVE authority validation. ANY failure
        // leaves the previous state untouched.
        switch proof {
        case .runtimeUidBoundary(let runtimeUID, let cert, let version, let binder):
            guard runtimeUID >= 0, runtimeUID != Int32(getuid()) else { return refuse("uidNotDistinct") }
            guard Self.isHex64(cert) else { return refuse("certificateMalformed") }
            guard Self.asciiToken(version, maximum: 96), Self.asciiToken(binder, maximum: 128) else {
                return refuse("identityTokenMalformed")
            }
            // Anchor the generation to ONE verified peer. A re-ingestion at
            // the same epoch with a DIFFERENT runtime UID / certificate /
            // binder is a peer swap and is refused (never silently replaced).
            if let conflict = peerBoundaryConflict(rootEpoch: rootEpoch, runtimeUID: runtimeUID,
                                                   cert: cert, binder: binder) {
                return conflict
            }
        case .engineConnected(let binder, let proto):
            guard Self.asciiToken(binder, maximum: 128), Self.asciiToken(proto, maximum: 64) else {
                return refuse("engineIdentityMalformed")
            }
            // The connected engine must be the SAME peer already anchored by
            // the runtime-UID boundary fact for this epoch; two different
            // peers may never combine into one qualified tuple.
            guard let anchor = currentPeerAnchor(rootEpoch: rootEpoch) else {
                return refuse("peerNotAnchored")
            }
            guard anchor.binderIdentity == binder else { return refuse("peerBinderMismatch") }
        case .mailboxEpoch:
            // A CLOSED mailbox is a fenced generation: refuse the fact at
            // INGESTION, not only in the derived UI field. LIVE cross-check
            // against the ORIGINAL mailbox bind (never a caller echo).
            let snap = LinuxShellMailbox.shared.snapshotForTesting()
            guard !snap.closed else { return refuse("mailboxClosed") }
            guard snap.epoch == rootEpoch else { return refuse("mailboxEpochMismatch") }
            guard currentPeerAnchor(rootEpoch: rootEpoch) != nil else { return refuse("peerNotAnchored") }
        case .rootfsInstalled(let digest, let version):
            guard currentPeerAnchor(rootEpoch: rootEpoch) != nil else { return refuse("peerNotAnchored") }
            guard Self.isHex64(digest) else { return refuse("rootfsReceiptMalformed") }
            guard Self.asciiToken(version, maximum: 96) else { return refuse("rootfsVersionMalformed") }
        case .workspaceMappingSynced(let digest):
            guard currentPeerAnchor(rootEpoch: rootEpoch) != nil else { return refuse("peerNotAnchored") }
            guard Self.isHex64(digest) else { return refuse("mappingReceiptMalformed") }
            // The mapping fact may ONLY rest on a REAL engine receipt: the
            // ORIGINAL transfer authority must be installed for the live
            // generation AND the claimed digest must be read back as the
            // terminal index of a TERMINAL-marked session under the accepted
            // transfer root whose marker proves the CURRENT root epoch
            // (never a flag, never an old/other-generation terminal digest).
            switch LinuxWorkspaceAuthority.lookupTerminalReceipt(matchingDigest: digest,
                                                                 rootEpoch: rootEpoch) {
            case .found:
                break
            case .noAuthority:
                return refuse("workspaceAuthorityNotInstalled")
            case .noEngine:
                return refuse("workspaceEngineNotInstalled")
            case .notFound:
                return refuse("mappingReceiptUnreadBack")
            case .epochMismatch:
                return refuse("mappingReceiptEpochMismatch")
            case .notSynced:
                return refuse("mappingReceiptNotSynced")
            case .unsafePath:
                return refuse("mappingReceiptTreeUnsafe")
            case .scanTruncated:
                return refuse("mappingReceiptScanTruncated")
            }
        case .leaseAuthorityQualified(let digest):
            guard currentPeerAnchor(rootEpoch: rootEpoch) != nil else { return refuse("peerNotAnchored") }
            guard Self.isHex64(digest) else { return refuse("leaseReceiptMalformed") }
            // Lease authority rides the SAME live, OPEN mailbox generation
            // (the lease binder is the mailbox). A closed mailbox refuses here
            // too, not merely in the derived field.
            let snap = LinuxShellMailbox.shared.snapshotForTesting()
            guard !snap.closed, snap.epoch == rootEpoch else {
                return refuse(snap.closed ? "mailboxClosed" : "leaseWithoutLiveMailbox")
            }
        case .singleWorkloadAcknowledged(let contract):
            guard currentPeerAnchor(rootEpoch: rootEpoch) != nil else { return refuse("peerNotAnchored") }
            guard Self.asciiToken(contract, maximum: 64) else { return refuse("contractTokenMalformed") }
        }
        let digest = FloeDigest.sha256Hex(Data(proof.canonicalText.utf8))
        lock.lock()
        facts[kind] = AcceptedFact(epoch: rootEpoch, proofDigest: digest, ingestedAt: Date())
        if case .runtimeUidBoundary(let runtimeUID, let cert, _, let binder) = proof {
            peerAnchor = PeerAnchor(epoch: rootEpoch, runtimeUID: runtimeUID,
                                    certificateDigest: cert, binderIdentity: binder)
        }
        lastRefusal = nil
        lock.unlock()
        return .accepted(field: kind, epoch: rootEpoch)
    }

    /// The runtime-UID boundary is the ONLY fact that establishes the peer.
    /// Returns a refusal if this epoch already anchored a DIFFERENT peer.
    private func peerBoundaryConflict(rootEpoch: UInt64, runtimeUID: Int32, cert: String,
                                      binder: String) -> LinuxReadinessIngressOutcome? {
        lock.lock(); let anchor = peerAnchor; lock.unlock()
        guard let anchor, anchor.epoch == rootEpoch else { return nil }
        if anchor.runtimeUID != runtimeUID || anchor.certificateDigest != cert
            || anchor.binderIdentity != binder {
            return .refused(code: "peerBoundaryConflict")
        }
        return nil // idempotent re-ingestion of the SAME peer
    }

    private func currentPeerAnchor(rootEpoch: UInt64) -> PeerAnchor? {
        lock.lock(); defer { lock.unlock() }
        guard let anchor = peerAnchor, anchor.epoch == rootEpoch else { return nil }
        return anchor
    }

    /// Invalidation: a lost/unqualified fact, failed map, stop or generation
    /// fence removes facts. Removal never auto-restores: the host must
    /// re-ingest real evidence.
    @discardableResult
    public func invalidate(_ kind: LinuxReadinessFieldKind?, reason: String) -> Bool {
        let bounded = String(reason.prefix(48))
        guard bounded.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }), !bounded.isEmpty else {
            return false
        }
        lock.lock()
        if let kind {
            facts.removeValue(forKey: kind)
            // If the anchor-defining boundary fact dies, the whole peer
            // binding dies with it: every remaining fact loses its verified
            // peer and must be re-ingested (no orphan qualification).
            if kind == .runtimeUidBoundary { peerAnchor = nil }
        } else {
            facts.removeAll()
            peerAnchor = nil
        }
        lastRefusal = "invalidated:\(kind?.rawValue ?? "all")"
        lock.unlock()
        return true
    }

    /// Trusted-host admission fence for a GENERATION (called from
    /// `RuntimeFacadeLinuxBindings.suspendAdmissions`). Marks the CURRENT
    /// live epoch suspended and clears its facts: positive readiness can
    /// NOT return for that epoch until either `resumeAdmissions` (explicit
    /// legitimate transition) or a strictly newer accepted epoch. Cleanup
    /// lanes (runtime-cleanup mailbox, mailbox poll) are NOT touched here.
    @discardableResult
    public func suspendAdmissions(epoch: UInt64) -> Bool {
        guard epoch != 0, Self.liveAcceptedEpoch() == epoch else { return false }
        lock.lock()
        suspendedEpoch = epoch
        facts.removeAll()
        peerAnchor = nil
        lastRefusal = "admissionSuspended"
        lock.unlock()
        return true
    }

    /// The explicit legitimate re-admission for the SAME still-live epoch
    /// (trusted host only). Clears the suspend mark; readiness then requires
    /// full re-ingestion of every real fact for the generation (facts were
    /// dropped at suspend) — a resume alone never re-qualifies anything.
    @discardableResult
    public func resumeAdmissions(epoch: UInt64) -> Bool {
        guard epoch != 0 else { return false }
        lock.lock()
        let didClear = suspendedEpoch == epoch
        if didClear { suspendedEpoch = 0 }
        lock.unlock()
        return didClear
    }

    public var admissionsSuspendedForEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return suspendedEpoch
    }

    // MARK: Derived live state

    /// The live derived fields: each fact must (a) exist, (b) carry the
    /// CURRENT live accepted epoch, and (c) pass its LIVE re-check. A
    /// generation change, mailbox rebind/close, authority/engine uninstall
    /// (impossible mid-generation, checked anyway) or a replaced UID
    /// relationship turns the field false without any explicit call.
    public func derivedFields() -> LinuxShellQualificationFields {
        let live = Self.liveAcceptedEpoch()
        lock.lock()
        let snapshot = facts
        let anchor = peerAnchor
        let suspended = suspendedEpoch
        lock.unlock()
        var fields = LinuxShellQualificationFields()
        // Positive readiness is blocked outright for a suspended live
        // generation (discovery AND dispatch read this one authority).
        guard let live, live != suspended else { return fields }
        for (kind, fact) in snapshot {
            // A fact only lives while its ACCEPTED epoch is still the live
            // generation: a mailbox close, rebind to a newer epoch or a
            // mismatched native readback drops every field coherently.
            guard fact.epoch == live else { continue }
            switch kind {
            case .runtimeUidBoundary:
                // Distinctness was proven at acceptance against THIS
                // process's UID; the anchor still describes this epoch.
                guard anchor?.epoch == live else { continue }
                fields.runtimeUidBoundaryVerified = true
            case .engineConnected:
                guard anchor?.epoch == live else { continue }
                fields.engineConnected = true
            case .mailboxEpoch:
                let snapshot = LinuxShellMailbox.shared.snapshotForTesting()
                fields.mailboxEpochBound = snapshot.epoch == live && !snapshot.closed
            case .rootfsInstalled:
                fields.rootfsQualified = true
            case .workspaceMappingSynced:
                // The receipt-backed fact only lives while the ORIGINAL
                // authority/engine transfer base is live (production reads
                // the installed authority + engine; a host test may supply
                // an explicit trusted root through the documented seam).
                fields.workspaceMappingSynced = LinuxWorkspaceAuthority.transferAuthorityLive
            case .leaseAuthorityQualified:
                let snapshot = LinuxShellMailbox.shared.snapshotForTesting()
                fields.leaseAuthorityQualified = snapshot.epoch == live && !snapshot.closed
            case .singleWorkloadAcknowledged:
                fields.singleWorkloadContractAcknowledged = true
            }
        }
        return fields
    }

    public func isFullyIngressed() -> Bool {
        derivedFields().allFieldsTrue
    }

    /// Accepted kinds + digests for stats (bounded; never raw proofs).
    public func statusJSON() -> String {
        let live = Self.liveAcceptedEpoch()
        lock.lock()
        let snapshot = facts
        let refusal = lastRefusal
        let anchor = peerAnchor
        let suspended = suspendedEpoch
        lock.unlock()
        var accepted: [String: [String: Any]] = [:]
        for (kind, fact) in snapshot {
            accepted[kind.rawValue] = ["epoch": fact.epoch,
                                       "proofDigest": fact.proofDigest,
                                       "live": fact.epoch == live]
        }
        var peerObject: [String: Any] = ["anchored": anchor != nil]
        if let anchor {
            // Only the ANCHOR DIGEST crosses the ABI — never the raw binder
            // identity token, UID or version (they stay in-process).
            let canonical = "\(anchor.epoch)|\(anchor.runtimeUID)|\(anchor.certificateDigest)|\(anchor.binderIdentity)"
            peerObject["epoch"] = anchor.epoch
            peerObject["anchorDigest"] = FloeDigest.sha256Hex(Data(canonical.utf8))
        }
        let fields = derivedFields()
        let object: [String: Any] = [
            "liveEpoch": live ?? 0,
            "accepted": accepted,
            "peer": peerObject,
            "suspendedEpoch": suspended,
            "fields": [
                "runtimeUidBoundaryVerified": fields.runtimeUidBoundaryVerified,
                "engineConnected": fields.engineConnected,
                "mailboxEpochBound": fields.mailboxEpochBound,
                "rootfsQualified": fields.rootfsQualified,
                "workspaceMappingSynced": fields.workspaceMappingSynced,
                "leaseAuthorityQualified": fields.leaseAuthorityQualified,
                "singleWorkloadContractAcknowledged": fields.singleWorkloadContractAcknowledged,
            ],
            "lastRefusal": refusal ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{\"error\":\"stats_encoding\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Test/reset hygiene (mirrors the module's existing resetForTesting
    /// precedent; never a runtime toggle or qualification flag).
    internal func resetForTesting() {
        lock.lock()
        facts.removeAll()
        peerAnchor = nil
        suspendedEpoch = 0
        lastRefusal = nil
        lock.unlock()
    }

    private func refuse(_ code: String) -> LinuxReadinessIngressOutcome {
        lock.lock()
        lastRefusal = code
        lock.unlock()
        return .refused(code: code)
    }

    private static func isHex64(_ text: String) -> Bool {
        text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func asciiToken(_ text: String, maximum: Int) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximum else { return false }
        return text.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }
}

// MARK: - The live readiness predicate (same authority for dispatch)

/// The production readiness answer: NOT a compiled-false constant and NOT a
/// boolean override — a live read of the ingress authority above. Defaults
/// false exactly until the trusted host ingests every real fact for the
/// CURRENT generation; every loss path (stale epoch, invalidation, mailbox
/// rebind away from the accepted generation) flips it back false.
public enum LinuxShellLiveReadiness {
    public static func makeInjected() -> LinuxShellInjectedReadiness {
        LinuxShellInjectedReadiness {
            // `derivedFields()` already requires EVERY accepted fact to carry
            // the CURRENT live accepted epoch (mailbox non-closed + native
            // cross-check). The per-instance compose/epoch gates live in
            // `RuntimeFacadeLinuxBindings.isCapabilityQualified`, so this
            // predicate is the single shared source for dispatch AND
            // discovery without pinning one bindings instance.
            LinuxReadinessIngress.shared.isFullyIngressed()
        }
    }
}

// MARK: - Trusted-host C ABI (JNI; never a model route)

private func readinessReply(_ object: [String: Any], buffer: UnsafeMutablePointer<CChar>?,
                            capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return LinuxRuntimeCleanupCode.invalidArguments }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          data.count + 1 <= Int(capacity) else {
        return LinuxRuntimeCleanupCode.bufferTooSmall
    }
    for (index, byte) in data.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[data.count] = 0
    return Int32(data.count)
}

private func readinessCString(_ pointer: UnsafePointer<CChar>?, maximum: Int) -> String? {
    guard let pointer else { return nil }
    var bytes: [UInt8] = []
    var index = 0
    while index < maximum {
        let byte = UInt8(bitPattern: pointer[index])
        if byte == 0 { break }
        bytes.append(byte)
        index += 1
    }
    guard index < maximum, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
    return text
}

private func readinessHex(_ text: String?) -> String? {
    guard let text, text.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
    return text
}

private func readinessToken(_ text: String?, maximum: Int) -> String? {
    guard let text, !text.isEmpty, text.utf8.count <= maximum,
          text.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { return nil }
    return text
}

/// Exact JSON-number → Int64 extraction following the module's proven
/// canonical classification (G02DomainBinder.designValue): a CF boolean is
/// refused BEFORE any number bridge, integer encodings use `int64Value`
/// exactly, unsigned encodings must fit Int64, and a floating encoding is
/// accepted ONLY when finite and integral within exact-integer range.
/// Anything else (unknown encoding included) is malformed — never a lossy
/// bridge. JSONSerialization without .usesDecimalNumbers never boxes a
/// decimal here, so an NSDecimalNumber-shaped value also refuses.
private func readinessExactInt64(_ number: NSNumber) -> Int64? {
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    switch String(cString: number.objCType) {
    case "c", "i", "s", "l", "q":
        return number.int64Value
    case "C", "I", "S", "L", "Q":
        let unsigned = number.uint64Value
        guard unsigned <= UInt64(Int64.max) else { return nil }
        return Int64(unsigned)
    case "f", "d":
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(),
              abs(value) <= 9_007_199_254_740_991 else { return nil }
        return number.int64Value
    default:
        return nil
    }
}

/// The runtime-UID boundary fact carries an `int >= 0` peer UID
/// (FROZEN_HOST_CONTRACT.json), typed Int32 inside Core. Values outside
/// 0...Int32.max REFUSE as malformed instead of truncating through the
/// `intValue` bridge (an overflowed NSNumber must never anchor a
/// DIFFERENT UID than the host proved). Identity/distinctness re-checks
/// inside ingest are unchanged.
private func readinessRuntimeUID(_ number: NSNumber) -> Int32? {
    guard let value = readinessExactInt64(number),
          value >= 0, value <= Int64(Int32.max) else { return nil }
    return Int32(value)
}

/// Ingest one typed readiness fact for the trusted host. The field name
/// selects the case; the proof JSON carries ONLY that field's constituents.
/// Reply: {"ok":true,"field":...,"epoch":...} or {"ok":false,"code":...}.
@_cdecl("floe_linux_readiness_ingest")
public func floeLinuxReadinessIngest(_ field: UnsafePointer<CChar>?, _ rootEpoch: UInt64,
                                     _ proofJson: UnsafePointer<CChar>?, _ proofLen: Int32,
                                     _ outBuffer: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    guard let fieldText = readinessCString(field, maximum: 48),
          let kind = LinuxReadinessFieldKind(rawValue: fieldText),
          rootEpoch != 0, rootEpoch <= UInt64(Int64.max) else {
        return readinessReply(["ok": false, "code": "invalidField"], buffer: outBuffer, capacity: capacity)
    }
    guard proofLen > 0, proofLen <= 4_096, let proofJson else {
        return readinessReply(["ok": false, "code": "proofMissing"], buffer: outBuffer, capacity: capacity)
    }
    let data = Data(bytes: proofJson, count: Int(proofLen))
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return readinessReply(["ok": false, "code": "proofMalformed"], buffer: outBuffer, capacity: capacity)
    }
    let proof: LinuxReadinessProof?
    switch kind {
    case .runtimeUidBoundary:
        if let uidNumber = object["runtimeUID"] as? NSNumber,
           let uid = readinessRuntimeUID(uidNumber),
           let cert = readinessHex(object["certificateDigest"] as? String),
           let version = readinessToken(object["packageVersion"] as? String, maximum: 96),
           let binder = readinessToken(object["binderIdentity"] as? String, maximum: 128) {
            proof = .runtimeUidBoundary(runtimeUID: uid, certificateDigest: cert,
                                        packageVersion: version, binderIdentity: binder)
        } else { proof = nil }
    case .engineConnected:
        if let binder = readinessToken(object["binderIdentity"] as? String, maximum: 128),
           let proto = readinessToken(object["engineProtocolVersion"] as? String, maximum: 64) {
            proof = .engineConnected(binderIdentity: binder, engineProtocolVersion: proto)
        } else { proof = nil }
    case .mailboxEpoch:
        proof = .mailboxEpoch
    case .rootfsInstalled:
        if let digest = readinessHex(object["receiptDigest"] as? String),
           let version = readinessToken(object["rootfsVersion"] as? String, maximum: 96) {
            proof = .rootfsInstalled(receiptDigest: digest, rootfsVersion: version)
        } else { proof = nil }
    case .workspaceMappingSynced:
        if let digest = readinessHex(object["receiptDigest"] as? String) {
            proof = .workspaceMappingSynced(receiptDigest: digest)
        } else { proof = nil }
    case .leaseAuthorityQualified:
        if let digest = readinessHex(object["receiptDigest"] as? String) {
            proof = .leaseAuthorityQualified(receiptDigest: digest)
        } else { proof = nil }
    case .singleWorkloadAcknowledged:
        if let contract = readinessToken(object["contractVersion"] as? String, maximum: 64) {
            proof = .singleWorkloadAcknowledged(contractVersion: contract)
        } else { proof = nil }
    }
    guard let proof else {
        return readinessReply(["ok": false, "code": "proofIncomplete"], buffer: outBuffer, capacity: capacity)
    }
    switch LinuxReadinessIngress.shared.ingest(proof, rootEpoch: rootEpoch) {
    case .accepted(let field, let epoch):
        return readinessReply(["ok": true, "field": field.rawValue, "epoch": epoch],
                              buffer: outBuffer, capacity: capacity)
    case .refused(let code):
        return readinessReply(["ok": false, "code": code], buffer: outBuffer, capacity: capacity)
    }
}

/// Invalidate one field ("*" = all). Used by the host on binder death,
/// engine disconnect, failed map, or stop. Facts never auto-restore.
@_cdecl("floe_linux_readiness_invalidate")
public func floeLinuxReadinessInvalidate(_ field: UnsafePointer<CChar>?,
                                         _ reason: UnsafePointer<CChar>?,
                                         _ outBuffer: UnsafeMutablePointer<CChar>?,
                                         _ capacity: Int32) -> Int32 {
    let text = readinessCString(field, maximum: 48)
    let reasonText = readinessCString(reason, maximum: 48) ?? "hostInvalidate"
    let kind: LinuxReadinessFieldKind?
    if text == nil || text == "*" {
        kind = nil
    } else if let text, let parsed = LinuxReadinessFieldKind(rawValue: text) {
        kind = parsed
    } else {
        return readinessReply(["ok": false, "code": "invalidField"], buffer: outBuffer, capacity: capacity)
    }
    let done = LinuxReadinessIngress.shared.invalidate(kind, reason: reasonText)
    return readinessReply(["ok": done, "scope": kind?.rawValue ?? "all"], buffer: outBuffer, capacity: capacity)
}

/// First-use activation (trusted host, AFTER the full real fact set for the
/// CURRENT accepted generation has been ingested — including the
/// workspaceMappingSynced receipt produced by the NON-EXECUTING workspace
/// preflight described in FROZEN_HOST_CONTRACT.json): attempts the ORIGINAL
/// registration entries exactly once per call. It NEVER fabricates
/// qualification: with any fact missing the existing gates refuse and
/// nothing registers (ordinary discovery keeps answering notImplemented
/// through the same live predicate). Jobs advertisement reuses
/// `RuntimeFacadeJobBindings.publishToolsIfQualified` (same gate, no new
/// system). Reply: {"ok":true,"shellRegistered":...,"jobsAdvertised":true}
/// or {"ok":false,"code":...}.
@_cdecl("floe_linux_readiness_activate_registration")
public func floeLinuxReadinessActivateRegistration(_ epoch: UInt64,
                                                   _ outBuffer: UnsafeMutablePointer<CChar>?,
                                                   _ capacity: Int32) -> Int32 {
    guard epoch != 0 else {
        return readinessReply(["ok": false, "code": "invalidEpoch"], buffer: outBuffer, capacity: capacity)
    }
    let bindings = RuntimeFacadeLinuxBindings.shared
    guard bindings.boundNativeEpoch == epoch else {
        return readinessReply(["ok": false, "code": "epochNotBound"], buffer: outBuffer, capacity: capacity)
    }
    guard bindings.isCapabilityQualified else {
        return readinessReply(["ok": false, "code": "readinessNotIngressed"],
                              buffer: outBuffer, capacity: capacity)
    }
    let shellRegistered = bindings.registerIntoCurrentGeneration()
    RuntimeFacadeJobBindings.shared.publishToolsIfQualified()
    return readinessReply(["ok": true, "shellRegistered": shellRegistered,
                           "jobsPublishAttempted": true],
                          buffer: outBuffer, capacity: capacity)
}

/// Derived live state + accepted digests (bounded diagnostics).
@_cdecl("floe_linux_readiness_status")
public func floeLinuxReadinessStatus(_ outBuffer: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    guard let outBuffer, capacity > 0 else { return LinuxRuntimeCleanupCode.invalidArguments }
    let bytes = Array(LinuxReadinessIngress.shared.statusJSON().utf8)
    guard bytes.count + 1 <= Int(capacity) else { return LinuxRuntimeCleanupCode.bufferTooSmall }
    for (index, byte) in bytes.enumerated() { outBuffer[index] = CChar(bitPattern: byte) }
    outBuffer[bytes.count] = 0
    return Int32(bytes.count)
}
