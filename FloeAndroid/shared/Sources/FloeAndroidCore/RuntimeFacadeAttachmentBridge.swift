// SPDX-License-Identifier: MPL-2.0
//
// RB-7 attachment staging — v3 binder handlers, async processors, the
// generation-scoped facade and the narrow staging JNI `_cdecl` ABI.
//
// Registration honesty: this package registers ONLY the seven EXISTING
// attachment command keys once Main's composition installs the lane with a
// real service (accepted epoch + owned store + RB1 pumps). Until then every
// one of the seven keeps its unchanged fail-closed `runtimeUnavailable`
// refusal from BridgeV3.route. No provider/run/skill/credential handler is
// registered here, no command or configuration label is added, and no fake
// success service is invented.
//
// Synchronous binder handlers (running on any JNI thread) do ONLY: strict
// envelope re-read, admission fence check, correlation dedupe, bounded
// receipt mint, mailbox enqueue, immediate receipt JSON return — the exact
// RB1 discipline. All file/DB effects run later on the mailbox processor
// tasks. The staging `_cdecl` ABI mirrors the reviewed runtime-owner shape:
// bounded C-string inputs, strict length caps, ASCII-validated receipts out,
// typed negative statuses, no JNI inside Swift, no continuations.
//
// Binary bytes cross ONLY through `floe_staging_write` / `floe_staging_read`
// / `floe_attachment_read` (64 KiB bound per call, app-private buffers).
// Committed-attachment reads additionally require a live READ GRANT that the
// `attachment.read` processor mints only after the ORIGINAL-row ownership
// verification settles — the grant table is a real, bounded, generation-
// scoped RAM authority (fail-closed when absent), never a dummy.
//
// Status space: the runtime owner ABI owns -2xx (frozen); this staging ABI
// owns -3xx (additive; documented in AttachmentStagingStatus). -105/-106
// keep their shared shape/buffer meanings across all lanes.
//
// This source is NOT compiled/executed by the authoring package.
import Foundation
import FloeModels
import FloePersistence

// MARK: - JNI-visible statuses (staging-owned -3xx space)

public enum AttachmentStagingStatus {
    public static let ok: Int32 = 0
    public static let invalidArguments: Int32 = -105   // shared shape rule
    public static let bufferTooSmall: Int32 = -106     // shared ASCII-copy rule
    public static let notInstalled: Int32 = -301
    public static let generationFenced: Int32 = -302
    public static let routeUnknown: Int32 = -303
    public static let routeTemporary: Int32 = -304
    public static let ingressUnknown: Int32 = -305
    public static let stateConflict: Int32 = -306
    public static let sizeExceeded: Int32 = -307
    public static let aggregateExceeded: Int32 = -308
    public static let diskFull: Int32 = -309
    public static let saturated: Int32 = -310
    public static let writeFailed: Int32 = -311
    public static let readFailed: Int32 = -312
    public static let handleUnknown: Int32 = -313
    public static let grantMissing: Int32 = -314
    public static let digestMismatch: Int32 = -315
    public static let partial: Int32 = -316            // short page: valid, not final
    public static let `internal`: Int32 = -399

    public static func code(for error: AttachmentStagingCode) -> Int32 {
        switch error {
        case .notInstalled: return notInstalled
        case .generationFenced: return generationFenced
        case .routeUnknown, .routeStale: return routeUnknown
        case .temporaryRefused: return routeTemporary
        case .ingressUnknown, .ingressUnfinished: return ingressUnknown
        case .handleUnknown: return handleUnknown
        case .stateConflict, .launchMarked, .alreadyConsumed, .rowBoundToMessage,
             .cancelled:
            return stateConflict
        case .sizeExceeded: return sizeExceeded
        case .aggregateExceeded: return aggregateExceeded
        case .diskFull: return diskFull
        case .saturated, .leaseUnknown: return saturated
        case .writeFailed, .renameFailed: return writeFailed
        case .readFailed: return readFailed
        case .digestMismatch, .rowChanged: return digestMismatch
        case .nameUnusable, .payloadInvalid, .sourceUnavailable, .grantRevoked:
            return invalidArguments
        case .wrongOwner, .storeUnavailable: return grantMissing
        case .internal: return AttachmentStagingStatus.internal
        }
    }

    public static func code(for outcome: AttachmentStagingService.WriteOutcome) -> Int32 {
        switch outcome {
        case .accepted: return ok
        case .refused(let code): return AttachmentStagingStatus.code(for: code)
        }
    }
}

// MARK: - Read grants (real, bounded, generation-scoped RAM authority)

/// A committed-attachment byte read requires: the exact attachmentID +
/// conversationID pair whose ORIGINAL-row ownership verification just
/// settled in this generation, plus the verified row snapshot (byte count +
/// digest + relative path). No path, no URI: the service re-derives and
/// re-checks containment from the row values. LRU-bounded; a new generation
/// knows no old grant (typed `grantMissing`), and cancel/discard/retire
/// revoke honestly.
public final class AttachmentReadGrantTable: @unchecked Sendable {
    public struct Grant: Sendable {
        public let attachment: AttachmentRef
        public let conversationID: UUID
        public let epoch: UInt64
    }

    public enum Limits {
        public static let maximumLiveGrants = 32
    }

    private let lock = NSLock()
    private var entries: [String: Grant] = [:]
    private var order: [String] = []

    public init() {}

    private static func key(attachmentID: UUID, conversationID: UUID) -> String {
        attachmentID.uuidString + "|" + conversationID.uuidString
    }

    public func issue(attachment: AttachmentRef, conversationID: UUID, epoch: UInt64) {
        let attachmentID = attachment.id
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(attachmentID: attachmentID, conversationID: conversationID)
        if entries[key] == nil {
            order.append(key)
            while order.count > Limits.maximumLiveGrants {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        entries[key] = Grant(attachment: attachment, conversationID: conversationID,
                             epoch: epoch)
    }

    public func lookup(attachmentID: UUID, conversationID: UUID, epoch: UInt64) -> Grant? {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(attachmentID: attachmentID, conversationID: conversationID)
        guard let grant = entries[key], grant.epoch == epoch else { return nil }
        return grant
    }

    @discardableResult
    public func revoke(attachmentID: UUID, conversationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(attachmentID: attachmentID, conversationID: conversationID)
        order.removeAll { $0 == key }
        return entries.removeValue(forKey: key) != nil
    }

    public func retireAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    public var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}

// MARK: - Typed domain outcomes (direct-return truth for in-process binding)

/// Full structured outcome of one attachment command. The mailbox settlement
/// maps these to closed identifier detail (RB1 typed-carrier interim
/// discipline: identifier-only `[String:String]`, page content travels only
/// through the typed reply for Main's future binding adapter). The Kotlin
/// host consumes the WIRE shape; in-process carriers (Main's UI adapter)
/// consume this typed shape — name/MIME never leave as wire detail.
public struct AttachmentCommandOutcome: Sendable {
    public enum Kind: String, Sendable, Equatable {
        case accepted
        case refused
    }
    public let kind: Kind
    public let code: AttachmentStagingCode?
    public let stagingID: String?
    public let handle: String?
    public let attachmentID: String?
    public let state: String?
    public let byteCount: Int?
    public let sha256: String?
    public let rowDigest: String?
    /// Scalar-safe view projection for in-process carriers ONLY (typed page).
    public let recordView: StagedRecordView?

    public init(kind: Kind, code: AttachmentStagingCode? = nil,
                stagingID: String? = nil, handle: String? = nil,
                attachmentID: String? = nil, state: String? = nil,
                byteCount: Int? = nil, sha256: String? = nil,
                rowDigest: String? = nil, recordView: StagedRecordView? = nil) {
        self.kind = kind
        self.code = code
        self.stagingID = stagingID
        self.handle = handle
        self.attachmentID = attachmentID
        self.state = state
        self.byteCount = byteCount
        self.sha256 = sha256
        self.rowDigest = rowDigest
        self.recordView = recordView
    }

    static func accepted(stagingID: String? = nil, handle: String? = nil,
                         attachmentID: String? = nil, state: String? = nil,
                         byteCount: Int? = nil, sha256: String? = nil,
                         rowDigest: String? = nil,
                         recordView: StagedRecordView? = nil) -> AttachmentCommandOutcome {
        AttachmentCommandOutcome(kind: .accepted, stagingID: stagingID, handle: handle,
                                 attachmentID: attachmentID, state: state,
                                 byteCount: byteCount, sha256: sha256,
                                 rowDigest: rowDigest, recordView: recordView)
    }

    static func refused(_ code: AttachmentStagingCode) -> AttachmentCommandOutcome {
        AttachmentCommandOutcome(kind: .refused, code: code)
    }

    /// Closed identifier detail for the mailbox settlement. Keys are a fixed
    /// vocabulary; values are opaque identifiers / decimal scalars / closed
    /// state names — never encoded JSON, never a path, URI, name or MIME.
    var detail: [String: String] {
        var out: [String: String] = ["result": kind.rawValue]
        if let code { out["code"] = code.rawValue }
        if let stagingID { out["stagingID"] = stagingID }
        if let handle { out["stagingHandle"] = handle }
        if let attachmentID { out["attachmentID"] = attachmentID }
        if let state { out["state"] = state }
        if let byteCount { out["byteCount"] = String(byteCount) }
        if let sha256 { out["sha256"] = sha256 }
        if let rowDigest { out["rowDigest"] = rowDigest }
        return out
    }
}

// MARK: - Installed generation

/// Everything the lane binds for ONE accepted generation. Installed by Main's
/// composition AFTER the owned store is ready (`AndroidRuntimeStoreOwner`
/// phase ready) and retired with the generation.
public struct AttachmentStagingDomainComponents: Sendable {
    public let epoch: UInt64
    public let mailbox: FacadeCommandMailbox
    public let effects: FacadeEffectPump
    public let registry: RuntimeDomainRegistry
    public let service: AttachmentStagingService
    public let launchAuthority: AttachmentStagingLaunchAuthority
    public let readGrants: AttachmentReadGrantTable

    public init(epoch: UInt64, mailbox: FacadeCommandMailbox, effects: FacadeEffectPump,
                registry: RuntimeDomainRegistry, service: AttachmentStagingService,
                launchAuthority: AttachmentStagingLaunchAuthority,
                readGrants: AttachmentReadGrantTable) {
        self.epoch = epoch
        self.mailbox = mailbox
        self.effects = effects
        self.registry = registry
        self.service = service
        self.launchAuthority = launchAuthority
        self.readGrants = readGrants
    }
}

// MARK: - Facade (Main binding surface)

public enum AttachmentStagingFacade {

    nonisolated(unsafe) private static var installed: AttachmentStagingDomainComponents?
    nonisolated(unsafe) private static var installedEffectPumpBound = false
    private static let stateLock = NSLock()

    public static var attachmentBinderKeys: [String] {
        RuntimeFacadeAttachmentBridge.attachmentBinderKeys
    }

    /// Registers EXACTLY the seven attachment keys (binder + processors) for
    /// the accepted generation. Returns false (registering nothing) when the
    /// epoch does not match the service identity (typed fail-closed; Main's
    /// composition order is asserted, never guessed).
    @discardableResult
    public static func install(components: AttachmentStagingDomainComponents) -> Bool {
        guard components.epoch == components.service.epoch else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard installed == nil else { return false }   // one install per process lane
        installed = components
        RuntimeFacadeAttachmentBridge.install(components: components)
        return true
    }

    /// Generation retirement: unregister the binder keys, drop processors,
    /// revoke read grants, retire the service (live ingress aborted, RAM
    /// invalidated; durable staged bytes and committed rows untouched). The
    /// mailbox/effect pumps are RB1-owned and drain in their own order.
    public static func retire(epoch: UInt64) {
        stateLock.lock()
        let current = installed
        if current?.epoch == epoch { installed = nil; installedEffectPumpBound = false }
        stateLock.unlock()
        guard let current, current.epoch == epoch else { return }
        RuntimeFacadeAttachmentBridge.uninstall(components: current)
        current.readGrants.retireAll()
        current.service.retire()
    }

    /// Read-only accessor for the staging `_cdecl` layer (never fabricates:
    /// absent generation is a typed `-301`, not a success).
    static var currentInstalled: AttachmentStagingDomainComponents? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return installed
    }

    /// Test-only hard reset (no durable side effects — files/rows are owned
    /// by the lane under test's synthetic root).
    static func uninstallAllForTesting() {
        stateLock.lock()
        let current = installed
        installed = nil
        installedEffectPumpBound = false
        stateLock.unlock()
        if let current {
            RuntimeFacadeAttachmentBridge.uninstall(components: current)
            current.readGrants.retireAll()
            current.service.retire()
        }
    }
}

// MARK: - Bridge handlers / processors

public enum RuntimeFacadeAttachmentBridge {

    // MARK: Handler keys (closed; exactly the seven existing commands)

    static var stageKey: String {
        BridgeV3.handlerKey(scope: .applicationConfiguration, command: "attachment.stage")
    }
    static var stagingReadKey: String {
        BridgeV3.handlerKey(scope: .applicationConfiguration,
                            command: "attachment.staging.read")
    }
    static var stagingCancelKey: String {
        BridgeV3.handlerKey(scope: .applicationConfiguration,
                            command: "attachment.staging.cancel")
    }
    static var stagingDiscardKey: String {
        BridgeV3.handlerKey(scope: .applicationConfiguration,
                            command: "attachment.staging.discard")
    }
    static var commitKey: String {
        BridgeV3.handlerKey(scope: .conversationLifecycle, command: "attachment.commit")
    }
    static var readKey: String {
        BridgeV3.handlerKey(scope: .conversationLifecycle, command: "attachment.read")
    }
    static var cancelKey: String {
        BridgeV3.handlerKey(scope: .conversationLifecycle, command: "attachment.cancel")
    }

    public static var attachmentBinderKeys: [String] {
        [stageKey, stagingReadKey, stagingCancelKey, stagingDiscardKey,
         commitKey, readKey, cancelKey]
    }

    // MARK: Install / uninstall

    static func install(components: AttachmentStagingDomainComponents) {
        let binder = RuntimeCommandBinder.shared
        let epoch = components.epoch
        binder.register(stageKey, commandSubmitHandler(scope: .applicationConfiguration,
                                                       command: "attachment.stage",
                                                       configurationScope: "attachmentStaging",
                                                       epoch: epoch))
        binder.register(stagingReadKey, commandSubmitHandler(
            scope: .applicationConfiguration,
            command: "attachment.staging.read",
            configurationScope: "attachmentStaging", epoch: epoch))
        binder.register(stagingCancelKey, commandSubmitHandler(
            scope: .applicationConfiguration,
            command: "attachment.staging.cancel",
            configurationScope: "attachmentStaging", epoch: epoch))
        binder.register(stagingDiscardKey, commandSubmitHandler(
            scope: .applicationConfiguration,
            command: "attachment.staging.discard",
            configurationScope: "attachmentStaging", epoch: epoch))
        binder.register(commitKey, commandSubmitHandler(scope: .conversationLifecycle,
                                                        command: "attachment.commit",
                                                        configurationScope: nil,
                                                        epoch: epoch))
        binder.register(readKey, commandSubmitHandler(scope: .conversationLifecycle,
                                                      command: "attachment.read",
                                                      configurationScope: nil,
                                                      epoch: epoch))
        binder.register(cancelKey, commandSubmitHandler(scope: .conversationLifecycle,
                                                        command: "attachment.cancel",
                                                        configurationScope: nil,
                                                        epoch: epoch))
        let registry = components.registry
        registry.register(handlerKey: stageKey,
                          processor: RuntimeAsyncProcessor { job in
            await processStage(job, components: components)
        })
        registry.register(handlerKey: stagingReadKey,
                          processor: RuntimeAsyncProcessor { job in
            await processStagingRead(job, components: components)
        })
        registry.register(handlerKey: stagingCancelKey,
                          processor: RuntimeAsyncProcessor { job in
            await processStagingCancel(job, components: components)
        })
        registry.register(handlerKey: stagingDiscardKey,
                          processor: RuntimeAsyncProcessor { job in
            await processStagingDiscard(job, components: components)
        })
        registry.register(handlerKey: commitKey,
                          processor: RuntimeAsyncProcessor { job in
            await processCommit(job, components: components)
        })
        registry.register(handlerKey: readKey,
                          processor: RuntimeAsyncProcessor { job in
            await processRead(job, components: components)
        })
        registry.register(handlerKey: cancelKey,
                          processor: RuntimeAsyncProcessor { job in
            await processCancel(job, components: components)
        })
    }

    static func uninstall(components: AttachmentStagingDomainComponents) {
        let binder = RuntimeCommandBinder.shared
        for key in attachmentBinderKeys { binder.unregister(key) }
        for key in attachmentBinderKeys { components.registry.unregister(handlerKey: key) }
    }

    // MARK: Synchronous binder handler (receipt + mailbox only)

    private static func commandSubmitHandler(scope: BridgeV3.Scope, command: String,
                                             configurationScope: String?,
                                             epoch: UInt64)
        -> RuntimeCommandBinder.Handler {
        let binderKey = BridgeV3.handlerKey(scope: scope, command: command)
        return { data in
            // BridgeV3 already validated the envelope before dispatch; the
            // handler re-reads only the stable identity fields and never
            // trusts a relabelled scope/command here.
            guard let envelope = parseObject(data),
                  envelope["scope"] as? String == scope.rawValue,
                  envelope["command"] as? String == command,
                  scope != .applicationConfiguration
                    || envelope["configurationScope"] as? String == configurationScope,
                  let correlation = envelope["correlationID"] as? String,
                  !correlation.isEmpty else {
                return errorJSON(error: "invalidEnvelope", reason: "malformedAfterValidation")
            }
            guard let installed = AttachmentStagingFacade.currentInstalled,
                  installed.epoch == epoch else {
                return errorJSON(error: "runtimeUnavailable", reason: "stagingNotInstalled")
            }
            if installed.mailbox.isAdmissionFenced {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.alreadyDraining.rawValue)
            }
            if let existing = installed.mailbox.liveReceipt(correlationID: correlation) {
                return receiptJSON(correlation: correlation, receipt: existing)
            }
            guard let receipt = installed.effects.register(correlationID: correlation) else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.receiptSaturated.rawValue)
            }
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: binderKey,
                command: command,
                scope: scope,
                configurationScope: configurationScope,
                receipt: receipt,
                envelope: data)
            switch installed.mailbox.submit(job) {
            case .queued:
                return receiptJSON(correlation: correlation, receipt: receipt)
            case .duplicate(let existing):
                return receiptJSON(correlation: correlation, receipt: existing)
            case .rejected:
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.mailboxSaturated.rawValue)
            }
        }
    }

    // MARK: - Processors (async; ALL file/DB effects live here)

    /// `attachment.stage`: publish one FINISHED native ingress. The command
    /// carries only the opaque ingress receipt; the real bytes were already
    /// streamed by the trusted host under a live route. Arrival of a staged
    /// file NEVER sends a message or starts a run.
    static func processStage(_ job: RuntimeCommandEnvelopeJob,
                             components: AttachmentStagingDomainComponents) async
        -> RuntimeCommandResult {
        guard let outcome = await typedStage(job: job, components: components) else {
            return settle(.refused(.payloadInvalid))
        }
        return settle(outcome)
    }

    static func typedStage(job: RuntimeCommandEnvelopeJob,
                           components: AttachmentStagingDomainComponents) async
        -> AttachmentCommandOutcome? {
        guard let payload = payloadObject(from: job.envelope),
              case .publish(let ingressReceipt)? =
                AttachmentStagingPayload.decodeStage(payload) else { return nil }
        switch components.service.publish(ingressReceipt: ingressReceipt) {
        case .published(let view):
            return .accepted(stagingID: view.stagingID, handle: view.handle,
                             state: view.state, byteCount: view.byteCount,
                             sha256: view.sha256, recordView: view)
        case .refused(let code):
            return .refused(code)
        }
    }

    /// `attachment.staging.read`: metadata/progress for a staged record.
    /// Bytes are NOT here — they use `floe_staging_read` by the host only.
    static func processStagingRead(_ job: RuntimeCommandEnvelopeJob,
                                   components: AttachmentStagingDomainComponents) async
        -> RuntimeCommandResult {
        guard let payload = payloadObject(from: job.envelope),
              case .snapshot(let stagingID)? =
                AttachmentStagingPayload.decodeStagingRead(payload),
              let view = components.service.snapshot(stagingID: stagingID) else {
            return settle(.refused(.handleUnknown))
        }
        return settle(.accepted(stagingID: view.stagingID, handle: view.handle,
                                state: view.state, byteCount: view.byteCount,
                                sha256: view.sha256, recordView: view))
    }

    /// `attachment.staging.cancel`: cancel the LIVE ingress for a staging
    /// identity (never touches another route, never a published file).
    static func processStagingCancel(_ job: RuntimeCommandEnvelopeJob,
                                     components: AttachmentStagingDomainComponents) async
        -> RuntimeCommandResult {
        guard let payload = payloadObject(from: job.envelope),
              case .ingress(let stagingID)? =
                AttachmentStagingPayload.decodeStagingCancel(payload) else {
            return settle(.refused(.payloadInvalid))
        }
        if let refusal = components.service.cancelIngress(stagingID: stagingID) {
            return settle(.refused(refusal))
        }
        return settle(.accepted(stagingID: stagingID,
                                state: StagedState.cancelled.rawValue))
    }

    /// `attachment.staging.discard`: remove staged bytes the user dropped.
    /// Refused for consumed/committed/leased records — committed history is
    /// RB3 lifecycle territory, never a discard side effect.
    static func processStagingDiscard(_ job: RuntimeCommandEnvelopeJob,
                                      components: AttachmentStagingDomainComponents) async
        -> RuntimeCommandResult {
        guard let payload = payloadObject(from: job.envelope),
              case .handle(let handle)? =
                AttachmentStagingPayload.decodeStagingDiscard(payload) else {
            return settle(.refused(.payloadInvalid))
        }
        if let refusal = components.service.discard(handle: handle) {
            return settle(.refused(refusal))
        }
        return settle(.accepted(handle: handle, state: StagedState.discarded.rawValue))
    }

    /// `attachment.commit` (taskID + conversation-row CAS): persist exact
    /// owned staged handles as conversation-level rows through the ORIGINAL
    /// writer. Arrival never auto-sends. Per-handle truths accumulate; a
    /// partial success is reported per handle, never silently as "all".
    static func processCommit(_ job: RuntimeCommandEnvelopeJob,
                              components: AttachmentStagingDomainComponents) async
        -> RuntimeCommandResult {
        guard let envelope = parseObject(job.envelope),
              let owner = envelope["owner"] as? [String: Any],
              let taskRaw = owner["taskID"] as? String,
              let conversationID = UUID(uuidString: taskRaw),
              let revision = envelope["revision"] as? [String: Any],
              let resourceID = revision["resourceID"] as? String,
              let version = revision["version"] as? String,
              !version.isEmpty,
              ConversationRowRevision.matches(revisionResourceID: resourceID,
                                              conversationID: conversationID),
              let payload = payloadObject(from: job.envelope),
              let handles = AttachmentStagingPayload.decodeCommitHandles(payload) else {
            return settle(.refused(.payloadInvalid))
        }
        var committed: [String] = []
        var refused: [(String, AttachmentStagingCode)] = []
        for handle in handles {
            let outcome = await components.service.commitStagedHandle(
                handle, conversationID: conversationID, expectedConversationDigest: version)
            switch outcome {
            case .success(let view):
                committed.append(view.stagingID)
            case .failure(let error):
                refused.append((handle, error.code))
            }
        }
        if committed.isEmpty, let (_, code) = refused.first {
            return settle(.refused(code))
        }
        var detail: [String: String] = [
            "result": refused.isEmpty ? "accepted" : "partial",
            "committedStagingIDs": committed.joined(separator: ","),
            "committedCount": String(committed.count),
        ]
        if !refused.isEmpty {
            detail["refusedCodes"] = refused.map { $0.1.rawValue }
                .joined(separator: ",")
        }
        return RuntimeCommandResult(kind: .accepted, detail: detail)
    }

    /// `attachment.read`: ownership-verify against the ORIGINAL rows, mint a
    /// read grant for the byte channel, settle identifier-only metadata.
    static func processRead(_ job: RuntimeCommandEnvelopeJob,
                            components: AttachmentStagingDomainComponents) async
        -> RuntimeCommandResult {
        guard let envelope = parseObject(job.envelope),
              let owner = envelope["owner"] as? [String: Any],
              let taskRaw = owner["taskID"] as? String,
              let conversationID = UUID(uuidString: taskRaw),
              let payload = payloadObject(from: job.envelope),
              case .committed(let attachmentID)? =
                AttachmentStagingPayload.decodeRead(payload) else {
            return settle(.refused(.payloadInvalid))
        }
        guard let verified = await components.service.verifyReadableAttachment(
            attachmentID: attachmentID, conversationID: conversationID) else {
            return settle(.refused(.wrongOwner))
        }
        components.readGrants.issue(attachment: verified.row,
                                    conversationID: conversationID,
                                    epoch: components.epoch)
        return settle(.accepted(attachmentID: verified.row.id.uuidString,
                                state: "readable",
                                byteCount: verified.row.byteCount,
                                sha256: verified.row.sha256,
                                rowDigest: verified.rowDigest))
    }

    /// `attachment.cancel` (taskID + attachment-row digest CAS): cancel a
    /// committed-but-pre-run row. Post-DB-commit cancellation reports the
    /// truth (`rowChanged`/`rowBoundToMessage`/absent), never a "rollback".
    static func processCancel(_ job: RuntimeCommandEnvelopeJob,
                              components: AttachmentStagingDomainComponents) async
        -> RuntimeCommandResult {
        guard let envelope = parseObject(job.envelope),
              let owner = envelope["owner"] as? [String: Any],
              let taskRaw = owner["taskID"] as? String,
              let conversationID = UUID(uuidString: taskRaw),
              let revision = envelope["revision"] as? [String: Any],
              let resourceID = revision["resourceID"] as? String,
              let version = revision["version"] as? String,
              !version.isEmpty,
              let payload = payloadObject(from: job.envelope),
              let attachmentID = AttachmentStagingPayload.attachmentIDOnly(payload),
              let attachmentUUID = UUID(uuidString: attachmentID),
              AttachmentRowRevision.matches(revisionResourceID: resourceID,
                                            attachmentID: attachmentUUID)
        else {
            return settle(.refused(.payloadInvalid))
        }
        let outcome = await components.service.cancelCommittedRow(
            attachmentID: attachmentID, conversationID: conversationID,
            expectedRowDigest: version)
        switch outcome {
        case .success:
            if let id = UUID(uuidString: attachmentID) {
                components.readGrants.revoke(attachmentID: id,
                                             conversationID: conversationID)
            }
            return settle(.accepted(attachmentID: attachmentID,
                                    state: "cancelledRow"))
        case .failure(let error):
            return settle(.refused(error.code))
        }
    }

    // MARK: - Settlement mapping

    /// Domain refusals settle as a COMPLETED mailbox operation carrying the
    /// honest refusal classification (`result=refused` + closed code); the
    /// frozen RuntimeFacadeCode enum has no attachment vocabulary and this
    /// lane never invents a wire label. The exact minimal proposal for Main
    /// is recorded in the lane handoff (typed carrier slot + the shared
    /// RB1 qualifier decision). Lifecycle-level faults still map to the
    /// closest frozen code for pump-level diagnostics.
    static func settle(_ outcome: AttachmentCommandOutcome) -> RuntimeCommandResult {
        if outcome.kind == .accepted {
            return RuntimeCommandResult(kind: .accepted, detail: outcome.detail)
        }
        switch outcome.code {
        case .some(.notInstalled):
            return RuntimeCommandResult(kind: .rejected, code: .notInstalled,
                                        detail: outcome.detail)
        case .some(.generationFenced):
            return RuntimeCommandResult(kind: .rejected, code: .alreadyDraining,
                                        detail: outcome.detail)
        case .some(.storeUnavailable):
            return RuntimeCommandResult(kind: .failed, code: .storeOpenFailed,
                                        detail: outcome.detail)
        case .some(.saturated):
            return RuntimeCommandResult(kind: .rejected, code: .receiptSaturated,
                                        detail: outcome.detail)
        default:
            return RuntimeCommandResult(kind: .accepted, detail: outcome.detail)
        }
    }

    // MARK: - Envelope helpers (local copies; RB1 helpers are private)

    static func parseObject(_ data: Data) -> [String: Any]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }

    static func payloadObject(from data: Data) -> [String: Any]? {
        guard let envelope = parseObject(data) else { return nil }
        guard let payload = envelope["payload"] else { return [:] }
        return payload as? [String: Any]
    }

    static func receiptJSON(correlation: String, receipt: String) -> Data {
        finalize([
            "ok": true,
            "schema": BridgeV3.commandSchema,
            "correlationID": correlation,
            "operationReceiptID": receipt,
            "queued": true,
        ]) ?? errorJSON(error: "runtimeUnavailable", reason: "frameBudgetExceeded")
    }

    static func errorJSON(error: String, reason: String) -> Data {
        finalize(["ok": false, "schema": BridgeV3.commandSchema,
                  "error": error, "reason": reason])
            ?? Data("{\"ok\":false,\"error\":\"runtimeUnavailable\"}".utf8)
    }

    static func finalize(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= BridgeV3.maximumBytes else { return nil }
        return data
    }
}

// MARK: - Staging JNI `_cdecl` surface (trusted platform host only)

/// Swift side of the narrow staging ABI. Every entry point validates bounded
/// ASCII inputs, calls the lock-guarded service directly (short critical
/// sections, no await), and returns typed statuses. The C TU
/// (floe_attachment_staging_jni.cpp) owns all JNI marshaling; Swift never
/// sees JNIEnv or jbyteArray. Registration authority is structural: model
/// envelopes CANNOT reach these symbols — only compiled host code can.

private func stagingReadCString(_ pointer: UnsafePointer<CChar>?,
                                limit: Int) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit)
    guard length > 0, length < limit else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length),
                  as: UTF8.self)
}

private func stagingOptionalCString(_ pointer: UnsafePointer<CChar>?,
                                    limit: Int) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit)
    guard length > 0, length < limit else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length),
                  as: UTF8.self)
}

private func stagingCopyCString(_ value: String, buffer: UnsafeMutablePointer<CChar>?,
                                capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else {
        return value.isEmpty ? AttachmentStagingStatus.ok : AttachmentStagingStatus.invalidArguments
    }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return AttachmentStagingStatus.bufferTooSmall }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return AttachmentStagingStatus.ok
}

private func stagingInstalled(_ body: (AttachmentStagingDomainComponents) -> Int32) -> Int32 {
    guard let components = AttachmentStagingFacade.currentInstalled else {
        return AttachmentStagingStatus.notInstalled
    }
    return body(components)
}

@_cdecl("floe_staging_route_open")
public func floeStagingRouteOpen(_ conversationHex: UnsafePointer<CChar>?,
                                 _ incarnation: UInt64,
                                 _ draftRevision: UInt64,
                                 _ isTemporary: Int32,
                                 _ outReceipt: UnsafeMutablePointer<CChar>?,
                                 _ outCap: Int32) -> Int32 {
    guard incarnation > 0 else { return AttachmentStagingStatus.invalidArguments }
    if isTemporary != 0 { return AttachmentStagingStatus.routeTemporary }
    var conversationID: UUID?
    if let hex = stagingOptionalCString(conversationHex, limit: 40) {
        guard let parsed = UUID(uuidString: hex) else {
            return AttachmentStagingStatus.invalidArguments
        }
        conversationID = parsed
    }
    return stagingInstalled { components in
        guard let route = components.service.registerRoute(ComposeRouteDescriptor(
            conversationID: conversationID, incarnation: incarnation,
            draftRevision: draftRevision, isTemporarySession: false)) else {
            return AttachmentStagingStatus.saturated
        }
        let written = stagingCopyCString(route.receipt, buffer: outReceipt, capacity: outCap)
        return written < 0 ? written : AttachmentStagingStatus.ok
    }
}

@_cdecl("floe_staging_route_close")
public func floeStagingRouteClose(_ routeReceipt: UnsafePointer<CChar>?) -> Int32 {
    guard let receipt = stagingReadCString(routeReceipt, limit: 64) else {
        return AttachmentStagingStatus.invalidArguments
    }
    return stagingInstalled { components in
        components.service.closeRoute(receipt: receipt)
        return AttachmentStagingStatus.ok
    }
}

@_cdecl("floe_staging_begin")
public func floeStagingBegin(_ routeReceipt: UnsafePointer<CChar>?,
                             _ reusingStagingID: UnsafePointer<CChar>?,
                             _ outIngress: UnsafeMutablePointer<CChar>?,
                             _ ingressCap: Int32,
                             _ outStagingID: UnsafeMutablePointer<CChar>?,
                             _ stagingCap: Int32) -> Int32 {
    guard let receipt = stagingReadCString(routeReceipt, limit: 64) else {
        return AttachmentStagingStatus.invalidArguments
    }
    let reusing = stagingOptionalCString(reusingStagingID, limit: 40)
    return stagingInstalled { components in
        switch components.service.beginIngress(routeReceipt: receipt,
                                               reusingStagingID: reusing) {
        case .refused(let code):
            return AttachmentStagingStatus.code(for: code)
        case .opened(let ingressReceipt, let stagingID):
            let first = stagingCopyCString(ingressReceipt, buffer: outIngress,
                                           capacity: ingressCap)
            if first < 0 { return first }
            let second = stagingCopyCString(stagingID, buffer: outStagingID,
                                            capacity: stagingCap)
            return second < 0 ? second : AttachmentStagingStatus.ok
        }
    }
}

@_cdecl("floe_staging_write")
public func floeStagingWrite(_ ingressReceipt: UnsafePointer<CChar>?,
                             _ bytes: UnsafePointer<UInt8>?,
                             _ length: Int32) -> Int32 {
    guard let receipt = stagingReadCString(ingressReceipt, limit: 64),
          let bytes, length >= 0,
          length <= Int32(AttachmentStagingLimits.maximumChunkBytes) else {
        return AttachmentStagingStatus.invalidArguments
    }
    return stagingInstalled { components in
        let chunk = Data(bytes: bytes, count: Int(length))
        let outcome = components.service.writeIngress(ingressReceipt: receipt, chunk: chunk)
        return AttachmentStagingStatus.code(for: outcome)
    }
}

@_cdecl("floe_staging_end")
public func floeStagingEnd(_ ingressReceipt: UnsafePointer<CChar>?,
                           _ displayNameHint: UnsafePointer<CChar>?,
                           _ mimeTypeHint: UnsafePointer<CChar>?,
                           _ kindHint: UnsafePointer<CChar>?) -> Int32 {
    guard let receipt = stagingReadCString(ingressReceipt, limit: 64) else {
        return AttachmentStagingStatus.invalidArguments
    }
    let name = stagingOptionalCString(displayNameHint, limit: 1024)
    let mime = stagingOptionalCString(mimeTypeHint, limit: 256)
    let kind = stagingOptionalCString(kindHint, limit: 16)
    return stagingInstalled { components in
        if let refusal = components.service.endIngress(ingressReceipt: receipt,
                                                       displayNameHint: name,
                                                       mimeHint: mime,
                                                       kindHint: kind) {
            return AttachmentStagingStatus.code(for: refusal)
        }
        return AttachmentStagingStatus.ok
    }
}

@_cdecl("floe_staging_abort")
public func floeStagingAbort(_ ingressReceipt: UnsafePointer<CChar>?) -> Int32 {
    guard let receipt = stagingReadCString(ingressReceipt, limit: 64) else {
        return AttachmentStagingStatus.invalidArguments
    }
    return stagingInstalled { components in
        if let refusal = components.service.abortIngress(ingressReceipt: receipt) {
            return AttachmentStagingStatus.code(for: refusal)
        }
        return AttachmentStagingStatus.ok
    }
}

@_cdecl("floe_staging_progress")
public func floeStagingProgress(_ ingressReceipt: UnsafePointer<CChar>?,
                                _ outBytes: UnsafeMutablePointer<Int64>?,
                                _ outFinished: UnsafeMutablePointer<Int32>?,
                                _ outCancelled: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let receipt = stagingReadCString(ingressReceipt, limit: 64),
          let outBytes, let outFinished, let outCancelled else {
        return AttachmentStagingStatus.invalidArguments
    }
    return stagingInstalled { components in
        guard let progress = components.service.ingressProgress(ingressReceipt: receipt) else {
            return AttachmentStagingStatus.ingressUnknown
        }
        outBytes.pointee = Int64(progress.bytes)
        outFinished.pointee = progress.finished ? 1 : 0
        outCancelled.pointee = progress.cancelled ? 1 : 0
        return AttachmentStagingStatus.ok
    }
}

@_cdecl("floe_staging_read")
public func floeStagingRead(_ stagingHandle: UnsafePointer<CChar>?,
                            _ offset: Int64,
                            _ outBuffer: UnsafeMutablePointer<UInt8>?,
                            _ capacity: Int32) -> Int32 {
    guard let handle = stagingReadCString(stagingHandle, limit: 64),
          let outBuffer, capacity > 0,
          capacity <= Int32(AttachmentStagingLimits.maximumChunkBytes),
          offset >= 0 else {
        return AttachmentStagingStatus.invalidArguments
    }
    return stagingInstalled { components in
        let data = components.service.readStaged(handle: handle, offset: offset,
                                                 maxBytes: Int(capacity))
        guard let data else {
            return components.service.snapshot(handle: handle) == nil
                ? AttachmentStagingStatus.handleUnknown
                : AttachmentStagingStatus.readFailed
        }
        if data.isEmpty { return AttachmentStagingStatus.ok }  // EOF: zero bytes
        data.withUnsafeBytes { raw in
            outBuffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!,
                             count: data.count)
        }
        return Int32(data.count)
    }
}

/// Committed-attachment byte read. Requires a live READ GRANT issued by the
/// `attachment.read` processor for the exact attachmentID + conversationID
/// pair in THIS generation (ownership was verified against the ORIGINAL
/// rows); absent/stale grants are typed `-314`, never a partial read and
/// never a path the caller controls.
@_cdecl("floe_attachment_read")
public func floeAttachmentRead(_ attachmentHex: UnsafePointer<CChar>?,
                               _ conversationHex: UnsafePointer<CChar>?,
                               _ offset: Int64,
                               _ outBuffer: UnsafeMutablePointer<UInt8>?,
                               _ capacity: Int32) -> Int32 {
    guard let attachmentRaw = stagingReadCString(attachmentHex, limit: 40),
          let conversationRaw = stagingReadCString(conversationHex, limit: 40),
          let attachmentID = UUID(uuidString: attachmentRaw),
          let conversationID = UUID(uuidString: conversationRaw),
          let outBuffer, capacity > 0,
          capacity <= Int32(AttachmentStagingLimits.maximumChunkBytes),
          offset >= 0 else {
        return AttachmentStagingStatus.invalidArguments
    }
    return stagingInstalled { components in
        guard let grant = components.readGrants.lookup(attachmentID: attachmentID,
                                                       conversationID: conversationID,
                                                       epoch: components.epoch) else {
            return AttachmentStagingStatus.grantMissing
        }
        let data = components.service.readCommittedBytes(attachment: grant.attachment,
                                                         offset: offset,
                                                         maxBytes: Int(capacity))
        guard let data else { return AttachmentStagingStatus.readFailed }
        if data.isEmpty { return AttachmentStagingStatus.ok }
        data.withUnsafeBytes { raw in
            outBuffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!,
                             count: data.count)
        }
        return Int32(data.count)
    }
}

/// Lock-only bounded staging counters (no paths, names or URIs — counters
/// and identifiers only). Null-safe by contract: never throws, never
/// blocks on IO.
@_cdecl("floe_staging_status")
public func floeStagingStatus(_ outBuffer: UnsafeMutablePointer<CChar>?,
                              _ capacity: Int32) -> Int32 {
    guard let components = AttachmentStagingFacade.currentInstalled else {
        let absent = "{\"installed\":false}"
        let written = stagingCopyCString(absent, buffer: outBuffer, capacity: capacity)
        return written < 0 ? written : AttachmentStagingStatus.notInstalled
    }
    var object: [String: Any] = [
        "installed": true,
        "epoch": components.epoch,
        "liveGrants": components.readGrants.liveCount,
    ]
    var counters: [String: Int] = [:]
    for (key, value) in components.service.statusCounters() { counters[key] = value }
    object["counters"] = counters
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let json = String(data: data, encoding: .utf8) else {
        return AttachmentStagingStatus.internal
    }
    let written = stagingCopyCString(json, buffer: outBuffer, capacity: capacity)
    return written < 0 ? written : AttachmentStagingStatus.ok
}
