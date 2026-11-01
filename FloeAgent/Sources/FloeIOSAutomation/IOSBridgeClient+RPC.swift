// FloeIOSAutomation — internal HTTP / RPC plumbing.

import Foundation

extension IOSBridgeClient {
    func sendHTTP(
        _ request: IOSBridgeHTTPRequest,
        timeout: TimeInterval,
        cancellation: IOSAutomationCancellationToken?
    ) async throws -> IOSBridgeHTTPResponse {
        if cancellation?.isCancelled == true {
            throw IOSBridgeError.cancelled
        }
        do {
            return try await configuration.transport.send(
                request,
                endpoint: configuration.endpoint,
                timeout: timeout,
                cancellation: cancellation
            )
        } catch let error as IOSBridgeTransportError {
            throw Self.mapTransportError(error)
        } catch is CancellationError {
            throw IOSBridgeError.cancelled
        } catch {
            throw IOSBridgeError.unexpected("The local Bridge transport failed.")
        }
    }

    func loadRecord() async throws -> IOSBridgePairingRecord {
        let availability = await configuration.store.availability(for: configuration.pairingHandle)
        switch availability {
        case .locked:
            throw IOSBridgeError.credentialStoreLocked
        case .unavailable:
            throw IOSBridgeError.credentialStoreUnavailable
        case .missing:
            throw IOSBridgeError.credentialStoreMissing
        case .available:
            break
        }
        do {
            return try await configuration.store.load(configuration.pairingHandle)
        } catch let error as IOSBridgePairingStoreError {
            throw Self.mapStoreError(error)
        } catch let error as IOSBridgeError {
            throw error
        } catch {
            throw IOSBridgeError.credentialStoreUnavailable
        }
    }

    func info(timeout: TimeInterval? = nil) async throws -> IOSBridgeInfo {
        let response = try await sendHTTP(
            IOSBridgeHTTPRequest(method: "GET", path: IOSBridgeProtocol.infoPath),
            timeout: timeout ?? configuration.statusTimeout,
            cancellation: nil
        )
        guard response.status == 200 else {
            throw IOSBridgeError.fromHTTP(
                status: response.status,
                document: IOSBridgeErrorDocument.decode(response.body)
            )
        }
        guard response.body.count <= IOSBridgeProtocol.maxStatusResponseBytes,
              let value = try? IOSBridgeJSONValue.decode(response.body),
              let info = IOSBridgeInfo.parse(value) else {
            throw IOSBridgeError.invalidResponse
        }
        guard info.protocolVersion == IOSBridgeProtocol.protocolVersion else {
            throw IOSBridgeError.incompatibleBridge(protocolVersion: info.protocolVersion)
        }
        return info
    }

    func configurationSnapshot(
        record: IOSBridgePairingRecord,
        timeout: TimeInterval? = nil
    ) async throws -> IOSBridgeConfigurationSnapshot {
        let value = try await sendRPC(
            record: record,
            method: IOSAutomationAction.config.wireMethod,
            params: .object([:]),
            timeout: timeout ?? configuration.rpcTimeout,
            cancellation: nil,
            operationID: nil,
            requestID: "status-\(UUID().uuidString.lowercased())"
        )
        guard let snapshot = IOSBridgeConfigurationSnapshot.parse(value) else {
            throw IOSBridgeError.invalidResponse
        }
        return snapshot
    }

    func sendRPC(
        record: IOSBridgePairingRecord,
        method: String,
        params: IOSBridgeJSONValue?,
        timeout: TimeInterval,
        cancellation: IOSAutomationCancellationToken?,
        operationID: String?,
        requestID: String
    ) async throws -> IOSBridgeJSONValue {
        if let operationID, !IOSBridgeOperationID.isCanonical(operationID) {
            throw IOSBridgeError.invalidArguments("The operation identifier is not canonical.")
        }
        if let params, params.objectValue == nil {
            throw IOSBridgeError.invalidArguments("Bridge params must be a JSON object.")
        }
        if cancellation?.isCancelled == true {
            throw IOSBridgeError.cancelled
        }
        let now = configuration.clock.now()
        let timestamp = Int(now.timeIntervalSince1970)
        guard timestamp >= 0 else {
            throw IOSBridgeError.invalidArguments("The device clock is invalid.")
        }
        let nonce: Data
        do {
            nonce = try configuration.randomness.bytes(IOSBridgeEnvelope.nonceByteCount)
        } catch {
            throw IOSBridgeError.unexpected("The system random source is unavailable.")
        }
        guard nonce.count == IOSBridgeEnvelope.nonceByteCount else {
            throw IOSBridgeError.unexpected("The system random source returned a short nonce.")
        }

        var requestObject: [String: IOSBridgeJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params ?? .object([:]),
            "id": .string(requestID),
        ]
        if let operationID {
            requestObject["operation_id"] = .string(operationID)
        }
        let plaintext = IOSBridgeJSONValue.object(requestObject).canonicalData()
        let envelope: IOSBridgeJSONValue
        do {
            envelope = try IOSBridgeEnvelope.sealRequest(
                plaintext,
                key: record.keyMaterial,
                nonce: nonce,
                timestamp: timestamp
            )
        } catch let failure as IOSBridgeEnvelope.Failure {
            throw IOSBridgeError.invalidRequest(failure.message)
        }
        let body = envelope.canonicalData()
        guard body.count <= IOSBridgeProtocol.maxRequestBodyBytes else {
            throw IOSBridgeError.requestTooLarge
        }

        let response = try await sendHTTP(
            IOSBridgeHTTPRequest(
                method: "POST",
                path: IOSBridgeProtocol.requestPath,
                headers: [
                    "Content-Type": "application/json",
                    "Cache-Control": "no-store",
                ],
                body: body
            ),
            timeout: timeout,
            cancellation: cancellation
        )

        if response.status != 200 {
            let error = IOSBridgeError.fromHTTP(
                status: response.status,
                document: IOSBridgeErrorDocument.decode(response.body)
            )
            switch error {
            case .authFailed, .authRequired:
                if record.isExpired(at: configuration.clock.now()) {
                    throw IOSBridgeError.pairingExpired
                }
                throw IOSBridgeError.pairingRevoked
            default:
                throw error
            }
        }
        guard response.body.count <= IOSBridgeProtocol.maxJSONResponseBytes else {
            throw IOSBridgeError.responseTooLarge
        }
        guard let responseEnvelope = try? IOSBridgeJSONValue.decode(response.body) else {
            throw IOSBridgeError.invalidResponse
        }
        let opened: Data
        do {
            opened = try IOSBridgeEnvelope.openResponse(
                responseEnvelope,
                key: record.keyMaterial,
                expectedNonceHex: IOSBridgeEnvelope.hexLowercase(nonce)
            )
        } catch {
            throw IOSBridgeError.invalidResponse
        }
        guard let responseValue = try? IOSBridgeJSONValue.decode(opened),
              let responseObject = responseValue.objectValue,
              responseObject["jsonrpc"]?.stringValue == "2.0" else {
            throw IOSBridgeError.invalidResponse
        }
        let responseID = responseObject["id"]
        if let responseID, !responseID.isNull, responseID != .string(requestID) {
            throw IOSBridgeError.invalidResponse
        }
        if let errorObject = responseObject["error"]?.objectValue {
            guard let code = errorObject["code"]?.intValue else {
                throw IOSBridgeError.invalidResponse
            }
            let message = errorObject["message"]?.stringValue ?? "Bridge returned a JSON-RPC error."
            let data = errorObject["data"]?.objectValue
            throw IOSBridgeError.fromJSONRPC(code: code, message: message, data: data)
        }
        guard let result = responseObject["result"] else {
            throw IOSBridgeError.invalidResponse
        }
        return result
    }

    /// Best-effort expiry refresh. The revision guard prevents a status/action
    /// refresh from overwriting a newer pairing saved while it was in flight.
    func touchCredentialIfNeeded(
        _ record: IOSBridgePairingRecord,
        expectedRevision: UInt64
    ) async {
        let now = configuration.clock.now()
        if let last = lastCredentialTouch,
           now.timeIntervalSince(last) < configuration.credentialTouchInterval {
            return
        }
        guard let updated = try? IOSBridgePairingRecord(
            tokenID: record.tokenID,
            clientName: record.clientName,
            grantedAt: record.grantedAt,
            lastVerifiedAt: now,
            expiresAt: max(record.expiresAt, now.addingTimeInterval(30 * 24 * 60 * 60)),
            protocolVersion: record.protocolVersion,
            keyMaterial: record.keyMaterial
        ) else {
            return
        }
        if await credentialWriter.touch(
            updated,
            expectedRevision: expectedRevision,
            handle: configuration.pairingHandle,
            store: configuration.store
        ) {
            lastCredentialTouch = now
        }
    }

    static func mapStoreError(_ error: IOSBridgePairingStoreError) -> IOSBridgeError {
        switch error {
        case .locked: return .credentialStoreLocked
        case .missing: return .credentialStoreMissing
        case .unavailable: return .credentialStoreUnavailable
        case .corrupt: return .credentialRecordInvalid
        case .verificationFailed: return .credentialStoreVerificationFailed
        }
    }

    static func mapTransportError(_ error: IOSBridgeTransportError) -> IOSBridgeError {
        switch error {
        case .invalidEndpoint:
            return .invalidEndpoint
        case .invalidRequest(let message):
            return .invalidRequest(message)
        case .requestTooLarge:
            return .requestTooLarge
        case .responseTooLarge:
            return .responseTooLarge
        case .unreachable:
            return .transportUnavailable
        case .transportNotPermitted:
            return .transportNotPermitted
        case .timedOut:
            return .timedOut
        case .connectionLost:
            return .connectionLost
        case .cancelled:
            return .cancelled
        case .redirectRefused:
            return .invalidResponse
        case .invalidResponse:
            return .invalidResponse
        }
    }
}
