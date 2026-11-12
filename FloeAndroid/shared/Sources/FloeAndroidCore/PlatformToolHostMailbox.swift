// SPDX-License-Identifier: MPL-2.0
//
// G08 generic trusted App-platform tool mailbox (Full-only seam).
//
// The SAME reviewed ticket shape as `NetworkArtifactHostMailbox` /
// `G07NetworkHostMailbox` / `OfficeAIHostMailbox`: Swift owns ONE bounded
// ticket table per bound native root epoch; the trusted Full App host claims
// tickets through the exported C ABI, performs the REAL typed phone/system
// operation in Kotlin, and settles exactly once.
//
// No phone/ADB/root name, schema, implementation or asset lives in this
// shared Play core. The Full App host supplies ONE bounded catalog at bind;
// every entry is validated by `PlatformToolCatalogParser` and registered in
// the ORIGINAL `ToolRunnerRegistry` with the ORIGINAL metadata types.
//
// Ownership is re-derived from the runtime-issued `ToolContext`, never from
// model JSON:
//   * task (conversation), run, tool-call id, idempotency key, scope and
//     approvalGrantID travel to the host ONLY inside the trusted ticket
//     descriptor;
//   * side-effecting descriptors require a non-nil approvalGrantID;
//   * temporary/public-web-only runs, delegated children, stale epochs and
//     tickets outside the run's effective ceiling are refused before any
//     ticket exists;
//   * cancellation is a REQUEST (`shouldStop`); the host must stop real work
//     and still settle. A success that arrives after cancellation is refused
//     (`-109`) and the waiter observes `cancelled`, never success;
//   * bind/close remove every name this mailbox installed, so a rebind can
//     never accumulate stale tools across epochs.
//
// There is no V3 handler, no model route, no fallback shell/interpreter and
// no raw host detail in model-facing errors.
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeAgentRuntime

// MARK: - Ownership

/// The ONE actual App-owned directory this mailbox will read screenshot
/// evidence from. It is minted only by trusted composition from the live
/// generation's validated `RuntimeStorageRoot` (never from model JSON, the
/// host environment, `$HOME` or a temporary fallback) and carries the exact
/// native root epoch that bound it.
public struct PlatformToolArtifactRootBinding: Sendable, Equatable {
    /// Standardized absolute path of `<owned root>/FloeAgent`.
    public let path: String
    public let epoch: UInt64

    public init(path: String, epoch: UInt64) {
        self.path = path
        self.epoch = epoch
    }
}

/// The ONE App-owned workspace-APK inbox this mailbox commits verified
/// transfer bytes into. Minted only by trusted composition from the live
/// generation's validated `RuntimeStorageRoot` (never from model JSON, the
/// host environment or a temporary fallback) and generation-fenced exactly
/// like the artifact root: `<owned root>/FloeAgent/WorkspaceApkInbox`.
/// Kotlin `ApkStagingStore.adoptWorkspaceFile` moves/copies and re-verifies
/// the committed bytes; this binding never exposes a model route.
public struct PlatformToolWorkspaceApkInboxBinding: Sendable, Equatable {
    public let path: String
    public let epoch: UInt64

    public init(path: String, epoch: UInt64) {
        self.path = path
        self.epoch = epoch
    }
}

/// Live currency of ONE claimed ticket, re-proved by the staging loop before
/// every page. `fenced` covers rebind/close/retire and any ticket whose
/// generation left the current epoch; `cancelled` is the owning call's own
/// cancellation request.
public enum PlatformToolClaimCurrency: Sendable, Equatable {
    case current
    case cancelled
    case fenced
}

/// Snapshot of the trusted ownership/fencing context for ONE CLAIMED ticket.
/// Minted only by `PlatformToolHostMailbox.claimedContext(claim:)` while the
/// ticket is claimed (state 1), belongs to the current bound epoch and the
/// mailbox is open. A snapshot is never authority by itself: the workspace
/// APK stager re-proves `currency()` before every page and honours
/// `deadline` (the ticket's own mailbox budget).
public struct PlatformToolClaimContext: Sendable {
    public let claim: Int64
    public let toolName: String
    public let owner: PlatformToolOwner
    public let deadline: DispatchTime
    fileprivate let mailbox: PlatformToolHostMailbox

    public func currency() -> PlatformToolClaimCurrency {
        mailbox.claimCurrency(claim: claim)
    }

    public var expired: Bool { DispatchTime.now() >= deadline }
}

/// Exact runtime-issued ownership recorded with one ticket. These values are
/// opaque identity to the host; it never decides authority from them.
public struct PlatformToolOwner: Sendable, Equatable {
    public let taskID: UUID
    public let runID: UUID
    public let epoch: UInt64
    public let toolCallID: String
    public let toolIdempotencyKey: String
    public let clientSessionID: String
    public let approvalGrantID: UUID?
    public let scope: ToolScope

    public init(taskID: UUID, runID: UUID, epoch: UInt64,
                toolCallID: String, toolIdempotencyKey: String,
                clientSessionID: String, approvalGrantID: UUID?,
                scope: ToolScope) {
        self.taskID = taskID
        self.runID = runID
        self.epoch = epoch
        self.toolCallID = toolCallID
        self.toolIdempotencyKey = toolIdempotencyKey
        self.clientSessionID = clientSessionID
        self.approvalGrantID = approvalGrantID
        self.scope = scope
    }
}

/// Canonical device wire codes plus the exact bounded legacy spellings that
/// older persisted/queued receipts can still carry. Only the platform
/// mailbox uses this normalization: the Kotlin host now emits `device_*`,
/// while `phone_*` remains readable so restored work is not silently lost.
/// It never renames an internal Phone type, module, stored preference or the
/// closed legacy `phone.observe/act/screenshot` tool aliases.
enum PlatformDeviceWireCode {
    private static let exactLegacy: [String: String] = [
        "phone_presence_required": "device_presence_required",
        "phone_unlock_required": "device_unlock_required",
        "phone_unlock_needs_user": "device_unlock_needs_user",
        "phone_unlock_state_unavailable": "device_unlock_state_unavailable",
        "phone_paused_by_user": "device_paused_by_user",
        "phone_stopped_by_user": "device_stopped_by_user",
        "phone_arm_required": "device_arm_required",
        "phone_target_required": "device_target_required",
        "phone_service_not_ready": "device_service_not_ready",
        "phone_timeout": "device_timeout",
        "phone_interrupted": "device_interrupted",
        "phone_finishing": "device_finishing",
        "phone_busy": "device_busy",
        "phone_unavailable": "device_unavailable",
        "phone_pause_state_unavailable": "device_pause_state_unavailable",
        "phone_observation_required": "device_observation_required",
    ]

    /// Canonical form of one host failure code. The prefix rule covers the
    /// closed host-denial family (`phone_launch_target_unavailable`,
    /// `phone_service_not_connected`, ...); it is used only for replies from
    /// the device tool host, never for arbitrary model or file content.
    static func canonical(_ code: String) -> String {
        if let exact = exactLegacy[code] { return exact }
        if code.hasPrefix("phone_") {
            return "device_" + String(code.dropFirst("phone_".count))
        }
        return code
    }

    static func isPausePrompt(_ canonicalCode: String) -> Bool {
        ["device_presence_required", "device_unlock_required",
         "device_unlock_needs_user", "device_paused_by_user"].contains(canonicalCode)
    }
}

public enum PlatformToolTransportError: Error, Sendable, Equatable {
    case hostUnbound
    case hostClosed
    case hostFenced
    case hostBudget
    case saturated
    case oversized
    case cancelled
    case resultInvalid
    case remoteFailed(code: String, detail: String?)
}

// MARK: - Mailbox

public final class PlatformToolHostMailbox: @unchecked Sendable {
    public static let shared = PlatformToolHostMailbox()

    private final class Ticket {
        let claim: Int64
        let toolName: String
        /// Runtime-issued ownership captured at submit; the workspace-APK
        /// staging seam re-derives task/run authority ONLY from this value.
        let owner: PlatformToolOwner
        let descriptor: Data
        let payload: Data
        let createdEpoch: UInt64
        let deadline: DispatchTime
        let cancellation: CancellationToken
        var state = 0 // 0 queued, 1 claimed, 2 settled
        var continuation: CheckedContinuation<PlatformToolResult,
                                              PlatformToolTransportError>?

        init(claim: Int64, toolName: String, descriptor: Data, payload: Data,
             owner: PlatformToolOwner, epoch: UInt64, deadline: DispatchTime,
             cancellation: CancellationToken) {
            self.owner = owner
            self.claim = claim
            self.toolName = toolName
            self.descriptor = descriptor
            self.payload = payload
            self.createdEpoch = epoch
            self.deadline = deadline
            self.cancellation = cancellation
        }
    }

    private struct Counters {
        var submitted = 0
        var claimed = 0
        var completed = 0
        var failed = 0
        var cancelled = 0
        var invalid = 0
        var lateSettle = 0
        var fenced = 0
        var saturated = 0
        var unbound = 0
        var expired = 0
        var bindRejections = 0
        var binds = 0
        var availabilitySets = 0
        var admissionSets = 0
    }

    private let registry: ToolRunnerRegistry
    private let currentEpoch: @Sendable () -> UInt64?
    /// Bound ONLY by `bindArtifactRoot(ownedRootPath:epoch:)` from trusted
    /// composition. nil means screenshot artifacts are refused (the mailbox
    /// itself may still register/execute tools that produce no image).
    private var artifactRoot: URL?
    private var artifactRootEpoch: UInt64 = 0
    /// Monotonic retirement fence: a retired epoch can never be rebound,
    /// even when the old root path is supplied again.
    private var artifactRootHighWater: UInt64 = 0
    /// The ONE App-owned workspace-APK inbox bound by trusted composition
    /// (same root discipline and generation fencing as `artifactRoot`). nil
    /// refuses every claimed workspace-APK transfer (no temporary fallback).
    private var workspaceApkInboxRoot: URL?
    private var workspaceApkInboxEpoch: UInt64 = 0
    /// Monotonic retirement fence mirroring `artifactRootHighWater`.
    private var workspaceApkInboxHighWater: UInt64 = 0
    /// Trusted durable-ceiling snapshot published by the Full host for the
    /// bound generation through `setAutoAdmission`. nil means ordinary
    /// automatic task calls keep the actual interactive/model gate.
    private var autoAdmission: PlatformToolAutoAdmission?
    private var autoAdmissionEpoch: UInt64 = 0

    private let condition = NSCondition()
    private var entries: [String: PlatformToolCatalogEntry] = [:]
    private var installedNames: Set<String> = []
    /// Names the Full host explicitly published as ACTUALLY usable for this
    /// generation. Empty + `availabilityPublished == false` means the catalog
    /// is registered but every runner stays unavailable (fail closed).
    private var availableNames: Set<String> = []
    private var availabilityPublished = false
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var counter: Int64 = 0
    private var epoch: UInt64 = 0
    private var closed = true
    private var lastBindFailure = ""
    private var counters = Counters()

    public init(registry: ToolRunnerRegistry = .shared,
                currentEpoch: @escaping @Sendable () -> UInt64? = {
                    G02NativeRootEpoch.readback()
                }) {
        self.registry = registry
        self.currentEpoch = currentEpoch
    }

    // MARK: - Actual owned artifact root (trusted composition only)

    /// Binds `<ownedRoot>/FloeAgent` for the EXACT live native root epoch.
    /// `ownedRootPath` must be the validated standardized owned root from
    /// `RuntimeStorageRoot` (the SAME root the generation's database and
    /// runtime use). There is no Foundation/persistent-container or temporary
    /// fallback: an unbound mailbox accepts no screenshot artifact.
    ///
    /// A same-epoch rebind of the identical root is idempotent. A different
    /// root at the same epoch, an older epoch, or a retired epoch is refused.
    @discardableResult
    public func bindArtifactRoot(ownedRootPath: String, epoch: UInt64) -> Bool {
        guard epoch != 0,
              let storage = RuntimeStorageRoot(validatingAbsoluteDirectory: ownedRootPath),
              currentEpoch() == epoch
        else { return false }
        let root = URL(fileURLWithPath: storage.path, isDirectory: true)
            .appendingPathComponent("FloeAgent", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
        } catch {
            return false
        }
        // The derived directory must be a REAL directory, never a symlink a
        // compromised host could point outside the accepted owned root.
        let values = try? root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true,
              values?.isSymbolicLink != true else { return false }
        condition.lock()
        defer { condition.unlock() }
        if artifactRootEpoch == epoch {
            return artifactRoot?.path == root.path
        }
        guard epoch > artifactRootEpoch,
              epoch > artifactRootHighWater else { return false }
        artifactRoot = root
        artifactRootEpoch = epoch
        return true
    }

    /// Clears ONLY the binding this exact epoch minted and advances the
    /// monotonic fence so a late bind for the retired generation can never
    /// resurrect the old root. Called from generation retirement.
    public func retireArtifactRoot(epoch: UInt64) {
        guard epoch != 0 else { return }
        condition.lock(); defer { condition.unlock() }
        if artifactRootEpoch == epoch {
            artifactRoot = nil
            artifactRootEpoch = 0
            artifactRootHighWater = max(artifactRootHighWater, epoch)
        }
        // Capability publication is generation-scoped too: retiring THIS
        // mailbox generation can never leave an old availability mask
        // advertised. A stale retirement for another epoch is a no-op.
        if self.epoch == epoch {
            availableNames.removeAll()
            availabilityPublished = false
            autoAdmission = nil
            autoAdmissionEpoch = 0
        }
    }

    /// Trusted test reset owned by the composition's `resetForTesting()`
    /// producer: clears the binding AND the monotonic fence so isolated
    /// host fixtures can reuse a low epoch. Never called from production.
    func resetArtifactRootBindingForTesting() {
        condition.lock(); defer { condition.unlock() }
        artifactRoot = nil
        artifactRootEpoch = 0
        artifactRootHighWater = 0
    }

    // MARK: Actual owned workspace-APK inbox (trusted composition only)

    /// Binds `<ownedRoot>/FloeAgent/WorkspaceApkInbox` for the EXACT live
    /// native root epoch. `ownedRootPath` must be the validated standardized
    /// owned root from `RuntimeStorageRoot` (the SAME root the generation's
    /// database and runtime use). Every managed component — the `FloeAgent`
    /// parent and the inbox leaf — must be a REAL directory, never a symlink
    /// a compromised host could point outside the accepted owned root.
    ///
    /// A same-epoch rebind of the identical root is idempotent. A different
    /// root at the same epoch, an older epoch, or a retired epoch is refused.
    @discardableResult
    public func bindWorkspaceApkInbox(ownedRootPath: String, epoch: UInt64) -> Bool {
        guard epoch != 0,
              let storage = RuntimeStorageRoot(validatingAbsoluteDirectory: ownedRootPath),
              currentEpoch() == epoch
        else { return false }
        guard let root = PlatformToolWorkspaceApkStager.prepareInbox(
            ownedRootPath: storage.path), currentEpoch() == epoch else { return false }
        condition.lock()
        defer { condition.unlock() }
        if workspaceApkInboxEpoch == epoch {
            return workspaceApkInboxRoot?.path == root.path
        }
        guard epoch > workspaceApkInboxEpoch,
              epoch > workspaceApkInboxHighWater else { return false }
        workspaceApkInboxRoot = root
        workspaceApkInboxEpoch = epoch
        return true
    }

    /// Clears ONLY the binding this exact epoch minted and advances the
    /// monotonic fence. Called from the SAME generation retirement path that
    /// calls `retireArtifactRoot`.
    public func retireWorkspaceApkInbox(epoch: UInt64) {
        guard epoch != 0 else { return }
        condition.lock(); defer { condition.unlock() }
        workspaceApkInboxHighWater = max(workspaceApkInboxHighWater, epoch)
        guard workspaceApkInboxEpoch == epoch else { return }
        workspaceApkInboxRoot = nil
        workspaceApkInboxEpoch = 0
    }

    /// Trusted test reset owned by the composition's `resetForTesting()`
    /// producer; paired with `resetArtifactRootBindingForTesting`.
    func resetWorkspaceApkInboxBindingForTesting() {
        condition.lock(); defer { condition.unlock() }
        workspaceApkInboxRoot = nil
        workspaceApkInboxEpoch = 0
        workspaceApkInboxHighWater = 0
    }

    /// Exact inbox readback for the trusted Full App host, never a model
    /// route. Returns nil unless the bound inbox still belongs to the
    /// CURRENT live root epoch.
    public func workspaceApkInboxBinding() -> PlatformToolWorkspaceApkInboxBinding? {
        let live = currentEpoch()
        condition.lock(); defer { condition.unlock() }
        guard let root = workspaceApkInboxRoot, workspaceApkInboxEpoch != 0,
              workspaceApkInboxEpoch == live else { return nil }
        return PlatformToolWorkspaceApkInboxBinding(
            path: root.path, epoch: workspaceApkInboxEpoch)
    }

    /// Exact root readback for the trusted Full App host, never a model
    /// route. Returns nil unless the bound root still belongs to the CURRENT
    /// live root epoch, so an epoch change fences the getter immediately.
    public func artifactRootBinding() -> PlatformToolArtifactRootBinding? {
        let live = currentEpoch()
        condition.lock(); defer { condition.unlock() }
        guard let root = artifactRoot, artifactRootEpoch != 0,
              artifactRootEpoch == live else { return nil }
        return PlatformToolArtifactRootBinding(path: root.path,
                                               epoch: artifactRootEpoch)
    }

    public func artifactRootPathForTrustedHost() -> String? {
        artifactRootBinding()?.path
    }

    public var boundArtifactRootEpoch: UInt64 {
        condition.lock(); defer { condition.unlock() }
        return artifactRootEpoch
    }

    public var boundEpoch: UInt64 {
        condition.lock(); defer { condition.unlock() }
        return epoch
    }

    public var isBound: Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0
    }

    public func isBound(to expectedEpoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0 && epoch == expectedEpoch
    }

    /// True only while this mailbox is bound to the ACTUAL live epoch and the
    /// named entry is still installed. Discovery consults this through the
    /// registry runner's `isAvailable`, so a closed/rebound catalog is never
    /// advertised.
    public var isAvailable: Bool {
        guard let live = currentEpoch(), live != 0 else { return false }
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0 && epoch == live && availabilityPublished
    }

    public func isToolAvailable(named name: String) -> Bool {
        let snapshot = installedEntry(named: name)
        guard snapshot.installed, snapshot.available,
              let live = currentEpoch(), live != 0 else { return false }
        return snapshot.epoch == live
    }

    /// Exact catalog names the Full host published as actually usable for
    /// the CURRENT bound generation. Discovery/telemetry only; never model
    /// arguments.
    public func availableToolNames() -> [String] {
        condition.lock(); defer { condition.unlock() }
        guard !closed, epoch != 0, availabilityPublished else { return [] }
        return availableNames.sorted()
    }

    public func installedToolNames() -> [String] {
        condition.lock(); defer { condition.unlock() }
        return installedNames.sorted()
    }

    private func installedEntry(named name: String)
        -> (entry: PlatformToolCatalogEntry?, epoch: UInt64, installed: Bool,
            available: Bool) {
        condition.lock(); defer { condition.unlock() }
        let entry = entries[name]
        let installed = !closed && epoch != 0 && entry != nil
            && installedNames.contains(name)
        let available = installed && availabilityPublished
            && availableNames.contains(name)
        return (entry, epoch, installed, available)
    }

    // MARK: Bind / close

    /// Parses and installs ONE trusted catalog for a strictly newer live
    /// epoch. Invalid catalogs are refused (`descriptorInvalid`) and leave the
    /// previous state untouched; a successful bind fences previous waiters and
    /// replaces (never accumulates) owned registry entries.
    @discardableResult
    public func bind(epoch newEpoch: UInt64, catalogJSON: Data) -> Int32 {
        guard newEpoch != 0 else { return PlatformToolHostStatus.shape }
        guard currentEpoch() == newEpoch else {
            return PlatformToolHostStatus.generationFenced
        }
        let catalog: PlatformToolCatalog
        do {
            catalog = try PlatformToolCatalogParser.parse(catalogJSON)
        } catch let error as PlatformToolCatalogError {
            noteBindFailure(error.code)
            return PlatformToolHostStatus.descriptorInvalid
        } catch {
            noteBindFailure("malformed:catalog")
            return PlatformToolHostStatus.descriptorInvalid
        }

        condition.lock()
        guard newEpoch > epoch else {
            condition.unlock()
            noteBindFailure("malformed:epoch")
            return PlatformToolHostStatus.descriptorInvalid
        }
        let priorNames = installedNames
        condition.unlock()
        // Fail closed if another runtime source already owns one of these
        // names at bind time. Names this mailbox installed are replaceable.
        // This runs WITHOUT the mailbox lock because the registry lookup asks
        // our runner's `isAvailable`, which re-enters this lock.
        for entry in catalog.entries where !priorNames.contains(entry.name) {
            if registry.descriptor(named: entry.name) != nil {
                noteBindFailure("nameCollision:\(entry.name)")
                return PlatformToolHostStatus.descriptorInvalid
            }
        }

        var resumes: [CheckedContinuation<PlatformToolResult,
                                          PlatformToolTransportError>] = []
        condition.lock()
        guard newEpoch > epoch else {
            condition.unlock()
            noteBindFailure("malformed:epoch")
            return PlatformToolHostStatus.descriptorInvalid
        }
        resumes = fenceAllLocked()
        uninstallLocked()
        var newEntries: [String: PlatformToolCatalogEntry] = [:]
        for entry in catalog.entries { newEntries[entry.name] = entry }
        entries = newEntries
        epoch = newEpoch
        closed = false
        lastBindFailure = ""
        installLocked(catalog)
        counters.binds += 1
        condition.broadcast()
        condition.unlock()
        for continuation in resumes { continuation.resume(throwing: .hostFenced) }
        return PlatformToolHostStatus.ok
    }

    /// Exact-epoch teardown. Removes every owned runner and fences every
    /// waiter; a late completion is classified, never resumed.
    public func close(epoch closing: UInt64) {
        var resumes: [CheckedContinuation<PlatformToolResult,
                                          PlatformToolTransportError>] = []
        condition.lock()
        guard closing == epoch, epoch != 0 else { condition.unlock(); return }
        closed = true
        resumes = fenceAllLocked()
        uninstallLocked()
        condition.broadcast()
        condition.unlock()
        for continuation in resumes { continuation.resume(throwing: .hostClosed) }
    }

    /// Publishes the ACTUAL currently-usable subset of the already-bound
    /// catalog for the SAME live root epoch. The Full host calls this on
    /// service/permission enable/disable without reopening the catalog or
    /// faking a new epoch.
    ///
    /// Validation is atomic: an unknown, duplicate or oversized name set is
    /// refused and the previous mask stays intact. A successful publish:
    ///   * replaces the mask for this epoch;
    ///   * fences QUEUED tickets whose tool is no longer available (they never
    ///     reached the host and resume as `hostFenced`, never success);
    ///   * leaves already-CLAIMED tickets alive so the real in-flight host
    ///     work settles exactly once (its cancellation/failure authority is
    ///     unchanged);
    ///   * clears on any rebind/close.
    @discardableResult
    public func setAvailability(epoch requested: UInt64, namesJSON: Data) -> Int32 {
        guard requested != 0 else { return PlatformToolHostStatus.shape }
        guard namesJSON.count > 0,
              namesJSON.count <= PlatformToolHostLimits.maximumAvailabilityBytes
        else { return PlatformToolHostStatus.oversized }
        guard let requestedNames = Self.parseAvailability(namesJSON) else {
            return PlatformToolHostStatus.descriptorInvalid
        }
        guard currentEpoch() == requested else {
            return PlatformToolHostStatus.generationFenced
        }

        var fenced: [CheckedContinuation<PlatformToolResult,
                                          PlatformToolTransportError>] = []
        condition.lock()
        guard !closed, epoch != 0, epoch == requested else {
            condition.unlock()
            return PlatformToolHostStatus.generationFenced
        }
        guard requestedNames.allSatisfy({ installedNames.contains($0) }) else {
            condition.unlock()
            return PlatformToolHostStatus.descriptorInvalid
        }
        var newlyFenced: [Int64] = []
        for (claim, ticket) in tickets
        where ticket.state == 0 && !requestedNames.contains(ticket.toolName) {
            if let continuation = ticket.continuation {
                ticket.continuation = nil
                fenced.append(continuation)
            }
            newlyFenced.append(claim)
            counters.fenced += 1
        }
        for claim in newlyFenced {
            retireLocked(claim)
        }
        if !newlyFenced.isEmpty {
            queue.removeAll { tickets[$0] == nil }
        }
        availableNames = requestedNames
        availabilityPublished = true
        counters.availabilitySets += 1
        condition.broadcast()
        condition.unlock()
        for continuation in fenced {
            continuation.resume(throwing: .hostFenced)
        }
        return PlatformToolHostStatus.ok
    }

    private static func parseAvailability(_ data: Data) -> Set<String>? {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let list = raw as? [Any],
              list.count <= PlatformToolHostLimits.maximumTools else {
            return nil
        }
        var names: Set<String> = []
        for value in list {
            guard let name = value as? String,
                  !name.isEmpty,
                  name.utf8.count <= PlatformToolHostLimits.maximumNameCharacters,
                  names.insert(name).inserted else {
                return nil
            }
        }
        return names
    }

    // MARK: Trusted ordinary-automatic admission (same-epoch, host-published)

    /// Publishes the trusted durable user ceilings for ordinary automatic
    /// approval for the SAME live epoch that already bound this mailbox.
    /// This is a STATEMENT FROM THE TRUSTED FULL HOST about settings it
    /// already enforces (`DeviceAccessHost.autoAdmissionJson`); it is never
    /// model input and it mints no approval identity. The canonical
    /// `ApprovalPolicy` pipeline consults the snapshot through
    /// `autoAdmissionForCurrentEpoch()` and issues the real grant.
    ///
    /// A malformed publication is refused atomically (`descriptorInvalid`)
    /// and leaves the previous snapshot untouched; a fenced/stale epoch is
    /// refused (`generationFenced`). Rebind/close clear the snapshot with
    /// the rest of the generation state, so a retired ceiling can never
    /// authorize a new generation.
    @discardableResult
    public func setAutoAdmission(epoch requested: UInt64,
                                 admissionJSON: Data) -> Int32 {
        guard requested != 0 else { return PlatformToolHostStatus.shape }
        guard !admissionJSON.isEmpty else { return PlatformToolHostStatus.shape }
        guard admissionJSON.count <= PlatformToolHostLimits.maximumAutoAdmissionBytes
        else { return PlatformToolHostStatus.oversized }
        guard currentEpoch() == requested else {
            return PlatformToolHostStatus.generationFenced
        }
        let admission: PlatformToolAutoAdmission
        do {
            admission = try PlatformToolAutoAdmissionParser.parse(admissionJSON)
        } catch {
            return PlatformToolHostStatus.descriptorInvalid
        }
        condition.lock()
        defer { condition.unlock() }
        guard !closed, epoch != 0, epoch == requested else {
            return PlatformToolHostStatus.generationFenced
        }
        autoAdmission = admission
        autoAdmissionEpoch = requested
        counters.admissionSets += 1
        return PlatformToolHostStatus.ok
    }

    /// Snapshot of the trusted admission for the CURRENT live epoch only.
    /// Returns nil for a stale/closed/rebound generation or before any
    /// successful publication, keeping ordinary automatic calls on the
    /// actual interactive/model gate (fail closed).
    public func autoAdmissionForCurrentEpoch() -> PlatformToolAutoAdmission? {
        let live = currentEpoch()
        condition.lock()
        defer { condition.unlock() }
        guard !closed, epoch != 0, epoch == live,
              autoAdmissionEpoch == epoch,
              let admission = autoAdmission else { return nil }
        return admission
    }

    /// A single mailbox snapshot of the selected ceiling and discoverable
    /// tool. Recheck the native epoch after releasing the condition so the
    /// query never nests the native-root and mailbox locks.
    public func autoAdmissionEligibilitySnapshot(named name: String)
        -> PlatformToolAutoAdmission? {
        guard let live = currentEpoch(), live != 0 else { return nil }
        condition.lock()
        let snapshot: PlatformToolAutoAdmission?
        if !closed, epoch == live, autoAdmissionEpoch == live,
           availabilityPublished, installedNames.contains(name),
           entries[name] != nil, availableNames.contains(name) {
            snapshot = autoAdmission
        } else {
            snapshot = nil
        }
        condition.unlock()
        guard currentEpoch() == live else { return nil }
        return snapshot
    }

    // MARK: Execution (registered runner body)

    public func execute(toolName requestedName: String, argumentsJSON: Data,
                        context: ToolContext) async throws -> ToolExecutionOutput {
        // Bounded legacy alias (exactly phone.observe/act/screenshot →
        // device.*): a call minted from a persisted pre-rename record keeps
        // its identity across the rename and dispatches against the canonical
        // catalog entry. Unknown phone.* names pass through unchanged and
        // fail closed at the exact-name catalog lookup below — never a
        // universal alias.
        let toolName = DeviceToolNames.canonical(requestedName)
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Device and system tools are unavailable in temporary chat; open a task")
        }
        guard let taskID = context.conversationID else {
            throw FloeError.validationFailed(
                "Device and system tools require a task-owned run")
        }
        guard context.childExecution == nil else {
            throw FloeError.validationFailed(
                "Device and system tools are main-run only")
        }
        if let origin = context.callOrigin {
            guard origin.kind == .mainRunDelegate,
                  origin.runID == context.runID,
                  origin.toolName == requestedName,
                  origin.callID == (context.toolCallID ?? "") else {
                throw FloeError.validationFailed(
                    "Device and system tools are main-run only")
            }
        }
        if let ceiling = context.allowedToolNames,
           !DeviceToolNames.ceilingAllows(ceiling, name: toolName) {
            throw FloeError.validationFailed(
                "This tool is outside the task's effective capability set")
        }
        if let frozen = context.frozenEffectiveCatalogNames,
           !frozen.contains(toolName) {
            throw FloeError.validationFailed(
                "This tool is not part of the task's offered catalog")
        }

        // Snapshot through a synchronous helper: NSLocking is unavailable
        // directly from async contexts, and the other mailbox families keep
        // their critical sections in synchronous functions for the same
        // reason.
        let snapshot = installedEntry(named: toolName)
        let boundEpoch = snapshot.epoch
        let entry = snapshot.entry
        guard snapshot.installed, let entry else {
            throw FloeError.invalidConfiguration(
                "Device and system tools are unavailable for this runtime generation")
        }
        guard snapshot.available else {
            // Registered but not published as actually usable for this
            // generation (or explicitly disabled while the epoch stayed the
            // same). Discovery hides it and direct execution fails closed.
            throw FloeError.invalidConfiguration(
                "Device and system tools are unavailable for the current runtime generation")
        }
        guard let live = currentEpoch(), live != 0, live == boundEpoch else {
            throw FloeError.invalidConfiguration(
                "Device and system tools are unavailable until the runtime is ready")
        }
        // Current approved metadata still constrains execution here, even
        // though the runtime already enforced the boundary at dispatch.
        if entry.isSideEffecting, context.approvalGrantID == nil {
            throw FloeError.validationFailed(
                "This device action requires an approved task grant")
        }
        if entry.requiresHostScope, context.scope == .local {
            throw FloeError.validationFailed(
                "This tool requires an authorized host scope")
        }
        do {
            try PlatformToolSchemaValidator.validateArguments(
                argumentsJSON, schemaJSON: entry.schemaJSON)
        } catch {
            throw FloeError.validationFailed(
                "Invalid arguments for platform tool '\(toolName)'")
        }

        let owner = PlatformToolOwner(
            taskID: taskID,
            runID: context.runID,
            epoch: boundEpoch,
            toolCallID: Self.boundedToken(context.toolCallID),
            toolIdempotencyKey: Self.boundedToken(context.toolIdempotencyKey),
            clientSessionID: Self.boundedToken(context.clientSessionID),
            approvalGrantID: context.approvalGrantID,
            scope: context.scope
        )
        let result: PlatformToolResult
        do {
            do {
                result = try await submit(entry: entry, argumentsJSON: argumentsJSON,
                                          owner: owner, cancellation: context.cancellation)
            } catch PlatformToolTransportError.remoteFailed(let code, let detail)
                where PlatformDeviceWireCode.isPausePrompt(PlatformDeviceWireCode.canonical(code))
                    && DeviceToolNames.allInteractionNames.contains(toolName) {
                // Park through the SAME durable question coordinator, after
                // the transport ticket has retired. Pause fences observations;
                // an interrupted action's old observation must be refreshed.
                // Background jobs and other platform tickets remain independent.
                guard let coordinator = UserQuestionHostAPI.shared.current(epoch: boundEpoch),
                      !owner.toolCallID.isEmpty else { throw PlatformToolTransportError.hostFenced }
                let chinese = Locale.current.identifier.lowercased().hasPrefix("zh")
                let canonicalCode = PlatformDeviceWireCode.canonical(code)
                let paused = canonicalCode == "device_paused_by_user"
                let pauseID = paused ? detail.flatMap(UUID.init(uuidString:)) : nil
                if paused && pauseID == nil { throw PlatformToolTransportError.hostFenced }
                let unlocking = !paused && canonicalCode != "device_presence_required"
                let question = UserQuestionDraft(id: pauseID.map { "phone-control-paused-\($0.uuidString.lowercased())" } ?? "phone-control-presence",
                    question: paused
                        ? (chinese ? "设备操作已暂停。允许这个任务继续吗？" : "Device control is paused. Allow this task to continue?")
                        : unlocking
                        ? (chinese ? "请解锁设备后选择继续。" : "Unlock the device, then choose Continue.")
                        : (chinese ? "你正在使用设备，允许任务接管屏幕吗？" : "Allow the task to use the screen while you are using the device?"),
                    options: [
                        UserQuestionOption(id: "allow", label: chinese ? (unlocking || paused ? "继续" : "允许") : (unlocking || paused ? "Continue" : "Allow")),
                        UserQuestionOption(id: "keep-control", label: chinese ? "保留我的控制权" : "Keep control")
                    ], allowsFreeText: false)
                let receipt = try await coordinator.ask(
                    UserQuestionRequest(waitPolicy: .required, questions: [question]),
                    runID: context.runID, conversationID: taskID, toolCallID: owner.toolCallID,
                    cancellation: context.cancellation, temporaryReadOnly: context.temporaryReadOnly)
                try context.cancellation.throwIfCancelled()
                guard receipt.status == .answered,
                      let answer = receipt.answers.first(where: { $0.source == .human }),
                      answer.selectedOptionIDs == ["allow"], let answeredAt = answer.answeredAt,
                      currentEpoch() == boundEpoch, isBound(to: boundEpoch) else {
                    throw FloeError.validationFailed("Device control was not allowed. Continue independent background work; do not retry UI control without a new user decision.")
                }
                // This timestamp is generated from the actual human CAS answer,
                // not from model arguments. Existing task/approval ceilings remain.
                result = try await submit(entry: entry, argumentsJSON: argumentsJSON,
                    owner: owner, cancellation: context.cancellation,
                    presenceApprovedAtMillis: Int64(answeredAt.timeIntervalSince1970 * 1_000), pauseApprovalID: pauseID)
            }
        } catch let error as PlatformToolTransportError {
            if context.cancellation.isCancelled { throw FloeError.cancelled }
            throw Self.mapped(error)
        }
        try context.cancellation.throwIfCancelled()
        // Generation currentness BEFORE completion: a rebound/closed mailbox
        // can never present an old-generation action as the current result.
        guard currentEpoch() == boundEpoch, isBound(to: boundEpoch) else {
            throw FloeError.invalidConfiguration(
                "Device and system tool generation changed before completion")
        }
        return Self.output(result)
    }

    // MARK: Ticket transport

    public func submit(entry: PlatformToolCatalogEntry,
                       argumentsJSON: Data,
                       owner: PlatformToolOwner,
                       cancellation: CancellationToken, presenceApprovedAtMillis: Int64 = 0, pauseApprovalID: UUID? = nil) async throws
        -> PlatformToolResult {
        guard argumentsJSON.count > 0,
              argumentsJSON.count <= PlatformToolHostLimits.maximumArgumentsBytes
        else { throw PlatformToolTransportError.oversized }
        guard owner.epoch != 0 else { throw PlatformToolTransportError.hostUnbound }
        guard !cancellation.isCancelled else {
            throw PlatformToolTransportError.cancelled
        }
        guard let descriptor = Self.descriptorJSON(
            entry: entry, owner: owner, arguments: argumentsJSON,
            presenceApprovedAtMillis: presenceApprovedAtMillis, pauseApprovalID: pauseApprovalID),
              descriptor.count <= PlatformToolHostLimits.maximumTicketDescriptorBytes
        else { throw PlatformToolTransportError.oversized }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<PlatformToolResult,
                                               PlatformToolTransportError>) in
            condition.lock()
            guard !closed, epoch != 0 else {
                counters.unbound += 1
                condition.unlock()
                continuation.resume(throwing: .hostUnbound)
                return
            }
            guard entries[entry.name] != nil, installedNames.contains(entry.name)
            else {
                counters.unbound += 1
                condition.unlock()
                continuation.resume(throwing: .hostUnbound)
                return
            }
            guard owner.epoch == epoch else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: .hostFenced)
                return
            }
            guard availabilityPublished,
                  availableNames.contains(entry.name) else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: .hostFenced)
                return
            }
            guard tickets.count < PlatformToolHostLimits.maximumLiveTickets else {
                counters.saturated += 1
                condition.unlock()
                continuation.resume(throwing: .saturated)
                return
            }
            counter &+= 1
            let ticket = Ticket(
                claim: counter,
                toolName: entry.name,
                descriptor: descriptor,
                payload: argumentsJSON,
                owner: owner,
                epoch: epoch,
                deadline: DispatchTime.now()
                    + .milliseconds(PlatformToolHostLimits.budgetMillis(toolName: entry.name)),
                cancellation: cancellation)
            ticket.continuation = continuation
            tickets[counter] = ticket
            queue.append(counter)
            counters.submitted += 1
            condition.broadcast()
            condition.unlock()
        }
    }

    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        var expired: [CheckedContinuation<PlatformToolResult,
                                           PlatformToolTransportError>] = []
        defer {
            for continuation in expired {
                continuation.resume(throwing: .hostBudget)
            }
        }
        condition.lock()
        let deadline = Date(
            timeIntervalSinceNow:
                Double(max(0, Int(max(0, timeoutMillis)))) / 1000)
        var claim: Int64 = 0
        while true {
            if closed || epoch == 0 { break }
            if let head = queue.first {
                queue.removeFirst()
                guard let ticket = tickets[head], ticket.state == 0 else {
                    continue
                }
                if ticket.deadline < DispatchTime.now() {
                    expireLocked(head, into: &expired)
                    continue
                }
                ticket.state = 1
                counters.claimed += 1
                claim = head
                break
            }
            if condition.wait(until: deadline) { continue }
            for (pending, ticket) in tickets
                where ticket.state == 0
                    && ticket.deadline < DispatchTime.now() {
                expireLocked(pending, into: &expired)
            }
            break
        }
        condition.unlock()
        return claim
    }

    public func describe(claim: Int64, buffer: UnsafeMutablePointer<CChar>?,
                         capacity: Int32) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            condition.unlock()
            return PlatformToolHostStatus.staleClaim
        }
        let descriptor = ticket.descriptor
        condition.unlock()
        guard descriptor.count <= PlatformToolHostLimits.maximumTicketDescriptorBytes
        else { return PlatformToolHostStatus.descriptorInvalid }
        guard capacity >= 0, let buffer,
              descriptor.count + 1 <= Int(capacity) else {
            return PlatformToolHostStatus.bufferTooSmall
        }
        descriptor.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, descriptor.count)
        }
        buffer[descriptor.count] = 0
        return Int32(descriptor.count)
    }

    public func payloadLength(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            return PlatformToolHostStatus.staleClaim
        }
        guard ticket.payload.count <= PlatformToolHostLimits.maximumArgumentsBytes
        else { return PlatformToolHostStatus.oversized }
        return Int32(ticket.payload.count)
    }

    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?,
                            capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            return PlatformToolHostStatus.staleClaim
        }
        guard capacity >= 0, let buffer, capacity >= ticket.payload.count else {
            return PlatformToolHostStatus.bufferTooSmall
        }
        guard !ticket.payload.isEmpty else { return 0 }
        ticket.payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, ticket.payload.count)
        }
        return Int32(ticket.payload.count)
    }

    public func isLive(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.createdEpoch == epoch,
              !closed else { return 0 }
        return ticket.state == 0
            || (ticket.state == 1 && ticket.continuation != nil) ? 1 : 0
    }

    public func shouldStop(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else { return 1 }
        return ticket.cancellation.isCancelled ? 1 : 0
    }

    /// Trusted-host context snapshot for ONE claimed ticket: the workspace
    /// APK staging seam (`floe_platform_tool_stage_workspace_apk`) derives
    /// task/run/epoch authority ONLY from this value, never from model text.
    /// nil unless the ticket exists, is claimed (state 1), belongs to the
    /// current bound epoch and the mailbox is open.
    public func claimedContext(claim: Int64) -> PlatformToolClaimContext? {
        condition.lock()
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            condition.unlock()
            return nil
        }
        let snapshot = PlatformToolClaimContext(
            claim: claim,
            toolName: ticket.toolName,
            owner: ticket.owner,
            deadline: ticket.deadline,
            mailbox: self)
        condition.unlock()
        return snapshot
    }

    /// Live currency re-proof for ONE claimed ticket. `cancelled` is reported
    /// only while the owning call's own cancellation token fired; every other
    /// deviation (settled, queued, rebind, close, epoch change) is `fenced`,
    /// so a stale generation can never present itself as a fresh refusal.
    public func claimCurrency(claim: Int64) -> PlatformToolClaimCurrency {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1, !closed,
              ticket.createdEpoch == epoch else { return .fenced }
        return ticket.cancellation.isCancelled ? .cancelled : .current
    }

    /// Settles one claimed ticket exactly once. `status == 0` requires a
    /// bounded, structurally valid result whose artifact bytes are verified
    /// on disk. A success arriving after cancellation is refused (`-109`) and
    /// resumes the caller with `cancelled`, so success is never observed after
    /// cancel.
    @discardableResult
    public func complete(claim: Int64, status: Int32, value: Data) -> Int32 {
        guard status == 0 || status == 1 else {
            return PlatformToolHostStatus.shape
        }
        if status == 0 {
            guard !value.isEmpty,
                  value.count <= PlatformToolHostLimits.maximumReplyBytes else {
                return PlatformToolHostStatus.oversized
            }
        } else {
            guard value.count <= PlatformToolHostLimits.maximumFailureReplyBytes
            else { return PlatformToolHostStatus.oversized }
        }

        // Snapshot the live epoch BEFORE taking the mailbox lock: the epoch
        // reader belongs to the runtime bootstrap and must never be invited
        // to re-enter this mailbox's lock.
        let liveEpoch = currentEpoch()
        var resultArtifactRoot: URL?
        condition.lock()
        guard let ticket = tickets[claim] else {
            if retired.contains(claim) { counters.lateSettle += 1 }
            condition.unlock()
            return PlatformToolHostStatus.staleClaim
        }
        guard ticket.state == 1 else {
            condition.unlock()
            return PlatformToolHostStatus.notClaimed
        }
        guard ticket.createdEpoch == epoch, !closed else {
            counters.lateSettle += 1
            condition.unlock()
            return PlatformToolHostStatus.generationFenced
        }
        if status == 0, ticket.cancellation.isCancelled {
            let continuation = ticket.continuation
            ticket.continuation = nil
            ticket.state = 2
            counters.cancelled += 1
            condition.unlock()
            retireAndCount(claim)
            continuation?.resume(throwing: .cancelled)
            return PlatformToolHostStatus.cancelled
        }
        if status == 1 {
            let failure = Self.failure(from: value)
            let continuation = ticket.continuation
            ticket.continuation = nil
            ticket.state = 2
            counters.failed += 1
            condition.unlock()
            retireAndCount(claim)
            continuation?.resume(throwing: .remoteFailed(
                code: failure.code, detail: failure.detail))
            return PlatformToolHostStatus.ok
        }
        let continuation = ticket.continuation
        ticket.continuation = nil
        ticket.state = 2
        resultArtifactRoot = liveArtifactRootLocked(
            liveEpoch: liveEpoch, ticketEpoch: ticket.createdEpoch)
        condition.unlock()

        let parsed: Result<PlatformToolResult, PlatformToolResultError>
        do {
            parsed = .success(try PlatformToolResultParser.parse(
                value, artifactRoot: resultArtifactRoot))
        } catch let error as PlatformToolResultError {
            parsed = .failure(error)
        } catch {
            parsed = .failure(.invalid("result"))
        }
        retireAndCount(claim)
        switch parsed {
        case .success(let result):
            condition.lock()
            counters.completed += 1
            condition.unlock()
            continuation?.resume(returning: result)
            return PlatformToolHostStatus.ok
        case .failure:
            condition.lock()
            counters.invalid += 1
            condition.unlock()
            continuation?.resume(throwing: .resultInvalid)
            return PlatformToolHostStatus.descriptorInvalid
        }
    }

    /// Caller holds `condition`. A result artifact is acceptable ONLY when
    /// the bound root belongs to the ticket's own generation AND that
    /// generation is still the CURRENT live epoch; every other case fails
    /// closed (no fallback root).
    private func liveArtifactRootLocked(liveEpoch: UInt64?,
                                        ticketEpoch: UInt64) -> URL? {
        guard let root = artifactRoot, artifactRootEpoch != 0,
              artifactRootEpoch == ticketEpoch,
              artifactRootEpoch == liveEpoch else { return nil }
        return root
    }

    // MARK: Readbacks

    public func statsJSON() -> String {
        condition.lock()
        let object: [String: Any] = [
            "epoch": String(epoch),
            "closed": closed,
            "installed": installedNames.count,
            "live": tickets.count,
            "queued": queue.count,
            "lastBind": lastBindFailure,
            "artifactRootBound": artifactRoot != nil,
            "artifactRootEpoch": String(artifactRootEpoch),
            "availabilityPublished": availabilityPublished,
            "autoAdmissionPublished": autoAdmission != nil && autoAdmissionEpoch == epoch,
            "available": availabilityPublished ? availableNames.count : 0,
            "counters": [
                "binds": counters.binds,
                "submitted": counters.submitted,
                "claimed": counters.claimed,
                "completed": counters.completed,
                "failed": counters.failed,
                "cancelled": counters.cancelled,
                "invalid": counters.invalid,
                "lateSettle": counters.lateSettle,
                "fenced": counters.fenced,
                "saturated": counters.saturated,
                "unbound": counters.unbound,
                "expired": counters.expired,
                "bindRejections": counters.bindRejections,
                "availabilitySets": counters.availabilitySets,
                "admissionSets": counters.admissionSets,
            ],
        ]
        condition.unlock()
        return Self.encodeJSON(object) ?? #"{"error":"stats"}"#
    }

    public func readinessJSON() -> String {
        // Read the live generation BEFORE taking the mailbox lock: a caller
        // supplied epoch reader must never be invited to re-enter this lock.
        let live = currentEpoch()
        condition.lock()
        let bound = !closed && epoch != 0
        let names = installedNames.sorted()
        let current = bound && live == epoch
        let artifactRootBound = artifactRoot != nil && artifactRootEpoch != 0
            && artifactRootEpoch == live
        let published = availabilityPublished
        let admissionPublished = autoAdmission != nil && autoAdmissionEpoch == epoch
        let availableList = published ? availableNames.sorted() : []
        let reason: String
        if !bound {
            reason = epoch == 0 ? "hostUnbound" : "mailboxClosed"
        } else if live == nil || live == 0 {
            reason = "runtimeNotReady"
        } else if !current {
            reason = "generationMismatch"
        } else if !published {
            reason = "availabilityUnpublished"
        } else {
            reason = "ready"
        }
        let object: [String: Any] = [
            "version": 1,
            "lane": "platformTool",
            "bound": bound,
            "epoch": String(epoch),
            "available": current,
            "reason": reason,
            "installed": names.count,
            "registered": names,
            "availableNames": availableList,
            "availabilityPublished": published,
            "autoAdmissionPublished": admissionPublished,
            "maxTools": PlatformToolHostLimits.maximumTools,
            "lastBind": lastBindFailure,
            "artifactRootBound": artifactRootBound,
            "artifactRootEpoch": String(artifactRootEpoch),
        ]
        condition.unlock()
        return Self.encodeJSON(object) ?? #"{"error":"readiness"}"#
    }

    // MARK: Registry ownership

    private func installLocked(_ catalog: PlatformToolCatalog) {
        for entry in catalog.entries {
            let tool = makeRunner(entry)
            registry.register(tool)
            installedNames.insert(entry.name)
        }
    }

    private func uninstallLocked() {
        let names = installedNames
        if !names.isEmpty {
            registry.unregister(where: { names.contains($0) })
        }
        installedNames.removeAll()
        entries.removeAll()
        availableNames.removeAll()
        availabilityPublished = false
        autoAdmission = nil
        autoAdmissionEpoch = 0
    }

    private func makeRunner(_ entry: PlatformToolCatalogEntry) -> AnyAgentTool {
        var tool = AnyAgentTool(
            descriptor: entry.descriptor,
            run: { [weak self] argumentsJSON, context in
                guard let self else {
                    throw FloeError.invalidConfiguration(
                        "Device and system tools are unavailable")
                }
                return try await self.execute(
                    toolName: entry.name, argumentsJSON: argumentsJSON,
                    context: context)
            },
            validateArguments: { argumentsJSON in
                try PlatformToolSchemaValidator.validateArguments(
                    argumentsJSON, schemaJSON: entry.schemaJSON)
            }
        )
        tool.isAvailable = { [weak self] in
            self?.isToolAvailable(named: entry.name) ?? false
        }
        return tool
    }

    // MARK: Fencing

    private func fenceAllLocked() -> [CheckedContinuation<PlatformToolResult,
                                                          PlatformToolTransportError>] {
        var resumes: [CheckedContinuation<PlatformToolResult,
                                           PlatformToolTransportError>] = []
        let claims = Array(tickets.keys)
        for claim in claims {
            if let ticket = tickets[claim],
               let continuation = ticket.continuation {
                ticket.continuation = nil
                resumes.append(continuation)
            }
            retireLocked(claim)
        }
        queue.removeAll()
        return resumes
    }

    private func retireLocked(_ claim: Int64) {
        tickets.removeValue(forKey: claim)
        retired.insert(claim)
        retiredOrder.append(claim)
        while retiredOrder.count > PlatformToolHostLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    private func retireAndCount(_ claim: Int64) {
        condition.lock()
        retireLocked(claim)
        condition.broadcast()
        condition.unlock()
    }

    private func expireLocked(
        _ claim: Int64,
        into expired: inout [CheckedContinuation<PlatformToolResult,
                                                   PlatformToolTransportError>]
    ) {
        guard let ticket = tickets[claim], ticket.state == 0,
              let continuation = ticket.continuation else { return }
        ticket.continuation = nil
        counters.expired += 1
        retireLocked(claim)
        queue.removeAll { $0 == claim }
        expired.append(continuation)
    }

    private func noteBindFailure(_ code: String) {
        let bounded = String(code.prefix(160))
        condition.lock()
        lastBindFailure = bounded
        counters.bindRejections += 1
        condition.unlock()
    }

    // MARK: Encoding

    private static func descriptorJSON(entry: PlatformToolCatalogEntry,
                                       owner: PlatformToolOwner,
                                       arguments: Data, presenceApprovedAtMillis: Int64 = 0, pauseApprovalID: UUID? = nil) -> Data? {
        let scopeData = (try? JSONEncoder().encode(owner.scope)) ?? Data()
        guard scopeData.count > 0,
              scopeData.count <= PlatformToolHostLimits.maximumScopeBytes,
              let scopeObject = try? JSONSerialization.jsonObject(
                with: scopeData) else { return nil }
        let object: [String: Any] = [
            "version": 1,
            "operation": "platformTool.execute",
            "presenceApprovedAtMillis": max(0, presenceApprovedAtMillis),
            "phonePauseApprovalID": pauseApprovalID?.uuidString.lowercased() ?? "",
            "tool": entry.name,
            "epoch": String(owner.epoch),
            "taskID": owner.taskID.uuidString,
            "runID": owner.runID.uuidString,
            "toolCallID": owner.toolCallID,
            "idempotencyKey": owner.toolIdempotencyKey,
            "clientSessionID": owner.clientSessionID,
            "approvalGrantID": owner.approvalGrantID?.uuidString ?? "",
            "scope": scopeObject,
            "argumentsBytes": arguments.count,
            "argumentsSHA256": FloeDigest.sha256Hex(arguments),
            "budgetMs": PlatformToolHostLimits.budgetMillis(toolName: entry.name),
            "replyLimitBytes": PlatformToolHostLimits.maximumReplyBytes,
            "failureLimitBytes": PlatformToolHostLimits.maximumFailureReplyBytes,
            "riskLabels": entry.riskLabels.map(\.rawValue).sorted(),
            "effect": entry.effect.rawValue,
            "sideEffecting": entry.isSideEffecting,
            "hostScope": entry.requiresHostScope,
        ]
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object,
                                           options: [.sortedKeys])
    }

    private static func encodeJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func boundedToken(_ value: String?) -> String {
        guard let value else { return "" }
        let cleaned = String(value.filter { character in
            character.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        })
        return String(cleaned.prefix(PlatformToolHostLimits.maximumOwnerTokenCharacters))
    }

    private static func output(_ result: PlatformToolResult) -> ToolExecutionOutput {
        let artifacts = result.artifact.map { [$0] } ?? []
        return ToolExecutionOutput(
            summary: result.modelVisibleSummary,
            fullOutputSHA256: result.rawJSONSHA256,
            exitStatus: result.exitStatus,
            artifacts: artifacts,
            maximumSummaryCharacters: 4_096
        )
    }

    private struct FailureBody: Decodable {
        let code: String
        let detail: String?
    }

    private static func failure(from data: Data) -> (code: String, detail: String?) {
        guard !data.isEmpty,
              let body = try? JSONDecoder().decode(FailureBody.self, from: data),
              isValidFailureCode(body.code) else {
            return ("internal", nil)
        }
        let detail = body.detail.map { value -> String in
            let cleaned = String(value.filter { character in
                character.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
            })
            return String(cleaned.prefix(PlatformToolHostLimits.maximumDetailCharacters))
        }
        return (body.code, detail)
    }

    private static func isValidFailureCode(_ code: String) -> Bool {
        guard !code.isEmpty,
              code.count <= PlatformToolHostLimits.maximumCodeCharacters,
              let first = code.first, first.isLetter else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-")
        }
    }

    private static func mapped(_ error: PlatformToolTransportError) -> FloeError {
        switch error {
        case .cancelled:
            return .cancelled
        case .hostUnbound, .hostClosed, .hostFenced:
            return .invalidConfiguration(
                "Device and system tools are unavailable for the current runtime generation")
        case .hostBudget:
            return .validationFailed("The device tool timed out")
        case .saturated:
            return .validationFailed(
                "Too many device tool calls are already running; retry shortly")
        case .oversized:
            return .validationFailed(
                "The device tool request or reply exceeded its bounded size")
        case .resultInvalid:
            return .internalError("The device returned an invalid tool result")
        case .remoteFailed(let rawCode, let detail):
            let code = PlatformDeviceWireCode.canonical(rawCode)
            switch code {
            case "cancelled":
                return .cancelled
            case "timeout":
                return .validationFailed("The device tool timed out")
            case "device_run_unavailable":
                let chinese = Locale.current.identifier.lowercased().hasPrefix("zh")
                if detail?.hasPrefix("snapshot_") == true {
                    return .validationFailed(chinese
                        ? "暂时无法读取此任务的运行状态，设备操作已停止。"
                        : "Device control stopped because the task's running state could not be read.")
                }
                return .validationFailed(chinese
                    ? "无法确认此任务仍在运行，设备操作已停止。请打开任务查看状态。"
                    : "Device control stopped because this task is no longer confirmed running. Open the task to check its status.")
            case "permissionRequired", "notAuthorized", "unauthorized":
                return .validationFailed(
                    "Android permission or user authorization is required for this action")
            case "serviceUnavailable", "unavailable":
                return .invalidConfiguration(
                    "The device system service is unavailable")
            case "invalidArguments", "requestInvalid", "requestTooLarge":
                return .validationFailed("The device refused this tool request")
            default:
                return .internalError("Device tool failed (\(code))")
            }
        }
    }
}

// MARK: - Trusted-host C ABI (Kotlin Full host pump only; NOT a V3 command)

private func platformToolCopyCString(
    _ value: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32
) -> Int32 {
    guard capacity >= 0, let buffer else { return PlatformToolHostStatus.shape }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else {
        return PlatformToolHostStatus.bufferTooSmall
    }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

@_cdecl("floe_platform_tool_bind")
public func floePlatformToolBind(_ epoch: UInt64,
                                 _ catalog: UnsafePointer<UInt8>?,
                                 _ catalogLength: Int32) -> Int32 {
    guard epoch != 0 else { return PlatformToolHostStatus.shape }
    guard catalogLength > 0, let catalog else {
        return PlatformToolHostStatus.shape
    }
    guard catalogLength <= Int32(PlatformToolHostLimits.maximumCatalogBytes) else {
        return PlatformToolHostStatus.oversized
    }
    guard G02NativeRootEpoch.readback() == epoch else {
        return PlatformToolHostStatus.generationFenced
    }
    let data = Data(bytes: catalog, count: Int(catalogLength))
    return PlatformToolHostMailbox.shared.bind(epoch: epoch, catalogJSON: data)
}

@_cdecl("floe_platform_tool_next")
public func floePlatformToolNext(_ timeoutMillis: Int32) -> Int64 {
    PlatformToolHostMailbox.shared.nextClaim(
        timeoutMillis: min(1_000, max(0, timeoutMillis)))
}

@_cdecl("floe_platform_tool_describe")
public func floePlatformToolDescribe(_ claim: Int64,
                                     _ buffer: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    PlatformToolHostMailbox.shared.describe(
        claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_platform_tool_payload_length")
public func floePlatformToolPayloadLength(_ claim: Int64) -> Int32 {
    PlatformToolHostMailbox.shared.payloadLength(claim: claim)
}

@_cdecl("floe_platform_tool_take_payload")
public func floePlatformToolTakePayload(_ claim: Int64,
                                        _ buffer: UnsafeMutablePointer<UInt8>?,
                                        _ capacity: Int32) -> Int32 {
    PlatformToolHostMailbox.shared.takePayload(
        claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_platform_tool_is_live")
public func floePlatformToolIsLive(_ claim: Int64) -> Int32 {
    PlatformToolHostMailbox.shared.isLive(claim: claim)
}

@_cdecl("floe_platform_tool_should_stop")
public func floePlatformToolShouldStop(_ claim: Int64) -> Int32 {
    PlatformToolHostMailbox.shared.shouldStop(claim: claim)
}

@_cdecl("floe_platform_tool_complete")
public func floePlatformToolComplete(_ claim: Int64, _ status: Int32,
                                     _ value: UnsafePointer<UInt8>?,
                                     _ valueLength: Int32) -> Int32 {
    guard status == 0 || status == 1, valueLength >= 0,
          valueLength > 0, value != nil else {
        return PlatformToolHostStatus.shape
    }
    let data = Data(bytes: value!, count: Int(valueLength))
    return PlatformToolHostMailbox.shared.complete(
        claim: claim, status: status, value: data)
}

/// Readback of the ONE bound actual artifact root (`<owned root>/FloeAgent`)
/// for the trusted Full host. Returns `generationFenced` unless the binding
/// still belongs to the current live root epoch. This is a host-to-storage
/// handoff only: it is not a V3 command, not model-visible and never appears
/// in ordinary errors.
@_cdecl("floe_platform_tool_artifact_root")
public func floePlatformToolArtifactRoot(
    _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32
) -> Int32 {
    guard let path = PlatformToolHostMailbox.shared.artifactRootPathForTrustedHost()
    else { return PlatformToolHostStatus.generationFenced }
    return platformToolCopyCString(path, buffer: buffer, capacity: capacity)
}

/// Same-epoch discoverability publish from the trusted Full host: a bounded
/// JSON array of names (subset of the already-registered catalog). No
/// metadata/schema rebind and no epoch fabrication; a later call replaces the
/// mask. Invalid/unknown/duplicate/oversized sets are refused atomically.
@_cdecl("floe_platform_tool_set_availability")
public func floePlatformToolSetAvailability(
    _ epoch: UInt64, _ namesJSON: UnsafePointer<UInt8>?, _ namesLength: Int32
) -> Int32 {
    guard epoch != 0 else { return PlatformToolHostStatus.shape }
    guard namesLength > 0, let namesJSON else {
        return PlatformToolHostStatus.shape
    }
    guard namesLength <= Int32(PlatformToolHostLimits.maximumAvailabilityBytes)
    else { return PlatformToolHostStatus.oversized }
    guard G02NativeRootEpoch.readback() == epoch else {
        return PlatformToolHostStatus.generationFenced
    }
    let data = Data(bytes: namesJSON, count: Int(namesLength))
    return PlatformToolHostMailbox.shared.setAvailability(
        epoch: epoch, namesJSON: data)
}

/// Trusted durable-ceiling publish for ordinary automatic approval from the
/// Full host: the SAME bounded admission JSON
/// (`{"version":1,"packageManagement":bool,"fileWrites":bool,
///   "fileRootIds":[...], "advancedTools":[...]?}`, <= 16 KiB) for the SAME
/// live native root epoch. This is not a V3 command, not model-visible and
/// never appears in ordinary errors; it mints no approval identity — the
/// canonical approval pipeline issues the real grant only when the snapshot
/// covers the exact call. Malformed bodies are refused (`descriptorInvalid`)
/// atomically; stale epochs are fenced; rebind/close/revoke clears.
@_cdecl("floe_platform_tool_set_auto_admission")
public func floePlatformToolSetAutoAdmission(
    _ epoch: UInt64, _ json: UnsafePointer<UInt8>?, _ length: Int32
) -> Int32 {
    guard epoch != 0 else { return PlatformToolHostStatus.shape }
    guard length > 0, let json else { return PlatformToolHostStatus.shape }
    guard length <= Int32(PlatformToolHostLimits.maximumAutoAdmissionBytes) else {
        return PlatformToolHostStatus.oversized
    }
    guard G02NativeRootEpoch.readback() == epoch else {
        return PlatformToolHostStatus.generationFenced
    }
    let data = Data(bytes: json, count: Int(length))
    return PlatformToolHostMailbox.shared.setAutoAdmission(
        epoch: epoch, admissionJSON: data)
}

@_cdecl("floe_platform_tool_close")
public func floePlatformToolClose(_ epoch: UInt64) -> Int32 {
    PlatformToolHostMailbox.shared.close(epoch: epoch)
    return PlatformToolHostStatus.ok
}

@_cdecl("floe_platform_tool_stats")
public func floePlatformToolStats(_ buffer: UnsafeMutablePointer<CChar>?,
                                  _ capacity: Int32) -> Int32 {
    platformToolCopyCString(PlatformToolHostMailbox.shared.statsJSON(),
                            buffer: buffer, capacity: capacity)
}

@_cdecl("floe_platform_tool_readiness")
public func floePlatformToolReadiness(_ buffer: UnsafeMutablePointer<CChar>?,
                                      _ capacity: Int32) -> Int32 {
    platformToolCopyCString(PlatformToolHostMailbox.shared.readinessJSON(),
                            buffer: buffer, capacity: capacity)
}

/// Claimed task-workspace APK staging for the trusted Full host (Kotlin
/// `PlatformToolsNative.stageWorkspaceApk`). Streams the CURRENT task Linux
/// content — through the REAL split-UID live-files lane while ONE live
/// current-run session exists, otherwise from the CURRENT verified exported
/// workspace snapshot under an explicit no-live-writer proof — into the
/// App-owned verified inbox and returns <= 8 KiB metadata JSON. APK bytes
/// never cross this ABI. Returns >= 0 (reply UTF-8 byte length, NUL-
/// terminated when capacity allows) or a typed negative transport refusal
/// with no reply body (`staleClaim` when the claim is not live for the
/// current generation).
@_cdecl("floe_platform_tool_stage_workspace_apk")
public func floePlatformToolStageWorkspaceApk(
    _ claim: Int64,
    _ path: UnsafePointer<UInt8>?,
    _ pathLength: Int32,
    _ reply: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let path, pathLength > 0,
          pathLength <= Int32(PlatformToolHostLimits.maximumStageWorkspaceApkPathBytes),
          let reply, capacity >= 2 else {
        return PlatformToolHostStatus.shape
    }
    let pathBytes = Data(bytes: path, count: Int(pathLength))
    guard !pathBytes.contains(0) else { return PlatformToolHostStatus.shape }
    let mailbox = PlatformToolHostMailbox.shared
    guard let context = mailbox.claimedContext(claim: claim) else {
        return PlatformToolHostStatus.staleClaim
    }
    // Held bridge (LinuxWorkspaceAuthority.bridge precedent): the JNI/binder
    // thread stays attached until the transfer REALLY settles; the ticket's
    // own deadline bounds the loop, so a settlement always arrives and no
    // detached work can outlive the call. The post-read no-live-writer probe
    // closes the exported-snapshot race: any same-conversation session that
    // became live during the read turns the commit into a typed refusal and
    // the partial file is discarded.
    let ownerTaskID = context.owner.taskID
    let semaphore = DispatchSemaphore(value: 0)
    let box = WorkspaceBridgeBox<Result<PlatformToolWorkspaceApkMetadata,
                                        PlatformToolWorkspaceApkError>>()
    let task = Task {
        let components = RuntimeFacadeLinuxBindings.shared.components
        let result = await PlatformToolWorkspaceApkStager.stage(
            context: context,
            relativePathUTF8: pathBytes,
            resolver: PlatformToolWorkspaceApkProductionResolver(),
            transport: components?.liveFiles,
            inbox: mailbox.workspaceApkInboxBinding(),
            liveConversationProbe: {
                guard let backend = RuntimeFacadeLinuxBindings.shared.components?.backend
                else { return false }
                let sessions = await backend.ownedSessions()
                return sessions.contains {
                    !$0.leaseReleased && $0.conversationID == ownerTaskID
                }
            })
        box.value = result
        semaphore.signal()
    }
    _ = task
    semaphore.wait()
    let json: String
    switch box.value ?? .failure(.stagingUnavailable) {
    case .success(let metadata):
        json = PlatformToolWorkspaceApkStager.replyJSON(metadata)
            ?? #"{"version":1,"ok":false,"code":"staging_unavailable"}"#
    case .failure(let error):
        json = PlatformToolWorkspaceApkStager.replyJSON(error)
            ?? #"{"version":1,"ok":false,"code":"staging_unavailable"}"#
    }
    return platformToolCopyCString(json, buffer: reply, capacity: capacity)
}
