// FloeIOSAutomation — single-source connection status.
//
// install != pair != ready. This method never mutates Bridge state and never
// claims readiness without a real authenticated config call.

import Foundation

extension IOSBridgeClient {
    public func status() async -> IOSBridgeConnectionSnapshot {
        let now = configuration.clock.now()
        guard configuration.platformAllowsLocalAutomation else {
            return snapshot(.unsupportedPlatform, at: now)
        }
        if let phase = pairingPhase {
            switch phase {
            case .waitingForOwnerApproval:
                return snapshot(.waitingForOwnerApproval, at: now)
            case .contactingCompanion, .savingCredential, .verifyingCredential:
                return snapshot(.pairingInProgress, at: now)
            }
        }

        let info: IOSBridgeInfo
        do {
            info = try await self.info()
        } catch let error as IOSBridgeError {
            return await unavailableSnapshot(for: error, at: now)
        } catch {
            return snapshot(.serviceUnavailable, at: now, detail: "transport")
        }

        let availability = await configuration.store.availability(for: configuration.pairingHandle)
        switch availability {
        case .locked:
            return snapshot(.lockedCredentials, info: info, at: now)
        case .unavailable:
            return snapshot(.credentialsUnavailable, info: info, at: now)
        case .missing:
            return snapshot(.needsPairing, info: info, at: now)
        case .available:
            break
        }

        let credentialRevision = await credentialWriter.currentRevision()
        let record: IOSBridgePairingRecord
        do {
            record = try await loadRecord()
        } catch let error as IOSBridgeError {
            switch error {
            case .credentialStoreMissing:
                return snapshot(.needsPairing, info: info, at: now)
            case .credentialStoreLocked:
                return snapshot(.lockedCredentials, info: info, at: now)
            case .credentialStoreUnavailable:
                return snapshot(.credentialsUnavailable, info: info, at: now)
            case .credentialRecordInvalid:
                return snapshot(.pairingRecordInvalid, info: info, at: now)
            default:
                return snapshot(.credentialsUnavailable, info: info, at: now,
                                detail: error.canonicalCode)
            }
        } catch {
            return snapshot(.credentialsUnavailable, info: info, at: now)
        }

        let configSnapshot: IOSBridgeConfigurationSnapshot
        do {
            configSnapshot = try await self.configurationSnapshot(record: record)
        } catch let error as IOSBridgeError {
            if error.isAuthenticationFailure {
                let status: IOSBridgeConnectionStatus = record.isExpired(at: now)
                    ? .expired : .revoked
                return snapshot(status, info: info, at: now, detail: error.canonicalCode)
            }
            return snapshot(.serviceUnavailable, info: info, at: now, detail: error.canonicalCode)
        } catch {
            return snapshot(.serviceUnavailable, info: info, at: now)
        }

        guard let client = configSnapshot.clients.first(where: {
            $0.clientID == record.tokenID
        }) else {
            return snapshot(.revoked, info: info, at: now, detail: "client_missing")
        }
        await touchCredentialIfNeeded(record, expectedRevision: credentialRevision)

        switch configSnapshot.engineState {
        case .ready:
            return snapshot(
                .ready,
                info: info,
                configuration: configSnapshot,
                sensitiveInputGranted: client.sensitiveInputGranted,
                clientExpiresAt: client.expiresAt,
                at: now
            )
        case .notReady(let reason):
            return snapshot(
                .engineNotReady(reason: reason),
                info: info,
                configuration: configSnapshot,
                sensitiveInputGranted: client.sensitiveInputGranted,
                clientExpiresAt: client.expiresAt,
                at: now
            )
        case .notRegistered:
            return snapshot(
                .engineNotReady(reason: ""),
                info: info,
                configuration: configSnapshot,
                sensitiveInputGranted: client.sensitiveInputGranted,
                clientExpiresAt: client.expiresAt,
                at: now,
                detail: "not_registered"
            )
        case .unknown:
            return snapshot(
                .serviceUnavailable,
                info: info,
                configuration: configSnapshot,
                at: now,
                detail: "invalid_engine_state"
            )
        }
    }

    private func unavailableSnapshot(
        for error: IOSBridgeError,
        at date: Date
    ) async -> IOSBridgeConnectionSnapshot {
        switch error {
        case .incompatibleBridge(let version):
            return snapshot(.incompatibleBridge(protocolVersion: version), at: date)
        case .serviceStopping:
            return snapshot(.serviceOff, at: date, detail: error.canonicalCode)
        case .transportUnavailable, .transportNotPermitted, .timedOut, .connectionLost,
             .transportDenied:
            var presence = IOSBridgeCompanionPresence.unknown
            if let probe = configuration.companionProbe {
                presence = await probe.presence()
            }
            switch presence {
            case .installed:
                return snapshot(.serviceOff, at: date, detail: error.canonicalCode)
            case .missing:
                return snapshot(.companionMissing, at: date, detail: error.canonicalCode)
            case .unknown:
                return snapshot(.serviceUnavailable, at: date, detail: error.canonicalCode)
            }
        default:
            return snapshot(.serviceUnavailable, at: date, detail: error.canonicalCode)
        }
    }

    func snapshot(
        _ status: IOSBridgeConnectionStatus,
        info: IOSBridgeInfo? = nil,
        configuration: IOSBridgeConfigurationSnapshot? = nil,
        sensitiveInputGranted: Bool = false,
        clientExpiresAt: Date? = nil,
        at date: Date,
        detail: String? = nil
    ) -> IOSBridgeConnectionSnapshot {
        IOSBridgeConnectionSnapshot(
            status: status,
            info: info,
            configuration: configuration,
            sensitiveInputGranted: sensitiveInputGranted,
            clientExpiresAt: clientExpiresAt,
            checkedAt: date,
            detail: detail
        )
    }
}
