// SPDX-License-Identifier: MPL-2.0
//
// G02 trusted-host DRAFT probe/discovery seam (unsaved or changed provider
// drafts), required by MAIN_CONFIG_DRAFT_PROBE_PARITY_DECISION_20261020.
//
// The frozen public `config.provider.probe` grammar accepts ONLY a persisted
// `{providerID}`; stuffing endpoint/protocol/key into it is refused, and
// testing the OLD stored profile while implying the draft was verified is
// forbidden. This seam is the missing trusted-host-only path:
//
//  * NOT a V3 command/tool: no command name, no payload vocabulary, no
//    permission. Exported to the App process only (JNI).
//  * Authority is the SAME accepted native Root epoch + ONE live provider
//    editor incarnation minted by `floe_host_route_open`; the caller passes
//    its own `rt:v1:` handle and the registry re-validates it under the same
//    lock the Root retirement fence takes. No model/imported JSON can mint a
//    route, and a stale/foreign route is refused without any dispatch.
//  * Input is the EXACT closed `ProviderSaveCandidate` the editor would
//    commit (frozen from RAM at the human editor action) + the bounded
//    ephemeral credential typed in that same editor session. The candidate is
//    mapped through the ORIGINAL draft builder and dispatched through the
//    ORIGINAL adapter under the SAME transport admission gate as the saved
//    probe. NOTHING is persisted: no provider row, no model row, no vault
//    intent, no credential-store write.
//  * Lifecycle: one bounded in-flight probe per provider, owner-cancellable
//    (`floe_host_draft_probe_cancel`) and swept by editor close / Root
//    retirement, which CANCEL the owned adapter work and retire its slots
//    (late polls answer typed routeUnavailable; no late callback can surface
//    as a current editor result because the App fences by identity/epoch and
//    the native slot is gone).
//  * Results are identifier-only typed outcomes (the same
//    `ConfigProbeOutcome` JSON the saved probe produces); the entered key is
//    never echoed, and errors are redacted by the ORIGINAL SecretRedactor in
//    the dispatch path.
import Foundation
import FloeCore

public enum G02HostDraftProbeStatus {
    public static let ok: Int32 = 0
    /// Non-terminal poll: the owned probe/discovery is still running.
    public static let pending: Int32 = 2
    public static let invalidArgument: Int32 = -105
    public static let invalidCandidate: Int32 = -110
    public static let secretTooLarge: Int32 = -111
    public static let saturated: Int32 = -112
    public static let candidateTooLarge: Int32 = -116
    public static let routeUnavailable: Int32 = -117
    public static let routeAssertionMismatch: Int32 = -118
    /// Result buffer smaller than the settled payload; `outLength` carries
    /// the exact required size so the caller can retry once.
    public static let bufferTooSmall: Int32 = -121
    /// Canonical `dp:v1:` handle capacity including the NUL terminator.
    public static let handleCapacity: Int32 = 40
}

public enum G02HostDraftProbeError: Error, Equatable {
    case invalidArgument
    case invalidCandidate
    case secretTooLarge
    case candidateTooLarge
    case saturated
    case routeUnavailable
    case routeAssertionMismatch
}

/// One trusted-host draft probe slot. The payload is the settled JSON
/// (success = the exact `ConfigProbeOutcome` object; failure = a typed
/// `{errorCode,reason}` object; cancellation = `{status:"cancelled"}`).
final class G02HostDraftProbeRegistry: @unchecked Sendable {
    static let shared = G02HostDraftProbeRegistry()

    private struct Slot {
        let routeToken: String
        let providerID: UUID
        /// The REAL accepted-Root/epoch owned-work lease attached BEFORE the
        /// adapter dispatch and released only when the awaited adapter call
        /// has TRULY settled — even after the editor route closed. RootStop
        /// observes a nonzero registry count, so cancellation/slot removal
        /// alone can never look drained while the adapter still runs.
        let lease: ConfigOwnedWorkLease
        var abandoned = false
        var state: State
    }

    private enum State {
        case running(Task<Void, Never>)
        case settled(Data)
    }

    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    /// Insertion order for bounded settled-slot eviction (same route).
    private var order: [String] = []

    /// Live in-flight capacity (a provider editor probes one target at a
    /// time; the bound keeps abandoned pollers from accumulating work).
    static let maximumLiveProbes = 4
    static let maximumSettledSlots = 8
    static let maximumCandidateBytes = 16_384
    static let maximumSecretBytes = 65_536

    /// The reviewed shared owned-work lifecycle (RB1 registry + the accepted
    /// composition epoch provider). NO parallel owner system: the same
    /// RuntimeOwnedWorkRegistry that save/delete/retirement use gates Root
    /// quiescence for draft-probe adapter work. Kind `vaultMaintenance` is
    /// the reviewed kind for awaited gateway/credential-bound network
    /// operations on the configuration lane (the saved probe runs inside the
    /// mailbox operation drain; the trusted host seam has no mailbox job, so
    /// it attaches this same registry directly).
    private var lifecycle: ConfigOwnedWorkLifecycle {
        if let override = Self.lifecycleForTesting { return override }
        return ConfigOwnedWorkLifecycle(epochProvider: G02CompositionEpochProvider())
    }

    /// Test-only facade resolution override (never set by a production or
    /// wire path; component tests have no installed bootstrap generation).
    nonisolated(unsafe) static var facadeProviderForTesting:
        (@Sendable (UInt64) -> ModelConfigurationFacade?)?

    /// Test-only lifecycle binding (component fixtures attach against a
    /// scripted registry/epoch; production never sets this).
    nonisolated(unsafe) static var lifecycleForTesting: ConfigOwnedWorkLifecycle?

    private func facade(forEpoch epoch: UInt64) -> ModelConfigurationFacade? {
        if let override = Self.facadeProviderForTesting {
            return override(epoch)
        }
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { return nil }
        return installed.modelConfigurationFacade
    }

    /// Freeze + dispatch ONE draft probe. Throws a typed refusal before any
    /// adapter work when the route/candidate/secret/capacity is not valid.
    func submit(candidateJSON: Data, secret: Data?, routeAssertion: String) throws -> String {
        guard !candidateJSON.isEmpty else { throw G02HostDraftProbeError.invalidCandidate }
        guard candidateJSON.count <= Self.maximumCandidateBytes else {
            throw G02HostDraftProbeError.candidateTooLarge
        }
        if let secret, secret.count > Self.maximumSecretBytes {
            throw G02HostDraftProbeError.secretTooLarge
        }
        guard G02HostRouteContextProvider.isCanonicalRouteToken(routeAssertion) else {
            throw G02HostDraftProbeError.invalidArgument
        }
        // Authority first: the SAME live provider route binding the secure
        // ingress uses (accepted epoch + live editor incarnation).
        guard let binding = G02HostSecureIngress.registry.assertLiveProviderRoute(
            token: routeAssertion) else {
            throw G02HostDraftProbeError.routeUnavailable
        }
        guard let facade = facade(forEpoch: binding.rootEpoch) else {
            throw G02HostDraftProbeError.routeUnavailable
        }
        // Provider identity is a parse-only projection; the facade re-parses
        // the same closed candidate (it never trusts this value for storage).
        guard let providerID = Self.candidateProviderID(candidateJSON) else {
            throw G02HostDraftProbeError.invalidCandidate
        }
        let handle = Self.makeHandle()
        let secretInput = secret
        // Attach the REAL owned-work lease BEFORE any adapter dispatch.
        // A retired/fenced/saturated lifecycle refuses typed and NOTHING
        // was dispatched yet (fail-closed, no invented success, no detached
        // network).
        let lease: ConfigOwnedWorkLease
        switch lifecycle.begin(kind: .vaultMaintenance, ownerID: handle) {
        case .failure(let rejection):
            switch rejection {
            case .invalidOwnerIdentity:
                throw G02HostDraftProbeError.invalidArgument
            case .noAdmittedEpoch, .rejected:
                // noAdmittedEpoch / phase-fenced / capacity rejections all
                // mean "this Root cannot own the work": fail closed.
                throw G02HostDraftProbeError.routeUnavailable
            }
        case .success(let attached):
            lease = attached
        }
        // Capacity check AND slot insertion happen under ONE lock, and the
        // slot exists before the task can possibly settle (the settle path
        // takes this same lock), so a very fast adapter can never lose its
        // terminal payload. Retired-but-unsettled slots keep counting: an
        // adapter still running is still live work.
        lock.lock()
        let liveCount = slots.values.reduce(into: 0) { count, slot in
            if case .running = slot.state { count += 1 }
        }
        guard liveCount < Self.maximumLiveProbes else {
            lock.unlock()
            lifecycle.settle(lease)
            throw G02HostDraftProbeError.saturated
        }
        let task = Task<Void, Never> { [weak self] in
            // The task owns its own copy and zeroes it on every exit.
            var ownedSecret = secretInput ?? Data()
            defer {
                if ownedSecret.count > 0 {
                    ownedSecret.resetBytes(in: 0..<ownedSecret.count)
                }
                ownedSecret = Data()
            }
            // Admission-to-retirement race closure: re-check the route AND
            // this slot under the registry lock immediately BEFORE the
            // network. A route closed/retired in the meantime never reaches
            // the adapter; the lease still settles honestly at task end.
            if self?.isDispatchLive(handle: handle, routeToken: routeAssertion) == false {
                self?.settleAndRelease(handle: handle, lease: lease,
                                       payload: Self.cancelledPayload())
                return
            }
            let payload: Data
            do {
                let outcome = try await facade.probeDraftCandidate(candidateJSON,
                                                                   secret: ownedSecret)
                payload = Self.settlePayload(outcome)
            } catch is CancellationError {
                payload = Self.cancelledPayload()
            } catch let error as ConfigDomainError {
                payload = Self.failurePayload(code: error.code.rawValue,
                                              reason: error.reason)
            } catch {
                payload = Self.failurePayload(code: "runtimeUnavailable",
                                              reason: "probeRejected")
            }
            self?.settleAndRelease(handle: handle, lease: lease, payload: payload)
        }
        slots[handle] = Slot(routeToken: routeAssertion,
                             providerID: providerID,
                             lease: lease,
                             state: .running(task))
        order.append(handle)
        evictSettledLocked(routeToken: routeAssertion)
        lock.unlock()
        return handle
    }

    /// Non-blocking poll. Returns `.pending` or `.ok` with the settled JSON.
    func result(handle: String, routeAssertion: String) throws -> (Int32, Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[handle], slot.routeToken == routeAssertion else {
            throw G02HostDraftProbeError.routeUnavailable
        }
        switch slot.state {
        case .running:
            return (G02HostDraftProbeStatus.pending, nil)
        case .settled(let payload):
            // A retired route never leaks its late result to a poller: the
            // slot is gone at settle; this branch is exact-route only.
            return (G02HostDraftProbeStatus.ok, payload)
        }
    }

    /// Owner cancel: cancels the REAL adapter work (Task cancellation reaches
    /// the original transport call) and keeps the slot until its own terminal
    /// settles; a settled slot is an idempotent no-op.
    @discardableResult
    func cancel(handle: String, routeAssertion: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = slots[handle], slot.routeToken == routeAssertion else {
            return false
        }
        if case .running(let task) = slot.state {
            task.cancel()
        }
        return true
    }

    /// Editor close / Root retirement sweep: cancel every owned adapter call
    /// for this route but KEEP the slot and its exact owned-work lease until
    /// the awaited adapter REALLY settles (settleAndRelease). Cancellation
    /// alone therefore never looks "drained" to lifecycle observers, and a
    /// late result for the retired route is never pollable (the slot is only
    /// removed at real terminal; polls before that answer pending, after
    /// that routeUnavailable).
    func cancelAll(routeToken: String) {
        var cancelled: [Task<Void, Never>] = []
        lock.lock()
        for (handle, slot) in slots where slot.routeToken == routeToken {
            if case .running(let task) = slot.state {
                var updated = slot
                updated.abandoned = true
                slots[handle] = updated
                cancelled.append(task)
            } else {
                // Settled-but-unpolled slots for a closed route are dropped;
                // their lease already settled at the task terminal.
                slots.removeValue(forKey: handle)
            }
        }
        order.removeAll { slots[$0] == nil }
        lock.unlock()
        for task in cancelled { task.cancel() }
    }

    /// The race check used immediately before dispatch (see submit).
    /// Lock order stays route -> probe EVERYWHERE: the slot state is read
    /// under the probe lock and RELEASED first; the route re-check then
    /// takes the registry lock. A retirement landing between the two is
    /// harmless: the sweep marks the slot abandoned under the probe lock and
    /// cancels the task, and cancellation still settles the lease at the
    /// real adapter terminal (never before).
    private func isDispatchLive(handle: String, routeToken: String) -> Bool {
        lock.lock()
        let slotLive: Bool
        if let slot = slots[handle], !slot.abandoned, case .running = slot.state {
            slotLive = true
        } else {
            slotLive = false
        }
        lock.unlock()
        guard slotLive else { return false }
        return G02HostSecureIngress.registry.assertLiveProviderRoute(token: routeToken) != nil
    }

    /// Real terminal: remove the slot, then release the exact lease. The
    /// awaited adapter call has returned (completed, failed or genuinely
    /// unwound via cancellation) at this point — settle-after-settlement,
    /// never detach-on-cancel.
    private func settleAndRelease(handle: String, lease: ConfigOwnedWorkLease,
                                  payload: Data) {
        lock.lock()
        if var slot = slots[handle] {
            slot.state = .settled(payload)
            if slot.abandoned {
                // Retired route: drop the slot at real terminal so late
                // polls fail closed; the lease release below is the drain
                // signal lifecycle observers waited for.
                slots.removeValue(forKey: handle)
                order.removeAll { slots[$0] == nil }
                lock.unlock()
                lifecycle.settle(lease)
                return
            }
            slots[handle] = slot
            evictSettledLocked(routeToken: slot.routeToken)
        }
        lock.unlock()
        lifecycle.settle(lease)
    }

    /// Test seam: live slot count (never exposed to the wire).
    var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.values.reduce(into: 0) { count, slot in
            if case .running = slot.state { count += 1 }
        }
    }

    /// Test-only full reset.
    func resetForTesting() {
        Self.facadeProviderForTesting = nil
        Self.lifecycleForTesting = nil
        lock.lock()
        slots.removeAll()
        order.removeAll()
        lock.unlock()
    }

    private func evictSettledLocked(routeToken: String) {
        var settled = order.filter { handle in
            guard let slot = slots[handle], slot.routeToken == routeToken else { return false }
            if case .settled = slot.state { return true }
            return false
        }
        while settled.count > Self.maximumSettledSlots {
            let oldest = settled.removeFirst()
            slots.removeValue(forKey: oldest)
        }
        order.removeAll { slots[$0] == nil }
    }

    // MARK: Identity / payload shaping

    private static func candidateProviderID(_ candidateJSON: Data) -> UUID? {
        guard let object = (try? JSONSerialization.jsonObject(with: candidateJSON))
                as? [String: Any],
              let raw = object["id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    private static func makeHandle() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
        return "dp:v1:" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func settlePayload(_ outcome: ConfigProbeOutcome) -> Data {
        let object = (try? outcome.jsonObject()) ?? ["status": "failed",
                                                     "failureReason": "probeRejected"]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"status\":\"failed\",\"failureReason\":\"probeRejected\"}".utf8)
    }

    private static func cancelledPayload() -> Data {
        Data("{\"status\":\"cancelled\",\"failureReason\":\"cancelled\"}".utf8)
    }

    private static func failurePayload(code: String, reason: String) -> Data {
        let object: [String: Any] = ["status": "failed", "errorCode": code, "reason": reason]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"status\":\"failed\",\"errorCode\":\"runtimeUnavailable\"}".utf8)
    }
}

// MARK: - Trusted host C ABI (App process only; not a V3 command)

/// Freeze + dispatch ONE draft probe/discovery. `secret` may be empty (a
/// no-credential draft) but its length must be within the frozen vault bound.
/// Everything (including the output capacity) is validated BEFORE any
/// dispatch; the returned `dp:v1:` handle names the owned operation.
@_cdecl("floe_host_draft_probe_submit")
public func floeHostDraftProbeSubmit(_ candidateJSON: UnsafePointer<UInt8>?,
                                     _ candidateLen: Int32,
                                     _ secret: UnsafePointer<UInt8>?,
                                     _ secretLen: Int32,
                                     _ routeToken: UnsafePointer<CChar>?,
                                     _ outHandle: UnsafeMutablePointer<CChar>?,
                                     _ outCap: Int32) -> Int32 {
    guard let outHandle, outCap >= G02HostDraftProbeStatus.handleCapacity else {
        return G02HostDraftProbeStatus.invalidArgument
    }
    guard candidateLen > 0, let candidateJSON else {
        return G02HostDraftProbeStatus.invalidCandidate
    }
    guard Int(candidateLen) <= G02HostDraftProbeRegistry.maximumCandidateBytes else {
        return G02HostDraftProbeStatus.candidateTooLarge
    }
    guard secretLen >= 0 else { return G02HostDraftProbeStatus.invalidArgument }
    guard Int(secretLen) <= G02HostDraftProbeRegistry.maximumSecretBytes else {
        return G02HostDraftProbeStatus.secretTooLarge
    }
    guard let routeToken, let routeLength = hostDraftProbeCLength(routeToken, maximum: 64),
          routeLength > 0 else {
        return G02HostDraftProbeStatus.invalidArgument
    }
    let route = String(decoding: UnsafeBufferPointer(start: routeToken, count: routeLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var secretData = Data()
    if secretLen > 0, let secret {
        secretData = Data(bytes: UnsafeRawPointer(secret), count: Int(secretLen))
    }
    defer {
        if secretData.count > 0 { secretData.resetBytes(in: 0..<secretData.count) }
        secretData = Data()
    }
    do {
        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: Data(bytes: UnsafeRawPointer(candidateJSON),
                                count: Int(candidateLen)),
            secret: secretData,
            routeAssertion: route)
        guard handle.utf8.count + 1 <= Int(outCap) else {
            return G02HostDraftProbeStatus.invalidArgument
        }
        for (index, byte) in handle.utf8.enumerated() {
            outHandle[index] = CChar(bitPattern: byte)
        }
        outHandle[handle.utf8.count] = 0
        return G02HostDraftProbeStatus.ok
    } catch let error as G02HostDraftProbeError {
        switch error {
        case .invalidArgument: return G02HostDraftProbeStatus.invalidArgument
        case .invalidCandidate: return G02HostDraftProbeStatus.invalidCandidate
        case .secretTooLarge: return G02HostDraftProbeStatus.secretTooLarge
        case .candidateTooLarge: return G02HostDraftProbeStatus.candidateTooLarge
        case .saturated: return G02HostDraftProbeStatus.saturated
        case .routeUnavailable: return G02HostDraftProbeStatus.routeUnavailable
        case .routeAssertionMismatch: return G02HostDraftProbeStatus.routeAssertionMismatch
        }
    } catch {
        return G02HostDraftProbeStatus.invalidArgument
    }
}

/// Non-blocking result poll. 0 = settled payload copied, 2 = pending (no
/// payload), -121 = the provided buffer is too small (`outLength` then holds
/// the exact required size). Negative refusals otherwise.
@_cdecl("floe_host_draft_probe_result")
public func floeHostDraftProbeResult(_ handle: UnsafePointer<CChar>?,
                                     _ routeToken: UnsafePointer<CChar>?,
                                     _ outPayload: UnsafeMutablePointer<UInt8>?,
                                     _ outCap: Int32,
                                     _ outLength: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let handle, let handleLength = hostDraftProbeCLength(handle, maximum: 64),
          handleLength > 0,
          let routeToken, let routeLength = hostDraftProbeCLength(routeToken, maximum: 64),
          routeLength > 0 else {
        return G02HostDraftProbeStatus.invalidArgument
    }
    let handleValue = String(decoding: UnsafeBufferPointer(start: handle, count: handleLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let route = String(decoding: UnsafeBufferPointer(start: routeToken, count: routeLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    do {
        let (status, payload) = try G02HostDraftProbeRegistry.shared.result(
            handle: handleValue, routeAssertion: route)
        guard status == G02HostDraftProbeStatus.ok, let payload else {
            outLength?.pointee = 0
            return G02HostDraftProbeStatus.pending
        }
        guard payload.count <= Int(Int32.max) else {
            return G02HostDraftProbeStatus.invalidArgument
        }
        outLength?.pointee = Int32(payload.count)
        guard outCap >= Int32(payload.count), let outPayload else {
            return G02HostDraftProbeStatus.bufferTooSmall
        }
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress, payload.count > 0 {
                outPayload.update(from: base.assumingMemoryBound(to: UInt8.self),
                                  count: payload.count)
            }
        }
        return G02HostDraftProbeStatus.ok
    } catch G02HostDraftProbeError.routeUnavailable {
        return G02HostDraftProbeStatus.routeUnavailable
    } catch {
        return G02HostDraftProbeStatus.invalidArgument
    }
}

/// Owner cancel (editor cancel / close). Idempotent; a stale handle is
/// refused without touching a newer route.
@_cdecl("floe_host_draft_probe_cancel")
public func floeHostDraftProbeCancel(_ handle: UnsafePointer<CChar>?,
                                     _ routeToken: UnsafePointer<CChar>?) -> Int32 {
    guard let handle, let handleLength = hostDraftProbeCLength(handle, maximum: 64),
          handleLength > 0,
          let routeToken, let routeLength = hostDraftProbeCLength(routeToken, maximum: 64),
          routeLength > 0 else {
        return G02HostDraftProbeStatus.invalidArgument
    }
    let handleValue = String(decoding: UnsafeBufferPointer(start: handle, count: handleLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let route = String(decoding: UnsafeBufferPointer(start: routeToken, count: routeLength)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return G02HostDraftProbeRegistry.shared.cancel(handle: handleValue,
                                                   routeAssertion: route)
        ? G02HostDraftProbeStatus.ok
        : G02HostDraftProbeStatus.routeUnavailable
}

private func hostDraftProbeCLength(_ pointer: UnsafePointer<CChar>,
                                   maximum: Int) -> Int? {
    var length = 0
    while length <= maximum {
        if pointer[length] == 0 { return length }
        length += 1
    }
    return nil
}
