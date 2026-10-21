// SPDX-License-Identifier: MPL-2.0
//
// G02PrivacyHostConfirmation — the REAL privileged trusted-host confirmation
// ingress for the two privacy clear operations.
//
// Authority: MAIN_PRIVACY_REPORT_STREAMING_DECISION_20261019
// (hostConfirmation.required/implementation/lifetime) and
// PRIVACY_SOURCE_MAIN_INTEGRATION_DIRECTIONS_20261019 (one-operation owner
// binding).
//
// A production clear is authorized ONLY by this chain:
//   1. the App shows the exact preview (digest from privacy.summary.get);
//   2. the user taps the explicit confirmation action;
//   3. the App calls the privileged JNI ingress WITH its live owner proof
//      (epoch + full owner token, never wire content);
//   4. the native ingress validates the proof against the live generation
//      (`RuntimeFacadeBootstrap.g02OwnerProofValid`) and the privacy
//      extension's registered store for this exact epoch;
//   5. the store mints an opaque bounded capability bound to
//      root + epoch + operation + action + preview digest + the host's exact
//      command invocation (correlationID);
//   6. the command path consumes it ONCE before any effect.
//
// It is NOT a V3 command, has no command name, label, matrix entry, tool or
// permission, and is unreachable from model-authored envelopes. The owner
// token never enters the wire, UI saved state or logs; refusals carry only a
// numeric status.
import Foundation
import Crypto
import FloeCore

public enum PrivacyConfirmationStatus {
    public static let ok: Int32 = 0
    public static let invalidArgument: Int32 = -105
    /// The presented owner epoch/token is not the live accepted generation.
    public static let ownerProofInvalid: Int32 = -120
    /// The privacy extension is not attached (no registered confirmation
    /// store for this epoch) or the runtime is retiring.
    public static let notReady: Int32 = -121
    public static let confirmationSaturated: Int32 = -122
    public static let confirmationNotFound: Int32 = -123
}

/// One accepted root/epoch's confirmation store. It is created by the
/// privacy extension at attach and registered process-wide. All methods are
/// synchronous under one lock so the JNI ingress can mint without awaiting:
/// the store owns no database, network or UI state.
public final class PrivacyHostConfirmationStore: @unchecked Sendable {
    public let root: String
    public let epoch: UInt64

    private struct Record {
        let binding: PrivacyHostConfirmationBinding
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var order: [String] = []
    private let clock: @Sendable () -> Date
    private var retired = false

    public init(root: String, epoch: UInt64,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.epoch = epoch
        self.clock = clock
    }

    /// Mint ONE capability after the real dialog. The caller is the
    /// privileged native ingress (owner proof already validated); this
    /// method never accepts a caller-supplied root/epoch and never derives
    /// consent from a digest or token alone.
    public func issue(operation: String, action: String,
                      previewDigest: String, invocationID: String) -> String? {
        guard Self.isValidOperation(operation),
              Self.expectedAction(for: operation) == action,
              Self.isDigest(previewDigest),
              Self.isValidInvocation(invocationID) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return nil }
        purgeExpiredLocked()
        guard records.count < PrivacyConfirmationLimits.maximumLiveCapabilities else {
            return nil
        }
        let token = Self.mintToken()
        guard records[token] == nil else { return nil }
        let binding = PrivacyHostConfirmationBinding(
            operation: operation, action: action, root: root, epoch: epoch,
            previewDigest: previewDigest, invocationID: invocationID)
        let record = Record(
            binding: binding,
            expiresAt: clock().addingTimeInterval(
                PrivacyConfirmationLimits.maximumTTLSeconds))
        records[token] = record
        order.append(token)
        while order.count > PrivacyConfirmationLimits.maximumLiveCapabilities * 2 {
            let evicted = order.removeFirst()
            records[evicted] = nil
        }
        return token
    }

    /// Atomic one-shot consume. A mismatched request (wrong operation/action/
    /// digest/invocation) NEVER burns the user's capability: it returns nil
    /// and leaves the record for the exact trusted invocation. Expired,
    /// foreign and replayed values answer nil.
    public func consume(token: String, operation: String, action: String,
                        previewDigest: String, invocationID: String)
        -> PrivacyHostConfirmationBinding?
    {
        lock.lock()
        defer { lock.unlock() }
        guard !retired, let record = records[token] else { return nil }
        guard record.expiresAt > clock() else {
            records[token] = nil
            return nil
        }
        let binding = record.binding
        guard binding.root == root, binding.epoch == epoch,
              binding.operation == operation, binding.action == action,
              binding.previewDigest == previewDigest,
              binding.invocationID == invocationID else {
            return nil
        }
        records[token] = nil
        return binding
    }

    /// Exact-token revoke (user cancel or a superseded dialog). Unknown
    /// tokens are refused without touching any other record.
    @discardableResult
    public func revoke(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard records.removeValue(forKey: token) != nil else { return false }
        return true
    }

    /// RootStop: remove every capability minted by THIS epoch. A newer
    /// epoch's store is a separate instance and is never touched.
    public func retire() {
        lock.lock()
        retired = true
        records.removeAll()
        order.removeAll()
        lock.unlock()
    }

    public var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked()
        return records.count
    }

    private func purgeExpiredLocked() {
        let now = clock()
        let expired = records.compactMap { entry in
            entry.value.expiresAt <= now ? entry.key : nil
        }
        for key in expired { records[key] = nil }
        order.removeAll { records[$0] == nil }
    }

    // MARK: Closed validation

    static func isValidOperation(_ operation: String) -> Bool {
        operation == RuntimeFacadePrivacy.historyClearOperation
            || operation == RuntimeFacadePrivacy.modelConfigClearOperation
    }

    static func expectedAction(for operation: String) -> String? {
        switch operation {
        case RuntimeFacadePrivacy.historyClearOperation:
            return PrivacyConfirmationLimits.historyAction
        case RuntimeFacadePrivacy.modelConfigClearOperation:
            return PrivacyConfirmationLimits.modelConfigurationAction
        default:
            return nil
        }
    }

    static func isDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && value.count == 71
            && value.dropFirst(7).allSatisfy { $0.isHexDigit }
    }

    static func isValidInvocation(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return PrivacyConfirmationLimits.tokenPrefix
            + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One registered store per accepted epoch (process-lifetime, bounded).
public final class PrivacyHostConfirmationRegistry: @unchecked Sendable {
    public static let shared = PrivacyHostConfirmationRegistry()

    private let lock = NSLock()
    private var stores: [UInt64: PrivacyHostConfirmationStore] = [:]
    private var epochs: [UInt64] = []

    private init() {}

    public func register(_ store: PrivacyHostConfirmationStore) {
        lock.lock()
        stores[store.epoch] = store
        epochs.removeAll { $0 == store.epoch }
        epochs.append(store.epoch)
        while epochs.count > 4 {
            let evicted = epochs.removeFirst()
            stores[evicted] = nil
        }
        lock.unlock()
    }

    public func current(epoch: UInt64) -> PrivacyHostConfirmationStore? {
        lock.lock(); defer { lock.unlock() }
        return stores[epoch]
    }

    public func unregister(epoch: UInt64) {
        lock.lock()
        stores[epoch] = nil
        epochs.removeAll { $0 == epoch }
        lock.unlock()
    }

    public func resetForTesting() {
        lock.lock(); stores.removeAll(); epochs.removeAll(); lock.unlock()
    }
}

// MARK: - Privileged C ABI (App-process JNI only; NOT a V3 command)

private func privacyCLength(_ pointer: UnsafePointer<CChar>, maximum: Int) -> Int? {
    var length = 0
    while length <= maximum {
        if pointer[length] == 0 { return length }
        length += 1
    }
    return nil
}

private func privacyCString(_ pointer: UnsafePointer<CChar>,
                            maximum: Int) -> String? {
    guard let length = privacyCLength(pointer, maximum: maximum) else {
        return nil
    }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: length)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func privacyCopyToken(_ token: String,
                              _ outToken: UnsafeMutablePointer<CChar>?,
                              _ outCap: Int32) -> Int32 {
    guard let outToken, outCap >= Int32(PrivacyConfirmationLimits.tokenCapacity) else {
        return PrivacyConfirmationStatus.invalidArgument
    }
    let bytes = Array(token.utf8)
    guard bytes.count + 1 <= Int(outCap) else {
        return PrivacyConfirmationStatus.invalidArgument
    }
    for (index, byte) in bytes.enumerated() {
        outToken[index] = CChar(bitPattern: byte)
    }
    outToken[bytes.count] = 0
    return PrivacyConfirmationStatus.ok
}

private func privacyOwnerProof(_ epoch: Int64,
                               _ token: UnsafePointer<CChar>?) -> Bool {
    guard epoch > 0, let token,
          let value = privacyCString(token, maximum: 64) else { return false }
    guard value.count >= 8, value.count <= 64,
          value.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") })
    else { return false }
    return AndroidRuntimeBootstrap.g02OwnerProofValid(
        epoch: UInt64(epoch), token: value)
}

/// Mint ONE confirmation capability for the live accepted generation.
/// Arguments are the host epoch/token, the closed operation name, the exact
/// preview digest, the host's exact command correlation (invocation), the
/// action label and a bounded output buffer.
@_cdecl("floe_privacy_confirm_issue")
public func floePrivacyConfirmIssue(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ operation: UnsafePointer<CChar>?,
    _ previewDigest: UnsafePointer<CChar>?,
    _ invocationID: UnsafePointer<CChar>?,
    _ action: UnsafePointer<CChar>?,
    _ outToken: UnsafeMutablePointer<CChar>?,
    _ outCap: Int32
) -> Int32 {
    guard let operation, let previewDigest, let invocationID, let action,
          outCap >= Int32(PrivacyConfirmationLimits.tokenCapacity) else {
        return PrivacyConfirmationStatus.invalidArgument
    }
    guard privacyOwnerProof(ownerEpoch, ownerToken) else {
        return PrivacyConfirmationStatus.ownerProofInvalid
    }
    guard let operationValue = privacyCString(operation, maximum: 64),
          let digestValue = privacyCString(previewDigest, maximum: 80),
          let invocationValue = privacyCString(invocationID, maximum: 256),
          let actionValue = privacyCString(action, maximum: 32),
          PrivacyHostConfirmationStore.isValidOperation(operationValue),
          PrivacyHostConfirmationStore.isDigest(digestValue),
          PrivacyHostConfirmationStore.isValidInvocation(invocationValue),
          PrivacyHostConfirmationStore.expectedAction(for: operationValue)
            == actionValue else {
        return PrivacyConfirmationStatus.invalidArgument
    }
    guard let store = PrivacyHostConfirmationRegistry.shared.current(
        epoch: UInt64(ownerEpoch)) else {
        return PrivacyConfirmationStatus.notReady
    }
    guard let token = store.issue(operation: operationValue,
                                  action: actionValue,
                                  previewDigest: digestValue,
                                  invocationID: invocationValue) else {
        return PrivacyConfirmationStatus.confirmationSaturated
    }
    return privacyCopyToken(token, outToken, outCap)
}

/// Exact-token revoke. A foreign/unknown token is a typed refusal; another
/// live capability is never touched.
@_cdecl("floe_privacy_confirm_revoke")
public func floePrivacyConfirmRevoke(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ token: UnsafePointer<CChar>?
) -> Int32 {
    guard privacyOwnerProof(ownerEpoch, ownerToken) else {
        return PrivacyConfirmationStatus.ownerProofInvalid
    }
    guard let token, let value = privacyCString(
        token, maximum: PrivacyConfirmationLimits.maximumTokenCharacters),
        value.hasPrefix(PrivacyConfirmationLimits.tokenPrefix) else {
        return PrivacyConfirmationStatus.invalidArgument
    }
    guard let store = PrivacyHostConfirmationRegistry.shared.current(
        epoch: UInt64(ownerEpoch)) else {
        return PrivacyConfirmationStatus.notReady
    }
    return store.revoke(token: value)
        ? PrivacyConfirmationStatus.ok
        : PrivacyConfirmationStatus.confirmationNotFound
}

/// RootStop/epoch retirement: clears ONLY this epoch's capabilities. The
/// extension's `beginRetirement` calls the same store directly; this export
/// exists for an App-side explicit cancel path.
@_cdecl("floe_privacy_confirm_retire")
public func floePrivacyConfirmRetire(
    _ ownerEpoch: Int64,
    _ ownerToken: UnsafePointer<CChar>?
) -> Int32 {
    guard privacyOwnerProof(ownerEpoch, ownerToken) else {
        return PrivacyConfirmationStatus.ownerProofInvalid
    }
    guard let store = PrivacyHostConfirmationRegistry.shared.current(
        epoch: UInt64(ownerEpoch)) else {
        return PrivacyConfirmationStatus.notReady
    }
    store.retire()
    PrivacyHostConfirmationRegistry.shared.unregister(epoch: UInt64(ownerEpoch))
    return PrivacyConfirmationStatus.ok
}
