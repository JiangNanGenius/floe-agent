// SPDX-License-Identifier: MPL-2.0
//
// D04 App consumer (job-6f953da44de048d0; egress-lifetime repair
// job-bd6d033ab1e34fad) — the narrow, epoch-fenced trusted-host
// run-output reader/egress C ABI (`floe_run_output_*`).
//
// What this lane adds and what it deliberately does NOT:
// * It fronts the EXISTING D04 authority composed by run-output-core10:
//   `RunOutputPersistedReader` over the run's OWN durable toolResult events
//   (exact owned persisted receipts) → `RuntimeFacadeRunOutput.verifiedRead`
//   (captured-root streamed verify + result-boundary generation recheck) →
//   chunked canonical-file egress. NO new receipt, MAC, timestamp identity,
//   permission or execution system exists here; no model-visible command is
//   registered (this is a trusted-host C ABI, the same pattern as
//   `floe_g04_source_host_*`, attachment staging and skills-folder staging:
//   "Model/tool/bridge payloads have NO route here").
// * Input is ONLY (epoch, conversationID, runID, outputID) plus the
//   generation's own trusted root — NEVER model-supplied receipt JSON, path,
//   or digest. The UI cannot ask for bytes: it asks for ONE sealed output of
//   ONE conversation it already owns, and the native side re-derives the
//   receipt from the durable record.
// * A generation-bound operation LEASE (`acquireLease(runID:owner:)`) is
//   taken BEFORE verification/read and held for the whole session lifetime
//   through the streamed copy. Close, the stale-generation sweep and every
//   typed early exit release it EXACTLY ONCE — and, per the lifetime
//   review, close/retire fences NEW admissions immediately while the
//   PHYSICAL FD + lease release is deferred until the LAST actual in-flight
//   read settles (`finalizeLocked` runs under one guard in exactly one of
//   the marking close or the draining settle). Run-output cleanup consults
//   the same lease set, so a live App reader retains the trees and a
//   cleanup claim refuses new opens. This is the REAL lifetime join the
//   review demanded — a claimed running read can no longer continue after
//   the exact owner released the session.
// * Source-descriptor ownership (the pinned-egress review): after
//   `verifiedRead` resolves, the egress pins ONE real file descriptor — an
//   `openat` walk from the captured canonical root through the frozen
//   `RunOutputs/<runID>/<outputID>` namespace with `O_NOFOLLOW` on every
//   namespace component (matching the store's real-directory walk), then
//   the final component with `O_NOFOLLOW`, and fstat-proves on the PINNED
//   descriptor: plain regular file, single link, exact sealed size within
//   the frozen caps, same device as the pinned root. The pinned descriptor
//   is then streamed through SHA-256 and must re-derive the sealed digest,
//   so the verified identity is bound to the EXACT descriptor that serves
//   bytes — never a per-chunk path reopen that could silently land on a
//   different inode. Chunk egress uses bounded `pread` on that owned
//   descriptor (no shared file offset, no per-chunk reopen). The per-chunk
//   guards recheck on the descriptor (regular file + exact size): a size
//   drift is the typed `fileChanged`; a hardlink or unlink that appears
//   AFTER pinning cannot swap the pinned inode's verified content, and
//   deletion under a live session is structurally refused by the un-drained
//   lease. Post-I/O, before ANY bytes are reported, the generation, store
//   and exact captured binding are rechecked and the session is rechecked
//   for close/sweep/supersede — a read that raced them is fenced (never a
//   silent success), and the bytes are discarded.
// * Bytes cross the boundary ONLY as bounded 64 KiB chunks into
//   caller-provided buffers (never base64, never whole-file JSON, never a
//   256 MiB read into RAM; pinning streams the digest with a bounded
//   64 KiB buffer and never buffers a file). Replies are bounded JSON
//   (≤ 32 KiB) with typed negative statuses on a disjoint band. The list
//   reply is serialized down to an honest byte-bounded PREFIX of the
//   ordered owned items — whole items are dropped from the tail with the
//   `truncatedItems` flag, never a cut UTF-8/metadata fragment and never a
//   silently hidden item — so legitimate large Unicode metadata cannot
//   blow the whole page into a bare -106; only an envelope that cannot fit
//   even with zero items answers the typed `bufferTooSmall`.
// * Dynamic absence: when the loaded libFloeAndroidCore does not export
//   these symbols (an older Core generation), the Kotlin lane maps
//   LinkageError to typed "unavailable" and the UI shows the honest
//   unavailable state — never a fabricated product success.
// * Temporary chat: the durable owned store structurally never contains a
//   RAM-only run, so a temporary runID answers `receiptMissing`/`runMissing`
//   here AND the App gates its queries to ordinary conversations. No
//   output-card backdoor, no durable write, no file-tool enablement for a
//   temporary session through any path in this lane.
// * Notes/Canvas: different stores/namespaces, unreachable here (the reader
//   only walks `runs` + `run_events` of the ONE owned cluster and the
//   canonical `RunOutputs/<run>/<output>/` namespace under the trusted root).
//
// Status space (additive; disjoint from gateway -1xx, runtime-owner -2xx,
// attachment -3xx, skills-folder -4xx, source host -5xx and network
// workspace -6xx):
//   0 ok; -105 shape; -106 buffer too small;
//   -701 notInstalled; -702 generationFenced; -703 sessionUnknown;
//   -704 stateConflict; -705 notOwner; -706 receiptMissing;
//   -707 fileMissing; -708 fileChanged; -709 oversized; -710 rejected;
//   -711 scanTruncated; -712 leaseRefused (cleanup claim / unbound store);
//   -713 saturated; -714 hopTimeout; -715 storeUnavailable; -799 internal.
//
// This source is authored for Main's single frozen-batch Android ARM64
// compile: NOT compiled, NOT executed, NOT type-checked here.

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Status / limits vocabulary

public enum RunOutputBridgeStatus {
    public static let ok: Int32 = 0
    public static let invalidArguments: Int32 = -105   // shared shape rule
    public static let bufferTooSmall: Int32 = -106     // shared ASCII-copy rule
    public static let notInstalled: Int32 = -701       // no live root generation
    public static let generationFenced: Int32 = -702   // epoch belongs to another generation
    public static let sessionUnknown: Int32 = -703
    public static let stateConflict: Int32 = -704      // closed session / ladder grammar
    public static let notOwner: Int32 = -705           // run row / sealed task identity mismatch
    public static let receiptMissing: Int32 = -706     // no owned durable receipt (proven)
    public static let fileMissing: Int32 = -707        // durable record OK, snapshot gone
    public static let fileChanged: Int32 = -708        // size/digest re-verification failed
    public static let oversized: Int32 = -709          // snapshot over the frozen caps
    public static let rejected: Int32 = -710           // receipt identity contract violated
    public static let scanTruncated: Int32 = -711      // bounded scan hit its ceiling
    public static let leaseRefused: Int32 = -712       // cleanup claim live / binding unbound
    public static let saturated: Int32 = -713          // live session cap
    public static let hopTimeout: Int32 = -714         // bounded actor hop expired
    public static let storeUnavailable: Int32 = -715   // durable read failed (never "empty")
    public static let `internal`: Int32 = -799
}

public enum RunOutputBridgeLimits {
    /// The frozen JNI chunk bound (identical to the source-host/gateway
    /// 64 KiB contract; JNI enforces it before Swift is ever called). Also
    /// the pinning digest's bounded streaming window.
    public static let maximumChunkBytes = 65_536
    /// Few concurrent owned readers than the workspace source lane: this
    /// lane is card-open/save-copy only, one per interactive surface.
    public static let maximumLiveSessions = 8
    public static let maximumReplyBytes = 32 * 1024
    /// The store caps at 32 user outputs per run, so a complete bounded scan
    /// can never legitimately exceed this listing ceiling; extra items set
    /// the honest `truncatedItems` flag instead of silently dropping. The
    /// SAME flag is honestly set when the reply byte budget drops whole
    /// trailing items below the count ceiling (never a cut UTF-8 fragment,
    /// never a silent hide).
    public static let maximumListedItems = 32
    /// Metadata/DB-only hops and snapshot-verifying (streamed SHA) hops use
    /// the same bounded-wait split as the reviewed source-host lane.
    public static let listHopSeconds = 30
    public static let fileHopSeconds = 300
}

// MARK: - Pinned descriptor (the owned source FD of one egress session)

/// One owned, opened-with-`O_NOFOLLOW` descriptor. `disposeOnce()` closes it
/// exactly once no matter which drain/refuse/cleaner path reaches it last,
/// and `deinit` is the safety net for an outcome never adopted by a session.
/// The physical FD lives at least as long as the session's LAST in-flight
/// read: close/sweep never touch it while `inFlightReads > 0`.
private final class RunOutputPinnedFile: @unchecked Sendable {
    let fd: Int32
    private let stateLock = NSLock()
    private var disposed = false

    init(fd: Int32) { self.fd = fd }

    /// True only for the call that actually closed the descriptor.
    @discardableResult
    func disposeOnce() -> Bool {
        stateLock.lock()
        guard !disposed else {
            stateLock.unlock()
            return false
        }
        disposed = true
        stateLock.unlock()
        close(fd)
        return true
    }

    deinit {
        if !disposed { close(fd) }
    }
}

private enum RunOutputPinResult {
    case pinned(RunOutputPinnedFile)
    case refused(Int32)
}

/// Pins the verified snapshot's REAL descriptor under the captured canonical
/// root: an `openat` chain from the trusted root directory through the
/// frozen namespace components with `O_NOFOLLOW` (every namespace component
/// must be a real directory on the same device — the pinned analogue of the
/// store's lexical lstat walk), then the final display file with
/// `O_NOFOLLOW`, and proves on the PINNED fd: plain regular file, single
/// link, exact sealed size inside the frozen caps. Typed refusals mirror the
/// pre-existing read grammar (missing/oversized/changed); a receipt that is
/// not even canonical answers `rejected` before any path is touched.
/// Never takes a model/UI-supplied path: root + components come from the
/// generation's own captured binding and the re-derived sealed receipt.
private func runOutputPinSnapshotDescriptor(rootPath: String,
                                            receipt: RunOutputFile) -> RunOutputPinResult {
    guard receipt.isCanonicalForCurrentRun, receipt.hasRuntimeConsistentIdentity else {
        return .refused(RunOutputBridgeStatus.rejected)
    }
    var parentFd = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parentFd >= 0 else {
        return .refused(RunOutputBridgeStatus.fileMissing)
    }
    var parentInfo = stat()
    guard fstat(parentFd, &parentInfo) == 0,
          parentInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
        close(parentFd)
        return .refused(RunOutputBridgeStatus.fileMissing)
    }
    for component in [RunOutputFile.namespacePrefix,
                      receipt.runID.uuidString, receipt.outputID] {
        let fd = component.withCString {
            openat(parentFd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            close(parentFd)
            return .refused(RunOutputBridgeStatus.fileMissing)
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_dev == parentInfo.st_dev else {
            close(fd)
            close(parentFd)
            return .refused(RunOutputBridgeStatus.fileMissing)
        }
        close(parentFd)
        parentFd = fd
        parentInfo = info
    }
    let fileFd = receipt.displayName.withCString {
        openat(parentFd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }
    close(parentFd)
    guard fileFd >= 0 else {
        return .refused(RunOutputBridgeStatus.fileMissing)
    }
    var info = stat()
    guard fstat(fileFd, &info) == 0 else {
        close(fileFd)
        return .refused(RunOutputBridgeStatus.fileMissing)
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
        close(fileFd)
        return .refused(RunOutputBridgeStatus.fileMissing)
    }
    guard Int(info.st_size) <= RunOutputCaps.standard.perFileBytes else {
        close(fileFd)
        return .refused(RunOutputBridgeStatus.oversized)
    }
    guard Int(info.st_size) == receipt.byteCount else {
        close(fileFd)
        return .refused(RunOutputBridgeStatus.fileChanged)
    }
    return .pinned(RunOutputPinnedFile(fd: fileFd))
}

/// Streams SHA-256 over the PINNED descriptor with a bounded buffer. A
/// read error or a zero read before the sealed size answers nil (the caller
/// refuses typed); nothing is ever buffered whole into memory.
private func runOutputDigest(pinned file: RunOutputPinnedFile, size: Int) -> String? {
    var hasher = SHA256()
    let chunk = min(max(size, 1), RunOutputBridgeLimits.maximumChunkBytes)
    var buffer = [UInt8](repeating: 0, count: chunk)
    var offset = 0
    while offset < size {
        let want = min(chunk, size - offset)
        let n = buffer.withUnsafeMutableBytes { raw in
            pread(file.fd, raw.baseAddress!, want, off_t(offset))
        }
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        if n == 0 { return nil }
        buffer.withUnsafeBytes { raw in
            hasher.update(bufferPointer:
                UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
        }
        offset += Int(n)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Facade


/// Swift-6-safe one-shot result box for the bounded synchronous actor hops
/// (the caller's thread blocks on the semaphore; only the detached task
/// writes through this box before signalling) — the reviewed source-host /
/// skills-folder shape, re-declared here because the original is private.
private final class RunOutputHopBox<Value>: @unchecked Sendable {
    // pthread_mutex: portable across Darwin AND Android/Linux (os_unfair_lock
    // is Darwin-only; NSLock is unavailable from async contexts on the
    // current SDK). The hop publishes into the box BEFORE the gate signal;
    // readers observe the box only after the gate wait, so the semaphore
    // still sequences publication and the mutex covers cross-thread reads.
    private var mutex = pthread_mutex_t()
    private var stored: Result<Value, any Error>?

    init() {
        pthread_mutex_init(&mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(&mutex)
    }

    var value: Result<Value, any Error>? {
        get {
            pthread_mutex_lock(&mutex)
            defer { pthread_mutex_unlock(&mutex) }
            return stored
        }
        set {
            pthread_mutex_lock(&mutex)
            defer { pthread_mutex_unlock(&mutex) }
            stored = newValue
        }
    }
}

/// The open hop's bounded payload: typed status plus, on success, the
/// sealed receipt, the CAPTURED binding the pinned descriptor was walked
/// under, and the owned pinned descriptor itself.
private struct OpenHopOutcome: Sendable {
    var status: Int32 = RunOutputBridgeStatus.internal
    var receipt: RunOutputFile?
    var binding: RunOutputStoreBinding?
    var pinned: RunOutputPinnedFile?
}

/// Process-lifecycle owner of the App-consumer run-output surface, mirroring
/// the established `RuntimeFacadeRunOutput` / `G04WorkspaceSourceHost`
/// pattern: synchronous thread-safe session table under one lock, EVERY
/// stateful call epoch-fenced against the native root readback (never the
/// caller's claim), opaque positive Int64 tickets, retired-ticket memory, and
/// counters-only stats. Production is the `shared` instance; focused
/// qualification injects via the same-module test seams below.
public final class RunOutputBridgeFacade: @unchecked Sendable {
    public static let shared = RunOutputBridgeFacade()

    /// File-private session table entry: references the file-private pinned
    /// descriptor, so its effective access must stay inside this file.
    private final class EgressSession {
        let ticket: Int64
        let createdEpoch: UInt64
        /// The exact binding the pinned descriptor was walked + digested
        /// under. Every stateful session call rechecks equality against the
        /// authority's CURRENT binding, so a same-epoch re-point is visible.
        let binding: RunOutputStoreBinding
        let lease: RunOutputLeaseToken
        let receipt: RunOutputFile
        let pinned: RunOutputPinnedFile
        /// ACTUAL in-flight read claims (admission-held, settle-released):
        /// the physical FD + lease cannot be freed while this is non-zero.
        var inFlightReads = 0
        /// Set by close/sweep: fences new admissions immediately; the
        /// physical release is deferred to the draining settle.
        var closed = false
        /// The exactly-once guard for lease release + FD dispose + retire.
        var finalized = false

        init(ticket: Int64, epoch: UInt64, lease: RunOutputLeaseToken,
             receipt: RunOutputFile, binding: RunOutputStoreBinding,
             pinned: RunOutputPinnedFile) {
            self.ticket = ticket; self.createdEpoch = epoch; self.lease = lease
            self.receipt = receipt; self.binding = binding; self.pinned = pinned
        }
    }

    private let lock = NSLock()
    private var counter: Int64 = 0
    private var sessions: [Int64: EgressSession] = [:]
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var counters = (lists: 0, opens: 0, chunksRead: 0, closes: 0,
                            fenced: 0, refused: 0, saturated: 0,
                            hopsTimedOut: 0, leaseReleased: 0,
                            fencedReads: 0, delayedReleases: 0, fdReleased: 0)

    /// Trusted fixture seams (same-module only; the reviewed source-host
    /// pattern). Production never writes these; no command/envelope/JSON
    /// field can reach this lane either way. Tests drive the reader +
    /// session grammar without installing a full G02 generation.
    internal var liveEpochOverrideForTesting: UInt64?
    internal var storeProviderOverrideForTesting: ((UInt64) -> (any RunStore)?)?
    internal var runOutputOverrideForTesting: RuntimeFacadeRunOutput?
    /// Lifetime-race seams: a one-shot pause point INSIDE a read's owned
    /// I/O window (between admission and the pread), a shortened open-hop
    /// budget, and a post-verify pause inside the open hop — all used by
    /// the focused drain regressions only; production leaves them nil.
    internal var readIOWindowHookForTesting: (() -> Void)?
    internal var fileHopSecondsOverrideForTesting: TimeInterval?
    internal var openHopPostVerifyPauseForTesting: TimeInterval?

    public init() {}

    // MARK: Epoch truth (never the caller's claim)

    private func liveEpoch() -> UInt64? {
        if let override = liveEpochOverrideForTesting { return override }
        return G02NativeRootEpoch.readback()
    }

    /// Sync counter bumps safe to call from the late-hop cleaner task
    /// (NSLock is unavailable from async contexts on the current SDK).
    private func recordLateHopFDReleased() {
        lock.lock(); counters.fdReleased += 1; lock.unlock()
    }
    private func recordLateHopLeaseReleased() {
        lock.lock(); counters.leaseReleased += 1; lock.unlock()
    }

    /// The durable run store of the CURRENT trusted generation, resolved
    /// through the installed run domain — exactly the composition run-output
    /// cleanup and deletion already consult. A stale/foreign epoch, a
    /// retired root or a missing generation answers nil (typed refusal).
    /// `components` is a `let` of Sendable value type on the actor, so this
    /// stays a synchronous read (no hop before the hop).
    private func durableRunStore(epoch: UInt64) -> (any RunStore)? {
        if let override = storeProviderOverrideForTesting { return override(epoch) }
        guard liveEpoch() == epoch,
              let (domain, _) = RunDomainFacade.current(epoch: epoch) else { return nil }
        let bundle = domain.components.durable
        // Ordinary durable bundle only. A temporary bundle could never be
        // installed here, but the identity check is explicit: the
        // temporary-chat reader backdoor stays structurally closed.
        guard bundle.identity == .ordinary else { return nil }
        return bundle.runs
    }

    private var runOutputAuthority: RuntimeFacadeRunOutput {
        runOutputOverrideForTesting ?? .shared
    }

    // MARK: - List (bounded durable receipt view)

    /// Scans the run's OWN durable toolResult events and answers the sealed
    /// receipts for the requesting conversation, each with an availability
    /// token computed from a cheap namespace check (existence + single-link
    /// regular file + exact size). Digest re-verification is NOT done here
    /// (that is the full streamed verify at open + the destination read-back
    /// at save); availability is honest about what each level proved.
    ///
    /// The reply is serialized down to a byte-bounded PREFIX: the real
    /// JSONSerialization output must fit `replyByteBudget` or whole trailing
    /// items drop (with the honest `truncatedItems` flag, never a cut
    /// metadata fragment or a hidden item); an envelope that cannot fit even
    /// with zero items answers the typed `bufferTooSmall` instead of
    /// silently mis-sizing the page.
    func listJSON(epoch: UInt64, conversationID: UUID, runID: UUID,
                  replyByteBudget: Int) -> (Int32, String?) {
        guard liveEpoch() == epoch else {
            lock.lock(); counters.fenced += 1; lock.unlock()
            return (epoch == 0 ? RunOutputBridgeStatus.notInstalled
                               : RunOutputBridgeStatus.generationFenced, nil)
        }
        guard let store = durableRunStore(epoch: epoch) else {
            return (RunOutputBridgeStatus.notInstalled, nil)
        }
        // A generation with no trusted artifact-root binding cannot answer
        // availability at all. This is the dynamic-absence path (an older
        // loaded Core): typed refusal, never an empty list pretending the
        // outputs do not exist.
        guard let binding = runOutputAuthority.currentBinding(), binding.epoch == epoch else {
            // No trusted artifact-root binding for this generation: the
            // dynamic-absence path. Typed refusal, never an empty list that
            // pretends the outputs do not exist.
            return (RunOutputBridgeStatus.leaseRefused, nil)
        }
        let reader = RunOutputPersistedReader(runStore: store)
        let scan: RunOutputReceiptScan
        let box = RunOutputHopBox<RunOutputReceiptScan>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.value = .success(await reader.scan(conversationID: conversationID, runID: runID))
            gate.signal()
        }
        // One absolute deadline for the whole scan wait (same discipline as
        // the open hop: retakes after a spurious wake never extend the
        // overall budget).
        let listDeadline = DispatchTime.now() + .seconds(RunOutputBridgeLimits.listHopSeconds)
        var woke = gate.wait(timeout: listDeadline)
        while box.value == nil, woke != .timedOut {
            woke = gate.wait(timeout: listDeadline)
        }
        if woke == .timedOut {
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            return (RunOutputBridgeStatus.hopTimeout, nil)
        }
        guard case .success(let resolved)? = box.value else {
            return (RunOutputBridgeStatus.internal, nil)
        }
        scan = resolved
        // Post-hop fence: a retire/rebind during the scan invalidates the
        // whole page (the store/binding it read is no longer current).
        guard liveEpoch() == epoch, durableRunStore(epoch: epoch) != nil,
              runOutputAuthority.currentBinding() == binding else {
            return (RunOutputBridgeStatus.generationFenced, nil)
        }
        lock.lock(); counters.lists += 1; lock.unlock()

        var items: [[String: Any]] = []
        var scanTruncated = false
        var rejectedCount = 0
        var ownedTotal = 0
        switch scan {
        case .owned(let receipts, let truncated, let rejected):
            scanTruncated = truncated
            rejectedCount = rejected
            ownedTotal = receipts.count
            for entry in receipts.prefix(RunOutputBridgeLimits.maximumListedItems) {
                items.append([
                    "outputID": entry.receipt.outputID,
                    "producerCallID": entry.receipt.producerCallID,
                    "producerTool": entry.receipt.producerTool,
                    "slot": entry.receipt.slot,
                    "displayName": entry.receipt.displayName,
                    "mimeType": entry.receipt.mimeType,
                    "byteCount": entry.receipt.byteCount,
                    "availability": Self.availabilityToken(
                        for: entry.receipt, artifactRoot: binding.artifactRoot),
                ])
            }
        case .runMissing:
            // The run row is gone from the trusted durable store (deleted
            // or never ordinary): typed absence, never an empty page that
            // hides a lifecycle bug.
            return (RunOutputBridgeStatus.receiptMissing, nil)
        case .notOwner:
            // Same typed answer as the reviewed child-list foreign-row rule:
            // foreign vs unknown stays indistinguishable to the caller, so
            // no ownership-probing oracle exists on this lane.
            return (RunOutputBridgeStatus.notOwner, nil)
        case .storeUnavailable:
            return (RunOutputBridgeStatus.storeUnavailable, nil)
        }
        // Serialize with the REAL serializer, shrinking whole trailing items
        // until the exact reply fits the byte budget. `truncatedItems` is
        // honest against the FULL owned count (both the 32-item ceiling and
        // any byte-budget drop flip it).
        var count = items.count
        while true {
            let object: [String: Any] = [
                "ok": 1,
                "schema": "floe.run-output.list.v1",
                "conversationID": conversationID.uuidString,
                "runID": runID.uuidString,
                "items": Array(items.prefix(count)),
                "scanTruncated": scanTruncated ? 1 : 0,
                "truncatedItems": count < ownedTotal ? 1 : 0,
                "rejectedCount": rejectedCount,
            ]
            let text = Self.json(object)
            if replyByteBudget >= 0, text.utf8.count <= replyByteBudget {
                return (RunOutputBridgeStatus.ok, text)
            }
            guard count > 0 else {
                return (RunOutputBridgeStatus.bufferTooSmall, nil)
            }
            count -= 1
        }
    }

    // MARK: - Open (lease + exact owned receipt + full streamed verify + pinned descriptor)

    func openEgress(epoch: UInt64, conversationID: UUID, runID: UUID, outputID: String) -> Int64 {
        guard epoch != 0, RunOutputFile.isValidSHA256Hex(outputID) else {
            return epoch == 0 ? Int64(RunOutputBridgeStatus.notInstalled)
                              : Int64(RunOutputBridgeStatus.invalidArguments)
        }
        guard liveEpoch() == epoch else {
            lock.lock(); counters.fenced += 1; lock.unlock()
            return Int64(RunOutputBridgeStatus.generationFenced)
        }
        guard durableRunStore(epoch: epoch) != nil else {
            return Int64(RunOutputBridgeStatus.notInstalled)
        }
        let authority = runOutputAuthority
        // SAME lease seam as publication/cleanup: acquire BEFORE
        // verification/read so a live reader is visible to a cleanup claim
        // and a held claim refuses this open (`acquireLease` returns nil
        // while a cleanup claim covers the run). Held through the whole
        // session (streamed copy / consumer ownership) and released exactly
        // once at close (after any in-flight read drains) or at every typed
        // early exit.
        guard let lease = authority.acquireLease(runID: runID, owner: "app.run-output.egress") else {
            lock.lock(); counters.refused += 1; lock.unlock()
            return Int64(RunOutputBridgeStatus.leaseRefused)
        }
        // Every non-advertising exit releases OUR exact token (double
        // release is an idempotent no-op inside the facade) and disposes
        // any pinned descriptor the hop may have opened, exactly once.
        func refuse(_ status: Int32) -> Int64 {
            authority.releaseLease(lease)
            lock.lock(); counters.leaseReleased += 1; lock.unlock()
            return Int64(status)
        }
        func dispose(_ pinned: RunOutputPinnedFile?) {
            if pinned?.disposeOnce() == true {
                lock.lock(); counters.fdReleased += 1; lock.unlock()
            }
        }
        guard let store = durableRunStore(epoch: epoch) else {
            return refuse(RunOutputBridgeStatus.notInstalled)
        }
        let reader = RunOutputPersistedReader(runStore: store)
        let box = RunOutputHopBox<OpenHopOutcome>()
        let gate = DispatchSemaphore(value: 0)
        let postVerifyPause = openHopPostVerifyPauseForTesting
        let hopTask = Task.detached(priority: .userInitiated) {
            var outcome = OpenHopOutcome()
            // Phase 1: the EXACT OWNED persisted receipt. Only THEN is the
            // trusted `verifiedRead` helper allowed to see this receipt.
            let receiptOutcome = await reader.lookup(conversationID: conversationID,
                                                     runID: runID, outputID: outputID)
            switch receiptOutcome {
            case .rejected:
                outcome.status = RunOutputBridgeStatus.rejected
            case .runMissing, .receiptMissing:
                outcome.status = RunOutputBridgeStatus.receiptMissing
            case .notOwner:
                outcome.status = RunOutputBridgeStatus.notOwner
            case .scanTruncated:
                outcome.status = RunOutputBridgeStatus.scanTruncated
            case .storeUnavailable:
                outcome.status = RunOutputBridgeStatus.storeUnavailable
            case .owned(let persisted):
                // Phase 2: full streamed verify under the CAPTURED root +
                // generation result-boundary recheck (the Core10 trusted-
                // receipt helper; the caller-supplied root is gone — the
                // facade re-reads its own captured binding internally).
                guard let hopBinding = authority.currentBinding(),
                      hopBinding.epoch == epoch else {
                    outcome.status = RunOutputBridgeStatus.generationFenced
                    break
                }
                switch authority.verifiedRead(persisted.receipt,
                                              requestingConversationID: conversationID) {
                case .resolved:
                    // Phase 3 (the pinned-egress review): bind the verified
                    // identity to ONE real descriptor under the SAME captured
                    // binding, then stream the sealed digest from that very
                    // descriptor. A path swap between core10's verify and the
                    // pin can therefore never feed this session unverified
                    // bytes: a mismatch refuses typed and disposes the fd.
                    switch runOutputPinSnapshotDescriptor(rootPath: hopBinding.artifactRoot.path,
                                                          receipt: persisted.receipt) {
                    case .refused(let status):
                        outcome.status = status
                    case .pinned(let file):
                        let digestMatches =
                            runOutputDigest(pinned: file, size: persisted.receipt.byteCount)
                            == persisted.receipt.sha256
                        if digestMatches, authority.currentBinding() == hopBinding {
                            if postVerifyPause != nil {
                                // Test seam: hold the pinned descriptor open
                                // after verification so the focused drain
                                // regression can observe the timeout cleaner.
                                try? await Task.sleep(
                                    nanoseconds: UInt64((postVerifyPause ?? 0) * 1_000_000_000))
                            }
                            outcome.status = RunOutputBridgeStatus.ok
                            outcome.receipt = persisted.receipt
                            outcome.binding = hopBinding
                            outcome.pinned = file
                        } else {
                            file.disposeOnce()
                            outcome.status = digestMatches
                                ? RunOutputBridgeStatus.generationFenced
                                : RunOutputBridgeStatus.fileChanged
                        }
                    }
                case .unavailable:
                    outcome.status = RunOutputBridgeStatus.generationFenced
                case .notOwner:
                    outcome.status = RunOutputBridgeStatus.notOwner
                case .missing:
                    outcome.status = RunOutputBridgeStatus.fileMissing
                case .changed:
                    outcome.status = RunOutputBridgeStatus.fileChanged
                case .oversized:
                    outcome.status = RunOutputBridgeStatus.oversized
                case .rejected:
                    outcome.status = RunOutputBridgeStatus.rejected
                }
            }
            // Publish BEFORE signalling (the waiter reads the box after the
            // wake; a missing publication is indistinguishable from a lost
            // hop and surfaces as the typed internal).
            box.value = .success(outcome)
            gate.signal()
        }
        let hopBudget = fileHopSecondsOverrideForTesting
            ?? TimeInterval(RunOutputBridgeLimits.fileHopSeconds)
        // ONE absolute deadline for the whole hop wait: a semaphore wake can
        // be spurious (the hop publishes its result into the box BEFORE
        // signalling, so an empty box after a non-timeout wake means the
        // real signal is still pending and the wait is retaken), but every
        // retake must answer to the SAME overall budget, never a fresh one.
        let hopDeadline = DispatchTime.now() + .milliseconds(Int(hopBudget * 1000))
        var woke = gate.wait(timeout: hopDeadline)
        while box.value == nil, woke != .timedOut {
            woke = gate.wait(timeout: hopDeadline)
        }
        if woke == .timedOut {
            // The hop may still be running. Its lease was taken by THIS
            // call and no session was ever advertised, so cleanup must
            // still see (and retain against) a real live owner until the
            // orphan hop finishes. A bounded cleaner task waits on the
            // same gate, disposes any pinned descriptor the late hop opened
            // and releases the exact token once the late result lands;
            // nothing here pretends the operation succeeded.
            lock.lock(); counters.hopsTimedOut += 1; lock.unlock()
            let hop = self
            Task.detached(priority: .utility) {
                await hopTask.value
                if let result = box.value, case .success(let outcome) = result {
                    if outcome.pinned?.disposeOnce() == true {
                        hop.recordLateHopFDReleased()
                    }
                }
                authority.releaseLease(lease)
                hop.recordLateHopLeaseReleased()
            }
            return Int64(RunOutputBridgeStatus.hopTimeout)
        }
        guard let result = box.value, case .success(let outcome) = result else {
            return refuse(RunOutputBridgeStatus.internal)
        }
        guard outcome.status == RunOutputBridgeStatus.ok,
              let receipt = outcome.receipt, let hopBinding = outcome.binding,
              let pinned = outcome.pinned else {
            dispose(outcome.pinned)
            return refuse(outcome.status == RunOutputBridgeStatus.ok
                              ? RunOutputBridgeStatus.internal : outcome.status)
        }
        // Post-hop admission: the generation must still own this session
        // before it can advertise a resolved descriptor, and the pinned
        // binding must STILL be the current one.
        guard liveEpoch() == epoch, durableRunStore(epoch: epoch) != nil,
              authority.currentBinding() == hopBinding else {
            dispose(pinned)
            return refuse(RunOutputBridgeStatus.generationFenced)
        }
        lock.lock()
        sweepStaleGenerationLocked(live: epoch)
        guard sessions.count < RunOutputBridgeLimits.maximumLiveSessions else {
            counters.saturated += 1
            if pinned.disposeOnce() { counters.fdReleased += 1 }
            lock.unlock()
            return refuse(RunOutputBridgeStatus.saturated)
        }
        let session = EgressSession(ticket: newTicketLocked(), epoch: epoch, lease: lease,
                                    receipt: receipt, binding: hopBinding, pinned: pinned)
        sessions[session.ticket] = session
        counters.opens += 1
        lock.unlock()
        return session.ticket
    }

    // MARK: - Session reads

    func info(_ ticket: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        lock.lock()
        guard let session = sessions[ticket] else {
            let wasRetired = retired.contains(ticket)
            lock.unlock()
            return wasRetired ? RunOutputBridgeStatus.generationFenced
                              : RunOutputBridgeStatus.sessionUnknown
        }
        guard !session.closed else {
            // Draining closed session: metadata is fenced like any read.
            lock.unlock()
            return RunOutputBridgeStatus.stateConflict
        }
        let createdEpoch = session.createdEpoch
        let binding = session.binding
        let receipt = session.receipt
        lock.unlock()
        guard liveEpoch() == createdEpoch,
              durableRunStore(epoch: createdEpoch) != nil,
              runOutputAuthority.currentBinding() == binding else {
            return sessionFailureStatus(ticket: ticket)
        }
        let object: [String: Any] = [
            "ok": 1,
            "schema": "floe.run-output.egress.v1",
            "conversationID": receipt.taskID?.uuidString ?? "",
            "runID": receipt.runID.uuidString,
            "outputID": receipt.outputID,
            "producerCallID": receipt.producerCallID,
            "producerTool": receipt.producerTool,
            "slot": receipt.slot,
            "displayName": receipt.displayName,
            "mimeType": receipt.mimeType,
            "byteCount": receipt.byteCount,
            "sha256": receipt.sha256,
            // Canonical RELATIVE snapshot path only (display/validation).
            // No absolute root ever crosses the C boundary.
            "relativePath": receipt.relativePath,
        ]
        return Self.copy(Self.json(object), buffer: buffer, capacity: capacity)
    }

    /// Streams up to `capacity` (≤ 64 KiB) bytes at `offset` from the
    /// session's OWNED pinned descriptor (bounded `pread`; no reopen, no
    /// shared file offset). Admission takes a REAL in-flight claim under the
    /// session lock; the claim is held across the I/O and released at the
    /// settle, which ALSO rechecks the generation/store/exact binding and
    /// the session's close/sweep state BEFORE any bytes are reported:
    /// a read whose session was closed or superseded mid-I/O never reports
    /// success, and the physical FD + lease release deferred by close drains
    /// through exactly one `finalizeLocked` here.
    func read(_ ticket: Int64, offset: Int64,
              buffer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
        guard let buffer, capacity > 0,
              capacity <= RunOutputBridgeLimits.maximumChunkBytes,
              offset >= 0 else {
            return RunOutputBridgeStatus.invalidArguments
        }
        lock.lock()
        guard let session = sessions[ticket] else {
            let wasRetired = retired.contains(ticket)
            lock.unlock()
            return wasRetired ? RunOutputBridgeStatus.generationFenced
                              : RunOutputBridgeStatus.sessionUnknown
        }
        guard !session.closed else {
            // close/sweep fences NEW admissions immediately; the physical
            // FD + lease wait for the in-flight reads to drain.
            lock.unlock()
            return RunOutputBridgeStatus.stateConflict
        }
        session.inFlightReads += 1
        let createdEpoch = session.createdEpoch
        let binding = session.binding
        let receipt = session.receipt
        let pinned = session.pinned
        lock.unlock()

        // Test seam: one-shot pause inside the owned I/O window (the claim
        // is already held, nothing has been read or reported yet).
        readIOWindowHookForTesting?()

        // The snapshot bytes were verified TWICE before this point: core10's
        // `verifiedRead` streamed the resolved path under the captured root
        // (namespace + size + SHA + result-boundary generation recheck),
        // and the open hop streamed THIS pinned descriptor's bytes through
        // SHA-256 and required the sealed digest. Egress therefore reads the
        // owned descriptor directly: a path swap after open cannot move the
        // stream to a different inode, and the held lease means cleanup
        // cannot delete the tree's live ownership under this session.
        var result: Int32
        var reportedBytes = false
        let size = receipt.byteCount
        if liveEpoch() != createdEpoch
            || durableRunStore(epoch: createdEpoch) == nil
            || runOutputAuthority.currentBinding() != binding {
            result = RunOutputBridgeStatus.generationFenced
        } else if size < 0 || size > RunOutputCaps.standard.perFileBytes {
            result = RunOutputBridgeStatus.oversized
        } else {
            var info = stat()
            if fstat(pinned.fd, &info) != 0
                || info.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) {
                result = RunOutputBridgeStatus.fileMissing
            } else if Int(info.st_size) != size {
                // Bytes moved under the verified session: refuse, keep the
                // lease until close (the reader's data stays recoverable on
                // disk — nothing here deletes or repairs).
                result = RunOutputBridgeStatus.fileChanged
            } else if offset >= Int64(size) {
                result = 0 // clean EOF (fenced at the settle like any success)
                reportedBytes = true
            } else {
                let start = Int(offset)
                let want = min(Int(capacity), size - start)
                var done = 0
                while done < want {
                    let n = pread(pinned.fd, buffer.advanced(by: done),
                                  want - done, off_t(start + done))
                    if n < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if n == 0 {
                        // Truncated under the pinned descriptor mid-request.
                        done = -1
                        break
                    }
                    done += Int(n)
                }
                if done < 0 {
                    result = RunOutputBridgeStatus.fileChanged
                } else if done == want {
                    result = Int32(done)
                    reportedBytes = true
                } else {
                    result = RunOutputBridgeStatus.fileMissing
                }
            }
        }

        // Settle: drop the actual in-flight claim, recheck generation/owner
        // AFTER the I/O and BEFORE returning bytes, then drain-finalize in
        // exactly one path if close/sweep had already fenced this session.
        let postLive = liveEpoch() == createdEpoch
            && durableRunStore(epoch: createdEpoch) != nil
            && runOutputAuthority.currentBinding() == binding
        lock.lock()
        session.inFlightReads -= 1
        if reportedBytes, !postLive {
            // Superseded/retired mid-I/O: the read physically succeeded but
            // its generation no longer owns the session — bytes discarded.
            result = RunOutputBridgeStatus.generationFenced
            counters.fencedReads += 1
        } else if reportedBytes, session.closed || session.finalized {
            // close/sweep raced the I/O: never a silent success after the
            // exact owner released — bytes discarded.
            result = RunOutputBridgeStatus.stateConflict
            counters.fencedReads += 1
        } else if reportedBytes {
            counters.chunksRead += 1
        }
        if session.closed, session.inFlightReads == 0, !session.finalized {
            finalizeLocked(session)
        }
        lock.unlock()
        return result
    }

    /// Close fences the session immediately (new reads admit `stateConflict`)
    /// and releases the exact lease token + pinned descriptor EXACTLY ONCE —
    /// immediately when no read is in flight, otherwise deferred to the last
    /// settle in `read`. Idempotent for an already-closed/retired/unknown
    /// session (mirrors the reviewed egressClose).
    func close(_ ticket: Int64) -> Int32 {
        lock.lock()
        guard let session = sessions[ticket] else {
            lock.unlock()
            return RunOutputBridgeStatus.ok
        }
        closeLocked(session)
        lock.unlock()
        return RunOutputBridgeStatus.ok
    }

    private func closeLocked(_ session: EgressSession) {
        guard !session.closed else { return }
        session.closed = true
        counters.closes += 1
        if session.inFlightReads == 0 {
            finalizeLocked(session)
        } else {
            // Real reads are in flight: the physical FD + lease stay owned
            // until the last settle drains (no host-thread blocking join).
            counters.delayedReleases += 1
        }
    }

    /// The single exactly-once physical release: lease token, pinned
    /// descriptor, retire record. Only ever called under `lock` and only
    /// when no in-flight claim remains.
    private func finalizeLocked(_ session: EgressSession) {
        guard !session.finalized else { return }
        session.finalized = true
        // Release the EXACT token (double release is an idempotent no-op
        // inside RuntimeFacadeRunOutput).
        runOutputAuthority.releaseLease(session.lease)
        counters.leaseReleased += 1
        if session.pinned.disposeOnce() { counters.fdReleased += 1 }
        retireLocked(session.ticket)
    }

    private func sessionFailureStatus(ticket: Int64) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if sessions[ticket] == nil {
            return retired.contains(ticket) ? RunOutputBridgeStatus.generationFenced
                                            : RunOutputBridgeStatus.sessionUnknown
        }
        return sessions[ticket]?.closed == true ? RunOutputBridgeStatus.stateConflict
                                                : RunOutputBridgeStatus.generationFenced
    }

    private func sweepStaleGenerationLocked(live: UInt64) {
        // Snapshot the values first: closeLocked finalizes (mutates
        // `sessions`) when nothing is in flight.
        let stale = sessions.values.filter { $0.createdEpoch != live }
        for session in stale {
            // A retired generation's reader: fence it immediately and release
            // its exact lease (deferred through any in-flight drain) so the
            // retired-but-live lease set drains honestly, retire the ticket
            // (fenced answers), and touch NO bytes — the snapshot tree
            // belongs to run-output cleanup, never to this sweep.
            closeLocked(session)
            counters.fenced += 1
        }
    }

    private func newTicketLocked() -> Int64 {
        counter &+= 1
        return counter
    }

    private func retireLocked(_ ticket: Int64) {
        sessions.removeValue(forKey: ticket)
        retired.insert(ticket)
        retiredOrder.append(ticket)
        while retiredOrder.count > 512 { retired.remove(retiredOrder.removeFirst()) }
    }

    func statsJSON() -> String {
        lock.lock()
        let value = counters
        lock.unlock()
        return Self.json([
            "ok": 1, "lists": value.lists, "opens": value.opens,
            "chunksRead": value.chunksRead, "closes": value.closes,
            "fenced": value.fenced, "refused": value.refused,
            "saturated": value.saturated, "hopsTimedOut": value.hopsTimedOut,
            "leaseReleased": value.leaseReleased,
            "fencedReads": value.fencedReads,
            "delayedReleases": value.delayedReleases,
            "fdReleased": value.fdReleased,
        ])
    }

    // MARK: - Availability (cheap namespace view for the card list)

    /// Availability tokens: "available" (canonical namespace walk, plain
    /// single-link regular file, exact sealed size), "missing", "changed"
    /// (size moved), "oversized" (file beyond the frozen cap), "rejected"
    /// (namespace grammar broken — symlink/special component). This is NOT
    /// the digest gate: open() runs the full streamed verification and the
    /// save lane re-measures bytes + SHA + EOF end to end. The card UI maps
    /// tokens to visible, actionable states.
    static func availabilityToken(for receipt: RunOutputFile, artifactRoot: URL) -> String {
        guard receipt.isCanonicalForCurrentRun, receipt.hasRuntimeConsistentIdentity else {
            return "rejected"
        }
        let base = artifactRoot.standardizedFileURL.path
        var url = artifactRoot
        for component in [RunOutputFile.namespacePrefix,
                          receipt.runID.uuidString, receipt.outputID, receipt.displayName] {
            url = url.appendingPathComponent(component)
        }
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(base + "/") else { return "rejected" }
        var walk = base
        for component in target.dropFirst(base.count + 1).split(separator: "/").dropLast() {
            walk = (walk as NSString).appendingPathComponent(String(component))
            var ancestorInfo = stat()
            guard lstat(walk, &ancestorInfo) == 0 else { return "missing" }
            guard ancestorInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                return "rejected"
            }
        }
        var info = stat()
        guard lstat(target, &info) == 0 else { return "missing" }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
            return "rejected"
        }
        let size = Int(info.st_size)
        guard size <= RunOutputCaps.standard.perFileBytes else { return "oversized" }
        guard size == receipt.byteCount else { return "changed" }
        return "available"
    }

    // MARK: - C ABI helpers (the reviewed source-host idioms)

    static func canonicalUUID(_ raw: String?) -> UUID? {
        guard let raw, !raw.isEmpty, let value = UUID(uuidString: raw) else { return nil }
        return value.uuidString.caseInsensitiveCompare(raw) == .orderedSame ? value : nil
    }

    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":0,\"errorCode\":\"internal\"}"
        }
        return text
    }

    static func copy(_ text: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        let bytes = Array(text.utf8)
        guard bytes.count + 1 <= Int(capacity) else { return RunOutputBridgeStatus.bufferTooSmall }
        guard let buffer else { return RunOutputBridgeStatus.invalidArguments }
        for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
        return Int32(bytes.count)
    }
}

// MARK: - Trusted-host C ABI (`floe_run_output_*`; Kotlin JNI only)

private func runOutputReadCString(_ pointer: UnsafePointer<CChar>?, limit: Int) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit)
    guard length > 0, length < limit else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length), as: UTF8.self)
}

/// Bounded durable receipt page for one exact (conversation, run) pair.
/// Positive/zero return = copied JSON length into the caller buffer;
/// negative = typed status. Never model-reachable; JNI host only.
@_cdecl("floe_run_output_list")
public func floeRunOutputList(_ epoch: UInt64,
                              _ taskHex: UnsafePointer<CChar>?,
                              _ runHex: UnsafePointer<CChar>?,
                              _ buffer: UnsafeMutablePointer<CChar>?,
                              _ capacity: Int32) -> Int32 {
    guard capacity > 0, capacity <= RunOutputBridgeLimits.maximumReplyBytes,
          let conversation = RunOutputBridgeFacade.canonicalUUID(
            runOutputReadCString(taskHex, limit: 64)),
          let run = RunOutputBridgeFacade.canonicalUUID(
            runOutputReadCString(runHex, limit: 64)) else {
        return RunOutputBridgeStatus.invalidArguments
    }
    // The reply is serialized down to a byte-bounded honest prefix: the
    // whole page only ever crosses when the REAL JSON fits the caller's
    // capacity (minus the NUL), never as an over-cap -106 surprise.
    let (status, body) = RunOutputBridgeFacade.shared.listJSON(
        epoch: epoch, conversationID: conversation, runID: run,
        replyByteBudget: Int(capacity) - 1)
    guard status == RunOutputBridgeStatus.ok, let body else { return status }
    return RunOutputBridgeFacade.copy(body, buffer: buffer, capacity: capacity)
}

/// Opens one owned egress session: exact persisted receipt lookup, the
/// generation lease, the full streamed verify, and the pinned-descriptor
/// identity re-verify, BEFORE any byte is advertised. Positive = opaque
/// ticket; negative = typed status.
@_cdecl("floe_run_output_open")
public func floeRunOutputOpen(_ epoch: UInt64,
                              _ taskHex: UnsafePointer<CChar>?,
                              _ runHex: UnsafePointer<CChar>?,
                              _ outputHex: UnsafePointer<CChar>?) -> Int64 {
    guard let conversation = RunOutputBridgeFacade.canonicalUUID(
        runOutputReadCString(taskHex, limit: 64)),
        let run = RunOutputBridgeFacade.canonicalUUID(
            runOutputReadCString(runHex, limit: 64)),
        let outputID = runOutputReadCString(outputHex, limit: 80),
        RunOutputFile.isValidSHA256Hex(outputID) else {
        return Int64(RunOutputBridgeStatus.invalidArguments)
    }
    return RunOutputBridgeFacade.shared.openEgress(epoch: epoch, conversationID: conversation,
                                                   runID: run, outputID: outputID)
}

/// Verified session facts (native-side values only): identity, display
/// fields, sealed size and digest, canonical relative path.
@_cdecl("floe_run_output_info")
public func floeRunOutputInfo(_ ticket: Int64,
                              _ buffer: UnsafeMutablePointer<CChar>?,
                              _ capacity: Int32) -> Int32 {
    guard ticket > 0, capacity > 0,
          capacity <= RunOutputBridgeLimits.maximumReplyBytes else {
        return RunOutputBridgeStatus.invalidArguments
    }
    return RunOutputBridgeFacade.shared.info(ticket, buffer: buffer, capacity: capacity)
}

/// Copies up to `capacity` (<= 64 KiB) snapshot bytes at `offset` into the
/// caller buffer from the session's OWNED pinned descriptor. Returns copied
/// length, 0 for a clean EOF, or a typed negative status. A read whose
/// session was closed or superseded mid-I/O is fenced at the settle and
/// NEVER reports success. Bytes never cross as base64/JSON and the whole
/// file is never read into RAM.
@_cdecl("floe_run_output_read")
public func floeRunOutputRead(_ ticket: Int64,
                              _ offset: Int64,
                              _ buffer: UnsafeMutablePointer<UInt8>?,
                              _ capacity: Int32) -> Int32 {
    guard ticket > 0, offset >= 0 else { return RunOutputBridgeStatus.invalidArguments }
    return RunOutputBridgeFacade.shared.read(ticket, offset: offset, buffer: buffer, capacity: capacity)
}

/// Fences the session immediately and releases its exact lease token +
/// pinned descriptor once the last in-flight read settles. Idempotent.
@_cdecl("floe_run_output_close")
public func floeRunOutputClose(_ ticket: Int64) -> Int32 {
    guard ticket > 0 else { return RunOutputBridgeStatus.invalidArguments }
    return RunOutputBridgeFacade.shared.close(ticket)
}

/// Typed counters JSON only (no paths, bytes or identities).
@_cdecl("floe_run_output_stats")
public func floeRunOutputStats(_ buffer: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    guard capacity > 0, capacity <= RunOutputBridgeLimits.maximumReplyBytes else {
        return RunOutputBridgeStatus.invalidArguments
    }
    return RunOutputBridgeFacade.copy(RunOutputBridgeFacade.shared.statsJSON(),
                                      buffer: buffer, capacity: capacity)
}
