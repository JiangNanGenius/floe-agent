// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import DeviceCheck
import FloeSecurity

enum APNsAppAttestPreference: Sendable, Equatable { case automatic, attestationAfterServerUnknown, assertionRequired }
enum APNsNativeAttestFailure: Error { case invalidKey }

/// Internal native provenance, never encoded into HTTP or exposed as connection state.
struct APNsNativeKeyRecovery: Sendable, Equatable {
    enum Reason: Sendable, Equatable { case unusableNativeKey, serverUnknownAttestedKey }
    let previousKeyID: String
    let reason: Reason
}

struct APNsAppAttestProof: Sendable {
    let keyID: String
    let attestationObject: Data?
    let assertionObject: Data?
    var nativeKeyRecovery: APNsNativeKeyRecovery? = nil
}

/// Native-only dependency. A provider/model cannot supply a claimed verified
/// flag, AppTransaction JWS, key identifier or attestation object.
@MainActor protocol APNsInstallationProving: AnyObject {
    func evidence() async -> APNsInstallationEvidence
    func observeEvidenceChanges(_ callback: @escaping @MainActor @Sendable (APNsInstallationEvidence) -> Void)
    func cancelEvidenceObservation()
    func proof(installationID: UUID, clientDataHash: Data, preference: APNsAppAttestPreference) async throws -> APNsAppAttestProof
    func confirm(installationID: UUID, keyID: String) throws
}

extension APNsInstallationProving {
    func observeEvidenceChanges(_ callback: @escaping @MainActor @Sendable (APNsInstallationEvidence) -> Void) {}
    func cancelEvidenceObservation() {}
}

/// Small native-call seam. Production always uses DeviceCheck; isolated
/// contracts can hold a callback without generating an Apple key.
@MainActor struct APNsAppAttestOperations {
    var isSupported: @MainActor @Sendable () -> Bool
    var generateKey: @MainActor @Sendable () async throws -> String
    var object: @MainActor @Sendable (String, Data, Bool) async throws -> Data
    static var live: Self {
        .init(isSupported: { DCAppAttestService.shared.isSupported },
            generateKey: { try await APNsNativeInstallationProofs.generateKeyLive() },
            object: { key, hash, asserting in try await APNsNativeInstallationProofs.nativeObjectLive(key, hash: hash, asserting: asserting) })
    }
}

@MainActor final class APNsNativeInstallationProofs: APNsInstallationProving {
    private struct KeyRecord: Codable {
        var id: String
        var confirmed: Bool
        /// Native attestation success is not a server receipt. Optional keeps
        /// legacy key records readable; it only chooses the next proof API.
        var attested: Bool? = nil
    }
    private var cachedAttestation: (keyID: String, hash: Data, object: Data)?
    private let vault: KeychainStore
    private let native: APNsAppAttestOperations
    private var nativeOperationActive = false
    // The coordinator may negotiate a second proof on the SAME challenge.
    // One generation budget includes bootstrap and any later negotiation.
    private var keyGenerationAttempt: (installationID: UUID, hash: Data)?
    init(vault: KeychainStore = KeychainStore(service: "org.floeagent.ios.push-installation",
         synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly),
         native: APNsAppAttestOperations = .live) {
        self.vault = vault; self.native = native
    }
    func evidence() async -> APNsInstallationEvidence { await APNsInstallChannelDetector.evidence() }
    func observeEvidenceChanges(_ callback: @escaping @MainActor @Sendable (APNsInstallationEvidence) -> Void) {
        APNsInstallChannelDetector.observe(owner: self, onChange: callback)
    }
    func cancelEvidenceObservation() { APNsInstallChannelDetector.cancelObservation(owner: self) }

    func proof(installationID: UUID, clientDataHash: Data, preference: APNsAppAttestPreference) async throws -> APNsAppAttestProof {
        guard !nativeOperationActive else { throw APNsServiceError.enrollmentPending }
        nativeOperationActive = true
        defer { nativeOperationActive = false }
        try Task.checkCancellation()
        let generationID = UUID()
        guard clientDataHash.count == 32 else { throw APNsServiceError.invalidPayload }
        guard native.isSupported() else {
            throw APNsServiceError.nativeVerification(.init(stage: .availability, code: .unsupported))
        }
        let account = installationID.uuidString.lowercased() + "/app-attest-key"
        var key: KeyRecord
        var loadedExistingKey = true
        do {
            let bytes = try vault.read(account: account)
            guard bytes.count <= 2_048 else { throw APNsServiceError.storage }
            key = try JSONDecoder().decode(KeyRecord.self, from: bytes)
        } catch KeychainStoreError.itemNotFound {
            loadedExistingKey = false
            guard keyGenerationAttempt?.installationID != installationID || keyGenerationAttempt?.hash != clientDataHash else {
                throw APNsServiceError.enrollmentPending
            }
            keyGenerationAttempt = (installationID, clientDataHash)
            let id = try await native.generateKey()
            // The actual successful callback owns an otherwise unrecoverable
            // key ID. Retain it BEFORE honoring cancellation, without doing
            // any attestation/HTTP or changing installation credentials.
            key = try retainGeneratedKey(id, account: account, expectedID: nil, generationID: generationID)
            try Task.checkCancellation()
        }
        guard !key.id.isEmpty, key.id.utf8.count <= 512 else { throw APNsServiceError.storage }
        try Task.checkCancellation()
        if let cached = cachedAttestation, cached.keyID != key.id || cached.hash != clientDataHash {
            cachedAttestation = nil
        }
        let reuseAttestation = preference != .assertionRequired && !key.confirmed
            && cachedAttestation?.keyID == key.id && cachedAttestation?.hash == clientDataHash
        var asserting = preference == .assertionRequired
            || (preference == .automatic && (key.confirmed || key.attested == true) && !reuseAttestation)
        var object: Data?
        var recovery: APNsNativeKeyRecovery?
        if !asserting, let cached = cachedAttestation, cached.keyID == key.id, cached.hash == clientDataHash {
            object = cached.object
        } else {
            do { object = try await self.object(key.id, hash: clientDataHash, asserting: asserting) }
            catch APNsNativeAttestFailure.invalidKey {
                try Task.checkCancellation()
                guard loadedExistingKey else {
                    throw APNsServiceError.nativeVerification(.init(
                        stage: asserting ? .assertion : .attestation, code: .invalidKey))
                }
                var reason: APNsNativeKeyRecovery.Reason?
                if preference == .automatic, !asserting, !key.confirmed, key.attested != true {
                    // A legacy record may represent an already-attested key.
                    // A successful SAME-key assertion distinguishes that from
                    // a key Apple can no longer use. No HTTP proof is invented.
                    do {
                        object = try await self.object(key.id, hash: clientDataHash, asserting: true)
                        asserting = true
                    } catch APNsNativeAttestFailure.invalidKey {
                        try Task.checkCancellation()
                        reason = .unusableNativeKey
                    }
                } else if asserting {
                    // Includes confirmed/attested keys and the server's
                    // assertionRequired negotiation. Typed invalidKey only.
                    reason = .unusableNativeKey
                } else if preference == .attestationAfterServerUnknown, case nil = cachedAttestation {
                    reason = .serverUnknownAttestedKey
                } else {
                    throw APNsServiceError.nativeVerification(.init(stage: .attestation, code: .invalidKey))
                }
                if let reason {
                    try Task.checkCancellation()
                    guard loadedExistingKey,
                          keyGenerationAttempt?.installationID != installationID || keyGenerationAttempt?.hash != clientDataHash else {
                        throw APNsServiceError.nativeVerification(.init(
                            stage: reason == .unusableNativeKey ? .assertion : .attestation, code: .invalidKey))
                    }
                    // Mark the budget BEFORE the native call, even if it fails.
                    keyGenerationAttempt = (installationID, clientDataHash)
                    let previousID = key.id
                    let id = try await native.generateKey()
                    guard id != previousID else { throw APNsServiceError.storage }
                    key = try retainGeneratedKey(id, account: account, expectedID: previousID, generationID: generationID)
                    try Task.checkCancellation()
                    // Outside the original catch: a new-key error never loops.
                    do { object = try await self.object(key.id, hash: clientDataHash, asserting: false) }
                    catch APNsNativeAttestFailure.invalidKey {
                        throw APNsServiceError.nativeVerification(.init(stage: .attestation, code: .invalidKey))
                    }
                    asserting = false
                    recovery = .init(previousKeyID: previousID, reason: reason)
                }
            }
            if !asserting, let object { cachedAttestation = (key.id, clientDataHash, object) }
        }
        guard let object, !object.isEmpty, object.count <= 24_576 else {
            throw APNsServiceError.nativeVerification(.init(
                stage: asserting ? .assertion : .attestation, code: .invalidResult))
        }
        // Successful attestation OR assertion establishes native state only.
        // Keep the irreversible success before honoring cancellation.
        let stored = try vault.read(account: account)
        guard stored.count <= 2_048 else { throw APNsServiceError.storage }
        var latest = try JSONDecoder().decode(KeyRecord.self, from: stored)
        guard latest.id == key.id else { throw APNsServiceError.storage }
        if latest.attested != true {
            latest.attested = true
            try vault.store(account: account, secret: JSONEncoder().encode(latest))
        }

        try Task.checkCancellation()
        return .init(keyID: key.id, attestationObject: asserting ? nil : object,
            assertionObject: asserting ? object : nil, nativeKeyRecovery: recovery)
    }
    private func object(_ keyID: String, hash: Data, asserting: Bool) async throws -> Data {
        do { return try await native.object(keyID, hash, asserting) }
        catch let failure as APNsServiceError {
            guard !asserting, case .nativeVerification(let detail) = failure,
                  detail.stage == .attestation, detail.code == .serverUnavailable else { throw failure }
            // Apple prescribes the SAME key and clientDataHash on this
            // specific transient response. One retry, fenced by cancellation.
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            return try await native.object(keyID, hash, asserting)
        }
    }
    /// MainActor serializes all native owners. The synchronous read/commit
    /// fence never overwrites a newer active ID. A rare conflicting success
    /// is still retained under this exact generation's recovery account.
    private func retainGeneratedKey(_ id: String, account: String, expectedID: String?, generationID: UUID) throws -> KeyRecord {
        guard !id.isEmpty, id.utf8.count <= 512 else { throw APNsServiceError.storage }
        let generated = KeyRecord(id: id, confirmed: false)
        let bytes = try JSONEncoder().encode(generated)
        let recoveryAccount = account + "/generated-" + generationID.uuidString.lowercased()
        try vault.store(account: recoveryAccount, secret: bytes)
        let latest: KeyRecord?
        do {
            let stored = try vault.read(account: account)
            guard stored.count <= 2_048 else { throw APNsServiceError.storage }
            latest = try JSONDecoder().decode(KeyRecord.self, from: stored)
        } catch KeychainStoreError.itemNotFound { latest = nil }
        if latest?.id == expectedID {
            try vault.store(account: account, secret: bytes)
            // The canonical slot now retains this exact successful ID. A
            // cleanup failure leaves an extra recovery reference, not loss.
            try? vault.delete(account: recoveryAccount)
            return generated
        }
        guard let latest else { throw APNsServiceError.storage }
        return latest
    }

    fileprivate static func generateKeyLive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { id, error in
                guard let id else {
                    continuation.resume(throwing: APNsServiceError.nativeVerification(
                        .init(stage: .generation, code: nativeCode(error)))); return
                }
                continuation.resume(returning: id)
            }
        }
    }
    fileprivate static func nativeObjectLive(_ keyID: String, hash: Data, asserting: Bool) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let completion: (Data?, Error?) -> Void = { data, error in
                if let error = error as? DCError, error.code == .invalidKey {
                    continuation.resume(throwing: APNsNativeAttestFailure.invalidKey); return
                }
                if let error {
                    continuation.resume(throwing: APNsServiceError.nativeVerification(
                        .init(stage: asserting ? .assertion : .attestation, code: nativeCode(error)))); return
                }
                guard let data, !data.isEmpty, data.count <= 24_576 else {
                    continuation.resume(throwing: APNsServiceError.nativeVerification(
                        .init(stage: asserting ? .assertion : .attestation, code: .invalidResult))); return
                }
                continuation.resume(returning: data)
            }
            if asserting { DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash, completionHandler: completion) }
            else { DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash, completionHandler: completion) }
        }
    }
    private nonisolated static func nativeCode(_ error: Error?) -> APNsNativeProofDiagnostic.Code {
        guard let error = error as? DCError else { return .unknown }
        switch error.code {
        case .featureUnsupported: return .unsupported
        case .invalidInput: return .invalidInput
        case .invalidKey: return .invalidKey
        case .serverUnavailable: return .serverUnavailable
        default: return .unknown
        }
    }
    func confirm(installationID: UUID, keyID: String) throws {
        try Task.checkCancellation()
        let account = installationID.uuidString.lowercased() + "/app-attest-key"
        let bytes = try vault.read(account: account)
        guard bytes.count <= 2_048 else { throw APNsServiceError.storage }
        var key = try JSONDecoder().decode(KeyRecord.self, from: bytes)
        guard key.id == keyID else { throw APNsServiceError.protocolViolation }
        if !key.confirmed { key.confirmed = true; try vault.store(account: account, secret: JSONEncoder().encode(key)) }
    }
}
#endif
