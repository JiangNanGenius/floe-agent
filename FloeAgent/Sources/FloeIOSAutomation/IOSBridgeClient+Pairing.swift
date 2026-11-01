// FloeIOSAutomation — owner-approved local pairing and local-only forget.

import CryptoKit
import Foundation

extension IOSBridgeClient {
    /// Performs X25519 pairing over the fixed loopback endpoint. Bridge always
    /// asks the device owner; this call simply waits for that decision. The
    /// result is returned only after the key was saved and read back.
    public func pair(
        clientName: String,
        replaceExisting: Bool = false,
        progress: @escaping @Sendable (IOSBridgePairingProgress) -> Void = { _ in }
    ) async throws -> IOSBridgePairingResult {
        guard configuration.platformAllowsLocalAutomation else {
            throw IOSBridgeError.unsupportedPlatform
        }
        let trimmedName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IOSBridgePairingRecord.isValidClientName(trimmedName) else {
            throw IOSBridgeError.invalidArguments(
                "The Bridge client name must be 1...\(IOSBridgeProtocol.clientNameMaximumBytes) printable UTF-8 bytes."
            )
        }
        guard pairingPhase == nil else {
            throw IOSBridgeError.pairingInProgress
        }
        expireDeviceInputOwnerIfNeeded(at: configuration.clock.now())
        guard activeLease == nil, deviceInputOwner == nil else {
            throw IOSBridgeError.deviceBusy
        }

        let cancellation = IOSAutomationCancellationToken()
        let startingEpoch = lifecycleEpoch
        pairingPhase = .contactingCompanion
        activePairingCancellation = cancellation
        defer {
            pairingPhase = nil
            activePairingCancellation = nil
        }

        let availability = await configuration.store.availability(for: configuration.pairingHandle)
        switch availability {
        case .locked:
            throw IOSBridgeError.credentialStoreLocked
        case .unavailable:
            throw IOSBridgeError.credentialStoreUnavailable
        case .missing, .available:
            break
        }

        // Verify the companion/protocol before asking the owner to approve a
        // key. A pair against an incompatible build must not create a record.
        let info: IOSBridgeInfo
        do {
            info = try await self.info()
        } catch let error as IOSBridgeError {
            throw error
        } catch {
            throw IOSBridgeError.transportUnavailable
        }

        let existing: IOSBridgePairingRecord?
        switch availability {
        case .available:
            do {
                existing = try await configuration.store.load(configuration.pairingHandle)
            } catch let error as IOSBridgePairingStoreError {
                switch error {
                case .missing, .corrupt:
                    existing = nil
                case .locked:
                    throw IOSBridgeError.credentialStoreLocked
                case .unavailable:
                    throw IOSBridgeError.credentialStoreUnavailable
                case .verificationFailed:
                    throw IOSBridgeError.credentialStoreVerificationFailed
                }
            } catch {
                throw IOSBridgeError.credentialStoreUnavailable
            }
        case .missing, .locked, .unavailable:
            existing = nil
        }

        if cancellation.isCancelled {
            throw IOSBridgeError.cancelled
        }
        if let existing, !existing.isExpired(at: configuration.clock.now()), !replaceExisting {
            throw IOSBridgeError.alreadyPaired
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientPublicKey = privateKey.publicKey.rawRepresentation
        let body = IOSBridgeJSONValue.object([
            "client_name": .string(trimmedName),
            "pub": .string(clientPublicKey.base64EncodedString()),
        ]).canonicalData()
        guard body.count <= IOSBridgeProtocol.maxRequestBodyBytes else {
            throw IOSBridgeError.requestTooLarge
        }

        progress(.contactingCompanion)
        pairingPhase = .waitingForOwnerApproval
        progress(.waitingForOwnerApproval)

        let response: IOSBridgeHTTPResponse
        do {
            response = try await withTaskCancellationHandler {
                try await sendHTTP(
                    IOSBridgeHTTPRequest(
                        method: "POST",
                        path: IOSBridgeProtocol.pairingPath,
                        headers: ["Content-Type": "application/json"],
                        body: body
                    ),
                    timeout: configuration.pairingTimeout,
                    cancellation: cancellation
                )
            } onCancel: {
                cancellation.cancel()
            }
        } catch let error as IOSBridgeError {
            switch error {
            case .timedOut:
                throw IOSBridgeError.pairingTimedOut
            case .transportUnavailable, .transportNotPermitted, .transportDenied:
                throw error
            case .cancelled:
                throw IOSBridgeError.cancelled
            case .responseTooLarge, .invalidResponse:
                throw IOSBridgeError.pairingResponseInvalid
            default:
                throw error
            }
        } catch {
            throw IOSBridgeError.transportUnavailable
        }

        guard lifecycleEpoch == startingEpoch else {
            throw IOSBridgeError.serviceFenced
        }
        if cancellation.isCancelled {
            throw IOSBridgeError.cancelled
        }
        if response.status != 200 {
            let document = IOSBridgeErrorDocument.decode(response.body)
            throw IOSBridgeError.fromHTTP(status: response.status, document: document)
        }
        guard response.body.count <= IOSBridgeProtocol.maxPairingResponseBytes,
              let value = try? IOSBridgeJSONValue.decode(response.body),
              let object = value.objectValue else {
            throw IOSBridgeError.pairingResponseInvalid
        }
        guard object["token"] == nil else {
            throw IOSBridgeError.pairingResponseInvalid
        }
        guard let tokenID = object["tok"]?.stringValue,
              tokenID.count == IOSBridgeEnvelope.tokenIDByteCount * 2,
              IOSBridgeEnvelope.strictHex(
                  tokenID,
                  byteCount: IOSBridgeEnvelope.tokenIDByteCount
              ) != nil,
              let returnedName = object["client_name"]?.stringValue,
              returnedName == trimmedName,
              let expiresSeconds = object["expires"]?.intValue,
              let devicePublicBase64 = object["pub"]?.stringValue,
              let devicePublicKey = Data(base64Encoded: devicePublicBase64, options: []),
              devicePublicKey.count == 32,
              devicePublicKey.base64EncodedString() == devicePublicBase64,
              let tokenCiphertextHex = object["token_ct"]?.stringValue,
              let tokenCiphertext = IOSBridgeEnvelope.strictHex(
                  tokenCiphertextHex,
                  byteCount: IOSBridgeEnvelope.keyByteCount
              ) else {
            throw IOSBridgeError.pairingResponseInvalid
        }
        let now = configuration.clock.now()
        guard expiresSeconds > Int(now.timeIntervalSince1970) else {
            throw IOSBridgeError.pairingResponseInvalid
        }
        let devicePublic: Curve25519.KeyAgreement.PublicKey
        let shared: SharedSecret
        do {
            devicePublic = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: devicePublicKey
            )
            shared = try privateKey.sharedSecretFromKeyAgreement(with: devicePublic)
        } catch {
            throw IOSBridgeError.pairingResponseInvalid
        }
        let sharedData = shared.withUnsafeBytes { Data($0) }
        guard let key = IOSBridgeEnvelope.unwrapKey(
            tokenCiphertext: tokenCiphertext,
            sharedSecret: sharedData,
            clientPublicKey: clientPublicKey,
            devicePublicKey: devicePublicKey
        ), key.count == IOSBridgeEnvelope.keyByteCount,
           IOSBridgeEnvelope.tokenID(for: key) == tokenID else {
            throw IOSBridgeError.pairingResponseInvalid
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresSeconds))
        let record: IOSBridgePairingRecord
        do {
            record = try IOSBridgePairingRecord(
                tokenID: tokenID,
                clientName: trimmedName,
                grantedAt: now,
                lastVerifiedAt: now,
                expiresAt: expiresAt,
                protocolVersion: info.protocolVersion,
                keyMaterial: key
            )
        } catch {
            throw IOSBridgeError.pairingResponseInvalid
        }

        progress(.savingCredential)
        pairingPhase = .savingCredential
        do {
            try await credentialWriter.savePairing(
                record,
                handle: configuration.pairingHandle,
                store: configuration.store
            )
        } catch let error as IOSBridgePairingStoreError {
            throw Self.mapStoreError(error)
        } catch {
            throw IOSBridgeError.credentialStoreUnavailable
        }

        progress(.verifyingCredential)
        pairingPhase = .verifyingCredential
        do {
            let loaded = try await configuration.store.load(configuration.pairingHandle)
            guard loaded.tokenID == record.tokenID,
                  loaded.matchesKey(in: record),
                  loaded.protocolVersion == record.protocolVersion else {
                throw IOSBridgeError.credentialStoreVerificationFailed
            }
        } catch let error as IOSBridgeError {
            if let existing {
                await credentialWriter.restorePairing(
                    existing,
                    handle: configuration.pairingHandle,
                    store: configuration.store
                )
            } else {
                try? await credentialWriter.deletePairing(
                    handle: configuration.pairingHandle,
                    store: configuration.store
                )
            }
            throw error
        } catch let error as IOSBridgePairingStoreError {
            if let existing {
                await credentialWriter.restorePairing(
                    existing,
                    handle: configuration.pairingHandle,
                    store: configuration.store
                )
            } else {
                try? await credentialWriter.deletePairing(
                    handle: configuration.pairingHandle,
                    store: configuration.store
                )
            }
            throw Self.mapStoreError(error)
        } catch {
            throw IOSBridgeError.credentialStoreVerificationFailed
        }

        lastCredentialTouch = now
        progress(.paired(expiresAt: expiresAt))
        return IOSBridgePairingResult(
            clientName: trimmedName,
            tokenID: tokenID,
            expiresAt: expiresAt,
            replacedExisting: existing != nil
        )
    }

    public func cancelPairing() {
        activePairingCancellation?.cancel()
    }

    /// Removes only Floe's saved local credential. It never calls Bridge to
    /// revoke the server-side client grant and never claims that it did.
    public func forgetLocalPairing() async throws -> IOSBridgeForgetResult {
        guard pairingPhase == nil else {
            throw IOSBridgeError.pairingInProgress
        }
        expireDeviceInputOwnerIfNeeded(at: configuration.clock.now())
        guard activeLease == nil, deviceInputOwner == nil else {
            throw IOSBridgeError.deviceBusy
        }
        let availability = await configuration.store.availability(for: configuration.pairingHandle)
        switch availability {
        case .locked:
            throw IOSBridgeError.credentialStoreLocked
        case .unavailable:
            throw IOSBridgeError.credentialStoreUnavailable
        case .missing:
            return IOSBridgeForgetResult(handleWasPresent: false)
        case .available:
            break
        }
        do {
            try await credentialWriter.deletePairing(
                handle: configuration.pairingHandle,
                store: configuration.store
            )
        } catch let error as IOSBridgePairingStoreError {
            switch error {
            case .missing:
                return IOSBridgeForgetResult(handleWasPresent: false)
            default:
                throw Self.mapStoreError(error)
            }
        } catch {
            throw IOSBridgeError.credentialStoreUnavailable
        }
        let after = await configuration.store.availability(for: configuration.pairingHandle)
        guard after == .missing else {
            throw IOSBridgeError.credentialStoreVerificationFailed
        }
        lastCredentialTouch = nil
        return IOSBridgeForgetResult(handleWasPresent: true)
    }
}
