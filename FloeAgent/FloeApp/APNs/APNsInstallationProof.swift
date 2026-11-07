// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import DeviceCheck
import FloeSecurity

enum APNsAppAttestPreference: Sendable, Equatable { case automatic, attestationAfterServerUnknown, assertionRequired }
enum APNsNativeAttestFailure: Error { case invalidKey }

struct APNsAppAttestProof: Sendable {
    let keyID: String
    let attestationObject: Data?
    let assertionObject: Data?
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
    private struct KeyRecord: Codable { var id: String; var confirmed: Bool }
    private var cachedAttestation: (keyID: String, hash: Data, object: Data)?
    private let vault: KeychainStore
    private let native: APNsAppAttestOperations
    private var nativeOperationActive = false
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
        guard clientDataHash.count == 32, native.isSupported() else {
            throw APNsServiceError.attestationUnavailable
        }
        let account = installationID.uuidString.lowercased() + "/app-attest-key"
        var key: KeyRecord
        do {
            let bytes = try vault.read(account: account)
            guard bytes.count <= 2_048 else { throw APNsServiceError.storage }
            key = try JSONDecoder().decode(KeyRecord.self, from: bytes)
        } catch KeychainStoreError.itemNotFound {
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
        let asserting = preference == .assertionRequired || (preference == .automatic && key.confirmed)
        let object: Data
        if !asserting, let cached = cachedAttestation, cached.keyID == key.id, cached.hash == clientDataHash {
            object = cached.object
        } else {
            do { object = try await native.object(key.id, clientDataHash, asserting) }
            catch APNsNativeAttestFailure.invalidKey {
                // Only a server-authenticated unknown-key reply permits this
                // bounded recovery, and only after Apple also says invalidKey.
                // Network/503/unknown errors never cause key generation.
                guard preference == .attestationAfterServerUnknown, case nil = cachedAttestation else {
                    throw APNsServiceError.attestationUnavailable
                }
                let id = try await native.generateKey()
                key = try retainGeneratedKey(id, account: account, expectedID: key.id, generationID: generationID)
                try Task.checkCancellation()
                object = try await native.object(key.id, clientDataHash, false)
            }
            if !asserting { cachedAttestation = (key.id, clientDataHash, object) }
        }
        try Task.checkCancellation()
        return .init(keyID: key.id, attestationObject: asserting ? nil : object,
            assertionObject: asserting ? object : nil)
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
            DCAppAttestService.shared.generateKey { id, _ in
                guard let id else { continuation.resume(throwing: APNsServiceError.attestationUnavailable); return }
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
                guard let data, !data.isEmpty, data.count <= 24_576 else {
                    continuation.resume(throwing: APNsServiceError.attestationUnavailable); return
                }
                continuation.resume(returning: data)
            }
            if asserting { DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: hash, completionHandler: completion) }
            else { DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash, completionHandler: completion) }
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
