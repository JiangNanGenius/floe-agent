// SPDX-License-Identifier: MPL-2.0
//
// MC-WEBSEARCH-3 ADDITIVE MIRROR of the live
// FloeAndroid/shared/Sources/FloeAndroidCore/SecretSaveIntentVault.swift
// (preimage sha256 64eac84b1263d238fa91c53d793dd95d3fd97491bfbce66bae6de
// 0218c7ccfa3, read-only at authoring time).
//
// This package is authorized to mirror this file ADDITIVELY ONLY, to
// implement the Main-authorized closed SubjectKind.webSearchSave kind
// (MAIN_WEB_SEARCH_SECURE_INGRESS_DECISION_20261019.json). The single delta
// is the webSearchSave cross-subject parse rule marked MC-WEBSEARCH-3 below;
// every other byte is the live file verbatim. SubjectKind itself gains
// `webSearchSave` in the SecretGatewayMailbox.swift mirror of THIS package
// (the live mailbox declares the enum). There is NO new public v3 command,
// NO new permission and NO new JNI signature: the existing
// floe_secret_save_intent_submit / _discard C ABI and the internal
// consume(token:route:expectedSubject:) seam are reused unchanged, and
// consume's existing expectedSubject equality enforces that a providerSave
// or mcpSave token can never drive a web-search save and vice versa.
//
// (private source candidate; NOT compiled, NOT executed; GRAMMAR-ONLY
// evidence in evidence/.)

// SPDX-License-Identifier: MPL-2.0
//
// Product-UID credential gateway — P2 save-intent vault.
//
// One atomic host-issued call at save-tap freezes the subject, route,
// baseRevision, candidate and binary secret together BEFORE any envelope
// exists. The LIVE slot is a bounded TTL transit (<=4, 120 s, unconsumed
// only). Consumption is one-shot and returns a non-Sendable typed lease; the
// vault keeps only an id-only ACTIVE admission (<=4, NO TTL) that is released
// by the handler's explicit `lease.close()`. A failed close is bounded
// fail-closed: the admission stays recorded and the cap refuses further
// admissions until an actual close succeeds.
//
// This file is the complete vault/ABI candidate. It is NOT compiled by the
// source-authoring package that produced it.
import Foundation
import Dispatch
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - Bounds

public enum SecretSaveIntentLimits {
    public static let maximumLiveSlots = 4
    public static let maximumActiveLeases = 4
    public static let maximumSecretBytes = 65_536
    public static let maximumIntentJSONBytes = 16_384
    public static let liveSlotTTLMillis: UInt64 = 120_000
    public static let maximumSubjectIDBytes = 128
    public static let maximumRouteTokenBytes = 128
    public static let maximumRevisionFieldBytes = 256
    public static let ingressTokenLogicalBytes = 39
    public static let ingressTokenCapacity = 40
}

// MARK: - Internal error surface

enum SaveIntentVaultError: Error, Equatable {
    case invalidArgument
    case invalidSchema
    case valueTooLarge
    case saturated
    case emptyValue
    case jsonTooLarge
}

// MARK: - Frozen intent model

struct ParsedSaveIntent {
    let subject: SubjectKind
    let subjectID: String
    let route: RouteBinding
    let baseRevision: SaveIntentBaseRevision?
    let candidateJSON: Data
}

struct SecretSaveIntentVaultStats {
    let intentsLive: Int
    let leasesActive: Int
    let leasesCloseFailed: Int
}

/// Typed, single-owner, NON-Sendable lease. The handler must keep it inside
/// its own scope and close it in a defer/owner-scope end. The vault holds no
/// candidate/secret copy for an ACTIVE admission.
public final class SaveIntentLease {
    public let leaseID: String
    public let subject: SubjectKind
    /// Frozen at save-tap for the handler's separate base CAS check. It is
    /// non-secret and is never itself a CAS decision.
    public let baseRevision: SaveIntentBaseRevision?
    public private(set) var candidateJSON: Data
    public private(set) var secret: Data?
    private weak var vault: SecretSaveIntentVault?
    private var closed = false

    init(leaseID: String, subject: SubjectKind, baseRevision: SaveIntentBaseRevision?,
         candidateJSON: Data, secret: Data?, vault: SecretSaveIntentVault) {
        self.leaseID = leaseID
        self.subject = subject
        self.baseRevision = baseRevision
        self.candidateJSON = candidateJSON
        self.secret = secret
        self.vault = vault
    }

    /// Explicit owner-scope release. Always zeroes the lease's own candidate
    /// and secret copies. Returns false when the admission release failed:
    /// the admission remains recorded and the cap stays fail-closed. A retry
    /// of close() is allowed; the admission is never replenished by time.
    @discardableResult
    public func close() -> Bool {
        if closed { return true }
        if candidateJSON.count > 0 {
            candidateJSON.resetBytes(in: 0..<candidateJSON.count)
        }
        candidateJSON = Data()
        if var bytes = secret {
            bytes.resetBytes(in: 0..<bytes.count)
            secret = nil
        }
        guard let vault else { return false }
        let released = vault.releaseAdmission(leaseID)
        if released {
            closed = true
        }
        return released
    }
}

// MARK: - Vault

/// Single process-wide save-intent vault. One lock guards LIVE slots, ACTIVE
/// admissions, retirement history and counters. Candidate JSON and secret
/// bytes are never logged, included in stats or exposed through rejections.
public final class SecretSaveIntentVault: @unchecked Sendable {
    public static let shared = SecretSaveIntentVault()

    private enum RetiredReason: UInt8 {
        case consumed
        case expired
    }

    private struct LiveSlot {
        let token: String
        let subject: SubjectKind
        let subjectID: String
        let routeToken: String
        let routeGeneration: UInt64
        let baseRevision: SaveIntentBaseRevision?
        var candidateJSON: Data
        var secret: Data
        let createdAt: UInt64
    }

    private struct Admission {
        let subject: SubjectKind
        let subjectID: String
    }

    private let lock = NSLock()
    private var slots: [String: LiveSlot] = [:]
    private var activeAdmissions: [String: Admission] = [:]
    private var retired: [String: RetiredReason] = [:]
    private var retiredOrder: [String] = []
    private var leasesCloseFailed = 0
    private var failNextCloseForTesting = false
    private var clockOverride: (() -> UInt64)?

    private init() {}

    private func nowLocked() -> UInt64 {
        if let clockOverride { return clockOverride() }
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    // MARK: Submit / discard

    /// Atomic save-tap capture. Validates the closed intent schema, copies the
    /// secret and candidate bytes into one bounded LIVE slot and mints a
    /// non-value-derived `int:v1:` handle (39 logical / 40 C bytes).
    func submit(intentJSON: Data, secret: Data) throws -> String {
        guard !intentJSON.isEmpty,
              intentJSON.count <= SecretSaveIntentLimits.maximumIntentJSONBytes else {
            throw SaveIntentVaultError.jsonTooLarge
        }
        guard !secret.isEmpty else { throw SaveIntentVaultError.emptyValue }
        guard secret.count <= SecretSaveIntentLimits.maximumSecretBytes else {
            throw SaveIntentVaultError.valueTooLarge
        }
        let parsed = try parseIntent(intentJSON)

        lock.lock()
        defer { lock.unlock() }
        let now = nowLocked()
        sweepExpiredLocked(at: now)
        guard slots.count < SecretSaveIntentLimits.maximumLiveSlots else {
            throw SaveIntentVaultError.saturated
        }
        var token = makeIngressToken()
        var attempts = 0
        while slots[token] != nil {
            attempts += 1
            if attempts > 8 { throw SaveIntentVaultError.saturated }
            token = makeIngressToken()
        }
        slots[token] = LiveSlot(
            token: token,
            subject: parsed.subject,
            subjectID: parsed.subjectID,
            routeToken: parsed.route.token,
            routeGeneration: parsed.route.generation,
            baseRevision: parsed.baseRevision,
            candidateJSON: parsed.candidateJSON,
            secret: secret,
            createdAt: now
        )
        return token
    }

    /// Best-effort zero+free of one LIVE slot. Idempotent for a well-formed
    /// token; ACTIVE leases are not affected.
    @discardableResult
    func discard(token: String) -> Int32 {
        guard SecretGatewayIdentity.isCanonicalIngressToken(token) else { return -105 }
        lock.lock()
        if var slot = slots.removeValue(forKey: token) {
            zeroSlot(&slot)
        }
        lock.unlock()
        return 0
    }

    /// Route-scoped retirement: zeroes and frees every UNCONSUMED LIVE slot
    /// frozen to this exact route pair (host route close / Root retirement /
    /// cancelled admission). Consumed intents are no longer LIVE slots: their
    /// ACTIVE lease belongs to the consuming handler until its own terminal
    /// close, so it is deliberately NEVER touched here. Returns the number of
    /// discarded slots (diagnostic only).
    @discardableResult
    func discardLiveSlots(routeToken: String, routeGeneration: UInt64) -> Int {
        guard !routeToken.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        var matched: [String] = []
        for (key, slot) in slots
        where slot.routeToken == routeToken && slot.routeGeneration == routeGeneration {
            matched.append(key)
        }
        for key in matched {
            if var removed = slots.removeValue(forKey: key) {
                zeroSlot(&removed)
            }
        }
        return matched.count
    }

    /// One-shot consume. On ANY outcome the LIVE slot's bytes and candidate
    /// are zeroed and the slot is removed; a typed rejection is thrown for
    /// route/subject mismatch, expiry, unknown/consumed token or ACTIVE-lease
    /// saturation. Success registers one id-only admission and returns the
    /// typed non-Sendable lease.
    func consume(token: String, route: RouteBinding,
                 expectedSubject: SubjectKind) throws -> SaveIntentLease {
        guard SecretGatewayIdentity.isCanonicalIngressToken(token) else {
            throw SecretBackendError.intentRejected(.unknownToken)
        }
        lock.lock()
        defer { lock.unlock() }
        let now = nowLocked()
        guard var slot = slots.removeValue(forKey: token) else {
            if let retiredReason = retired[token] {
                switch retiredReason {
                case .consumed:
                    throw SecretBackendError.intentRejected(.consumed)
                case .expired:
                    throw SecretBackendError.intentRejected(.expired)
                }
            }
            throw SecretBackendError.intentRejected(.unknownToken)
        }
        if now >= slot.createdAt && now - slot.createdAt > SecretSaveIntentLimits.liveSlotTTLMillis {
            zeroSlot(&slot)
            addRetiredLocked(token: token, reason: .expired)
            throw SecretBackendError.intentRejected(.expired)
        }

        var candidate = slot.candidateJSON
        // The lease's secret copy is optional by type; keep the optional here
        // so the rejection zeroizer can release/nil it on every exit path.
        var secret: Data? = slot.secret
        zeroSlot(&slot)
        addRetiredLocked(token: token, reason: .consumed)

        guard slot.subject == expectedSubject else {
            zeroBytes(&candidate)
            zeroOptionalBytes(&secret)
            throw SecretBackendError.intentRejected(.subjectMismatch)
        }
        guard slot.routeToken == route.token && slot.routeGeneration == route.generation else {
            zeroBytes(&candidate)
            zeroOptionalBytes(&secret)
            throw SecretBackendError.intentRejected(.routeMismatch)
        }
        guard activeAdmissions.count < SecretSaveIntentLimits.maximumActiveLeases else {
            zeroBytes(&candidate)
            zeroOptionalBytes(&secret)
            throw SecretBackendError.intentRejected(.intentSaturated)
        }

        let leaseID = makeLeaseID()
        activeAdmissions[leaseID] = Admission(subject: slot.subject, subjectID: slot.subjectID)
        return SaveIntentLease(leaseID: leaseID, subject: slot.subject,
                               baseRevision: slot.baseRevision,
                               candidateJSON: candidate, secret: secret, vault: self)
    }

    // MARK: Expiry / admission release

    /// Executes ONLY for unconsumed LIVE slots. ACTIVE admissions are never
    /// time-expired; a hung handler keeps its admission until explicit close.
    func sweepExpired(at now: UInt64) {
        lock.lock()
        sweepExpiredLocked(at: now)
        lock.unlock()
    }

    private func sweepExpiredLocked(at now: UInt64) {
        guard !slots.isEmpty else { return }
        var expired: [String] = []
        for (token, slot) in slots {
            if now >= slot.createdAt &&
                now - slot.createdAt > SecretSaveIntentLimits.liveSlotTTLMillis {
                expired.append(token)
            }
        }
        for token in expired {
            if var slot = slots.removeValue(forKey: token) {
                zeroSlot(&slot)
                addRetiredLocked(token: token, reason: .expired)
            }
        }
    }

    func releaseAdmission(_ leaseID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeAdmissions[leaseID] != nil else { return true }
        if failNextCloseForTesting {
            failNextCloseForTesting = false
            leasesCloseFailed += 1
            return false
        }
        activeAdmissions.removeValue(forKey: leaseID)
        return true
    }

    // MARK: Diagnostics (counters only; no candidate/secret/reference)

    func statsSnapshot() -> SecretSaveIntentVaultStats {
        lock.lock()
        defer { lock.unlock() }
        return SecretSaveIntentVaultStats(intentsLive: slots.count,
                                          leasesActive: activeAdmissions.count,
                                          leasesCloseFailed: leasesCloseFailed)
    }

    // MARK: Test-only control

    internal func configureForTesting(clock: (() -> UInt64)? = nil) {
        lock.lock()
        if let clock { clockOverride = clock }
        lock.unlock()
    }

    internal func parseGenerationForTesting(_ number: NSNumber) -> UInt64? {
        parseGeneration(number)
    }

    internal func setFailNextCloseForTesting() {
        lock.lock()
        failNextCloseForTesting = true
        lock.unlock()
    }

    internal func resetForTesting() {
        lock.lock()
        for key in Array(slots.keys) {
            if var slot = slots.removeValue(forKey: key) {
                zeroSlot(&slot)
            }
        }
        slots.removeAll()
        activeAdmissions.removeAll()
        retired.removeAll()
        retiredOrder.removeAll()
        leasesCloseFailed = 0
        failNextCloseForTesting = false
        clockOverride = nil
        lock.unlock()
    }

    // MARK: Schema

    private func parseIntent(_ data: Data) throws -> ParsedSaveIntent {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SaveIntentVaultError.invalidSchema
        }
        let allowed: Set<String> = ["subject", "route", "intent", "baseRevision", "candidate"]
        guard Set(object.keys).isSubset(of: allowed) else {
            throw SaveIntentVaultError.invalidSchema
        }
        guard let intent = object["intent"] as? String, intent == "set" else {
            throw SaveIntentVaultError.invalidSchema
        }
        guard let subjectObject = object["subject"] as? [String: Any],
              Set(subjectObject.keys).isSubset(of: ["kind", "id"]),
              let kindString = subjectObject["kind"] as? String,
              let kind = SubjectKind(rawValue: kindString),
              let subjectID = subjectObject["id"] as? String,
              !subjectID.isEmpty,
              subjectID.utf8.count <= SecretSaveIntentLimits.maximumSubjectIDBytes else {
            throw SaveIntentVaultError.invalidSchema
        }
        guard let routeObject = object["route"] as? [String: Any],
              Set(routeObject.keys).isSubset(of: ["token", "generation"]),
              let routeToken = routeObject["token"] as? String,
              !routeToken.isEmpty,
              routeToken.utf8.count <= SecretSaveIntentLimits.maximumRouteTokenBytes,
              let generationNumber = routeObject["generation"] as? NSNumber,
              let generation = parseGeneration(generationNumber) else {
            throw SaveIntentVaultError.invalidSchema
        }
        guard let candidate = object["candidate"] as? [String: Any],
              let candidateID = candidate["id"] as? String,
              !candidateID.isEmpty,
              candidateID == subjectID else {
            throw SaveIntentVaultError.invalidSchema
        }
        // The subject kind is a closed vocabulary. A provider identity is
        // never accepted as an MCP subject: the candidate must not smuggle a
        // providerID/servers identity under the other kind. Subject-specific
        // field validation remains the consumer handler's authority.
        if kind == .mcpSave && candidate["providerID"] != nil {
            throw SaveIntentVaultError.invalidSchema
        }
        if kind == .providerSave && (candidate["serverID"] != nil || candidate["mcpServerID"] != nil) {
            throw SaveIntentVaultError.invalidSchema
        }
        // MC-WEBSEARCH-3 (MAIN_WEB_SEARCH_SECURE_INGRESS_DECISION_20261019
        // .json): the web-search save subject is a CLOSED kind. Its subject
        // id is the exact canonical WebSearchProviderConfiguration.id and
        // the generic candidate["id"] == subjectID check above already
        // binds them. Additively, a web-search candidate can never smuggle
        // a provider / server / MCP identity: those keys are refused here,
        // before any LIVE slot is stored. The candidate's web-search field
        // requirements by provider kind are the consumer handler's authority
        // (RuntimeFacadeConfig save path), exactly like providerSave.
        if kind == .webSearchSave
            && (candidate["providerID"] != nil || candidate["serverID"] != nil
                || candidate["mcpServerID"] != nil) {
            throw SaveIntentVaultError.invalidSchema
        }
        let candidateData: Data
        do {
            candidateData = try JSONSerialization.data(withJSONObject: candidate,
                                                       options: [.sortedKeys])
        } catch {
            throw SaveIntentVaultError.invalidSchema
        }
        guard candidateData.count <= SecretSaveIntentLimits.maximumIntentJSONBytes else {
            throw SaveIntentVaultError.jsonTooLarge
        }
        var baseRevision: SaveIntentBaseRevision?
        if let raw = object["baseRevision"] {
            guard !(raw is NSNull),
                  let baseObject = raw as? [String: Any],
                  Set(baseObject.keys).isSubset(of: ["resourceID", "version"]),
                  let resourceID = baseObject["resourceID"] as? String,
                  let version = baseObject["version"] as? String,
                  !resourceID.isEmpty, !version.isEmpty,
                  resourceID.utf8.count <= SecretSaveIntentLimits.maximumRevisionFieldBytes,
                  version.utf8.count <= SecretSaveIntentLimits.maximumRevisionFieldBytes else {
                throw SaveIntentVaultError.invalidSchema
            }
            baseRevision = SaveIntentBaseRevision(resourceID: resourceID, version: version)
        }
        return ParsedSaveIntent(subject: kind, subjectID: subjectID,
                                route: RouteBinding(token: routeToken, generation: generation),
                                baseRevision: baseRevision, candidateJSON: candidateData)
    }

    /// Route generation is a real unsigned integer, never a JSON boolean or a
    /// lossy floating coercion. Exact integer NSNumber/NSDecimalNumber text is
    /// parsed directly; floating, boolean, fractional, negative, nonfinite and
    /// out-of-range values are rejected before a LIVE slot is stored.
    private func parseGeneration(_ number: NSNumber) -> UInt64? {
        #if canImport(CoreFoundation)
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        #endif
        // Foundation may use NSDecimalNumber for large exact integers. Its
        // stringValue is exact; still reject a decimal point/exponent form.
        if let decimal = number as? NSDecimalNumber {
            let text = decimal.stringValue
            if text.contains(".") || text.contains("e") || text.contains("E") {
                return nil
            }
            return UInt64(text)
        }
        let type = String(cString: number.objCType)
        if type == "c" || type == "B" || type == "d" || type == "f" {
            // 'c'/'B' are boolean representations on corelibs Foundation;
            // 'd'/'f' are lossy floating representations.
            return nil
        }
        return UInt64(number.stringValue)
    }

    // MARK: Zeroization / tokens

    private func zeroSlot(_ slot: inout LiveSlot) {
        if slot.candidateJSON.count > 0 {
            slot.candidateJSON.resetBytes(in: 0..<slot.candidateJSON.count)
        }
        slot.candidateJSON = Data()
        if slot.secret.count > 0 {
            slot.secret.resetBytes(in: 0..<slot.secret.count)
        }
        slot.secret = Data()
    }

    private func zeroBytes(_ value: inout Data) {
        if value.count > 0 { value.resetBytes(in: 0..<value.count) }
        value = Data()
    }

    private func zeroOptionalBytes(_ value: inout Data?) {
        if var bytes = value {
            if bytes.count > 0 { bytes.resetBytes(in: 0..<bytes.count) }
        }
        value = nil
    }

    private func addRetiredLocked(token: String, reason: RetiredReason) {
        retired[token] = reason
        retiredOrder.append(token)
        while retiredOrder.count > 64 {
            let oldest = retiredOrder.removeFirst()
            retired.removeValue(forKey: oldest)
        }
    }

    private func makeIngressToken() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }
        return "int:v1:" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func makeLeaseID() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - C ABI

private func cStringLength(_ pointer: UnsafePointer<CChar>, maximum: Int) -> Int? {
    var length = 0
    while length <= maximum {
        if pointer[length] == 0 { return length }
        length += 1
    }
    return nil
}

@_cdecl("floe_secret_save_intent_submit")
public func floeSecretSaveIntentSubmit(_ intentJSON: UnsafePointer<CChar>?,
                                       _ value: UnsafePointer<UInt8>?,
                                       _ valueLen: Int32,
                                       _ outToken: UnsafeMutablePointer<CChar>?,
                                       _ outCap: Int32) -> Int32 {
    guard let intentJSON, let outToken,
          outCap >= Int32(SecretSaveIntentLimits.ingressTokenCapacity) else {
        return -105
    }
    guard let jsonLength = cStringLength(intentJSON,
                                         maximum: SecretSaveIntentLimits.maximumIntentJSONBytes) else {
        return -116
    }
    guard jsonLength > 0 else { return -110 }
    guard valueLen >= 0 else { return -105 }
    guard valueLen > 0 else { return -115 }
    guard valueLen <= Int32(SecretSaveIntentLimits.maximumSecretBytes) else { return -111 }
    guard let value else { return -105 }
    let json = Data(bytes: UnsafeRawPointer(intentJSON), count: jsonLength)
    let secret = Data(bytes: UnsafeRawPointer(value), count: Int(valueLen))
    do {
        let token = try SecretSaveIntentVault.shared.submit(intentJSON: json, secret: secret)
        guard token.utf8.count + 1 <= Int(outCap) else { return -105 }
        for (index, byte) in token.utf8.enumerated() {
            outToken[index] = CChar(bitPattern: byte)
        }
        outToken[token.utf8.count] = 0
        return 0
    } catch SaveIntentVaultError.invalidSchema {
        return -110
    } catch SaveIntentVaultError.valueTooLarge {
        return -111
    } catch SaveIntentVaultError.saturated {
        return -112
    } catch SaveIntentVaultError.emptyValue {
        return -115
    } catch SaveIntentVaultError.jsonTooLarge {
        return -116
    } catch SaveIntentVaultError.invalidArgument {
        return -105
    } catch {
        return -105
    }
}

@_cdecl("floe_secret_save_intent_discard")
public func floeSecretSaveIntentDiscard(_ token: UnsafePointer<CChar>?) -> Int32 {
    guard let token, let length = cStringLength(token, maximum: 64),
          length == SecretSaveIntentLimits.ingressTokenLogicalBytes else {
        return -105
    }
    let value = String(cString: token)
    guard SecretGatewayIdentity.isCanonicalIngressToken(value) else { return -105 }
    return SecretSaveIntentVault.shared.discard(token: value)
}
