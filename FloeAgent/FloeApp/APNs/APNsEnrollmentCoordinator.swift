// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import UIKit

@MainActor protocol APNsEnrollmentLifecycle: AnyObject {
    var hasActiveExchange: Bool { get }
    var canAwaitTargetInBackground: Bool { get }
    var retryAfterInterruption: Date? { get }
    @discardableResult func receive(_ challenge: APNsEnrollmentChallenge) -> Bool
    @discardableResult func receive(_ challenge: APNsEnrollmentChallenge, deliveryDeadline: Date) -> Bool
    func registrationDidCommit()
    func setEvidenceChangedHandler(_ callback: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

/// One native enrollment operation, independent from scheduler ownership.
/// The service owns its worker until it really returns (including a late
/// non-cancellable Apple callback), so cancelling cannot accumulate workers.
@MainActor final class APNsEnrollmentCoordinator: APNsEnrollmentLifecycle {
    private struct NonceRequest: Encodable {
        let installationID: UUID
        let tokenSHA256: String?
        let credentialSHA256: String
        let signingEnvironment: APNsSigningEnvironment
        let channel: APNsInstallChannel
        enum CodingKeys: String, CodingKey { case installationID, tokenSHA256, credentialSHA256, signingEnvironment, channel }
        func encode(to encoder: Encoder) throws {
            var out = encoder.container(keyedBy: CodingKeys.self)
            try out.encode(installationID, forKey: .installationID)
            if let tokenSHA256 { try out.encode(tokenSHA256, forKey: .tokenSHA256) }
            else { try out.encodeNil(forKey: .tokenSHA256) }
            try out.encode(credentialSHA256, forKey: .credentialSHA256)
            try out.encode(signingEnvironment, forKey: .signingEnvironment)
            try out.encode(channel, forKey: .channel)
        }
    }
    private struct Nonce: Decodable {
        let installationID: UUID
        let tokenSHA256: String?
        let credentialSHA256: String
        let signingEnvironment: APNsSigningEnvironment
        let channel: APNsInstallChannel
        let topic: String
        let nonceID: UUID
        let nonce: String
        let expiresAt: Date
        let attestationChallenge: String
        enum CodingKeys: String, CodingKey { case installationID, tokenSHA256, credentialSHA256, signingEnvironment, channel, topic, nonceID, nonce, expiresAt, attestationChallenge }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard fields.contains(.tokenSHA256) else { throw APNsServiceError.protocolViolation }
            installationID = try fields.decode(UUID.self, forKey: .installationID)
            tokenSHA256 = try fields.decodeIfPresent(String.self, forKey: .tokenSHA256)
            credentialSHA256 = try fields.decode(String.self, forKey: .credentialSHA256)
            signingEnvironment = try fields.decode(APNsSigningEnvironment.self, forKey: .signingEnvironment)
            channel = try fields.decode(APNsInstallChannel.self, forKey: .channel)
            topic = try fields.decode(String.self, forKey: .topic)
            nonceID = try fields.decode(UUID.self, forKey: .nonceID)
            nonce = try fields.decode(String.self, forKey: .nonce)
            expiresAt = try fields.decode(Date.self, forKey: .expiresAt)
            attestationChallenge = try fields.decode(String.self, forKey: .attestationChallenge)
        }
    }
    private struct ChallengeRequest: Encodable {
        let nonceID: UUID
        let deviceToken: String?
        let proof: APNsAppAttestProof
        let signedAppTransaction: String?
        enum CodingKeys: String, CodingKey { case nonceID, deviceToken, appAttestKeyID, attestationObject, assertionObject, signedAppTransaction }
        func encode(to encoder: Encoder) throws {
            var out = encoder.container(keyedBy: CodingKeys.self)
            try out.encode(nonceID, forKey: .nonceID)
            if let deviceToken { try out.encode(deviceToken, forKey: .deviceToken) } else { try out.encodeNil(forKey: .deviceToken) }
            try out.encode(proof.keyID, forKey: .appAttestKeyID)
            if let value = proof.attestationObject { try out.encode(value.base64EncodedString(), forKey: .attestationObject) }
            if let value = proof.assertionObject { try out.encode(value.base64EncodedString(), forKey: .assertionObject) }
            if let signedAppTransaction { try out.encode(signedAppTransaction, forKey: .signedAppTransaction) }
            else { try out.encodeNil(forKey: .signedAppTransaction) }
        }
    }
    private struct Challenge: Decodable {
        let challengeID: UUID
        let nonceID: UUID
        let installationID: UUID
        let expiresAt: Date
        let status: String
    }
    private struct CompleteRequest: Encodable {
        let nonceID: UUID
        let proof: String?
        enum CodingKeys: String, CodingKey { case nonceID, proof }
        func encode(to encoder: Encoder) throws {
            var out = encoder.container(keyedBy: CodingKeys.self)
            try out.encode(nonceID, forKey: .nonceID)
            if let proof { try out.encode(proof, forKey: .proof) } else { try out.encodeNil(forKey: .proof) }
        }
    }
    private struct Voucher: Decodable { let nonceID: UUID; let voucher: String }
    private struct Operation {
        let id: UUID
        let continuation: CheckedContinuation<APNsEnrollmentProof, Error>
        let timer: Task<Void, Never>
    }
    private let http: HTTPAPNsTransport
    private let installation: any APNsInstallationProving
    private let waiter: APNsEnrollmentWaiter
    private let isForeground: @MainActor @Sendable () -> Bool
    private let exchangeSeconds: TimeInterval
    private var evidence = APNsInstallationEvidence.unknown
    private var evidenceGeneration = UUID()
    private var evidenceChanged: (@MainActor @Sendable () -> Void)?
    private var operation: Operation?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var targetWait: (operationID: UUID, lease: APNsEnrollmentWaiter.Lease)?
    private var targetProofConsumed = false
    private var backgroundDeliveryDeadline: Date?
    private(set) var retryAfterInterruption: Date?

    init(http: HTTPAPNsTransport, installation: any APNsInstallationProving,
         waiter: APNsEnrollmentWaiter = APNsEnrollmentWaiter(), exchangeSeconds: TimeInterval = 90,
         isForeground: @escaping @MainActor @Sendable () -> Bool = { UIApplication.shared.applicationState == .active }) throws {
        guard exchangeSeconds.isFinite, exchangeSeconds > 0, exchangeSeconds <= 90 else { throw APNsServiceError.unconfigured }
        self.http = http; self.installation = installation; self.waiter = waiter
        self.isForeground = isForeground; self.exchangeSeconds = exchangeSeconds
    }
    func refreshInstallationEvidence() async -> APNsInstallChannel {
        let generation = UUID(); evidenceGeneration = generation
        installation.observeEvidenceChanges { [weak self] result in
            guard let self, self.evidenceGeneration == generation else { return }
            let changed = self.evidence.channel != result.channel || self.evidence.signedAppTransaction != result.signedAppTransaction
            self.evidence = result
            if changed { self.evidenceChanged?() }
        }
        let result = await installation.evidence() // Native implementation returns its cache immediately.
        guard !Task.isCancelled, generation == evidenceGeneration else { return .unknown }
        evidence = result
        return result.channel
    }
    func proof(for request: APNsRegistrationRequest, secret: Data) async throws -> APNsEnrollmentProof {
        guard isForeground() else { throw APNsServiceError.foregroundRequired }
        guard worker == nil else { throw APNsServiceError.enrollmentPending }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.exchangeSeconds ?? 0)) } catch { return }
                    self?.end(id: id, result: .failure(APNsServiceError.enrollmentPending), cancelWorker: true)
                }
                retryAfterInterruption = nil
                operation = Operation(id: id, continuation: continuation, timer: timer)
                workerID = id
                worker = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let result = try await self.perform(request, secret: secret, id: id)
                        self.end(id: id, result: .success(result), cancelWorker: false)
                    } catch { self.end(id: id, result: .failure(error), cancelWorker: false) }
                    if self.workerID == id { self.worker = nil; self.workerID = nil }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.end(id: id, result: .failure(CancellationError()), cancelWorker: true) } }
    }
    var hasActiveExchange: Bool { operation != nil }
    var canAwaitTargetInBackground: Bool {
        guard let targetWait, operation?.id == targetWait.operationID,
              !targetProofConsumed, targetWait.lease.deadline > Date() else { return false }
        return true
    }
    @discardableResult func receive(_ challenge: APNsEnrollmentChallenge) -> Bool {
        // A direct foreground route is not a system background delivery.
        guard isForeground() else { return false }
        return accept(challenge, deliveryDeadline: nil)
    }
    @discardableResult func receive(_ challenge: APNsEnrollmentChallenge, deliveryDeadline: Date) -> Bool {
        guard deliveryDeadline > Date(), deliveryDeadline.timeIntervalSinceNow <= 20 else { return false }
        return accept(challenge, deliveryDeadline: deliveryDeadline)
    }
    private func accept(_ challenge: APNsEnrollmentChallenge, deliveryDeadline: Date?) -> Bool {
        guard canAwaitTargetInBackground, let targetWait else { return false }
        return waiter.receive(challenge) {
            if let deliveryDeadline {
                let limit = min(deliveryDeadline, challenge.expiresAt, targetWait.lease.deadline)
                self.backgroundDeliveryDeadline = min(self.backgroundDeliveryDeadline ?? limit, limit)
            }
        }
    }
    func setEvidenceChangedHandler(_ callback: @escaping @MainActor @Sendable () -> Void) { evidenceChanged = callback }
    func registrationDidCommit() { retryAfterInterruption = nil }
    func cancel() {
        evidenceGeneration = UUID()
        installation.cancelEvidenceObservation()
        if let id = operation?.id { end(id: id, result: .failure(CancellationError()), cancelWorker: true) }
        else { waiter.cancel(); worker?.cancel() }
    }
    private func current(_ id: UUID, waitingForTarget: Bool = false) throws {
        try Task.checkCancellation()
        guard operation?.id == id else { throw CancellationError() }
        if isForeground() { return }
        if let deadline = backgroundDeliveryDeadline, deadline > Date(), targetWait?.operationID == id { return }
        // Only receipt parsing/binding and an inert nonce wait may survive a
        // scene transition without an APNs delivery. Complete/PUT never do.
        if waitingForTarget, canAwaitTargetInBackground { return }
        throw APNsServiceError.foregroundRequired
    }
    private func end(id: UUID, result: Result<APNsEnrollmentProof, Error>, cancelWorker: Bool) {
        guard let value = operation, value.id == id else { return }
        operation = nil; value.timer.cancel(); waiter.cancel()
        targetWait = nil; targetProofConsumed = false; backgroundDeliveryDeadline = nil
        if cancelWorker, workerID == id { worker?.cancel() }
        value.continuation.resume(with: result)
    }
    private func perform(_ request: APNsRegistrationRequest, secret: Data, id: UUID) async throws -> APNsEnrollmentProof {
        try current(id)
        guard secret.count == 32, request.signingEnvironment != .unknown,
              !request.installed.bundleID.isEmpty else { throw APNsServiceError.unconfigured }
        let deviceToken = request.enabled ? request.deviceToken : nil
        if request.enabled {
            guard let deviceToken, deviceToken.range(of: "^[a-f0-9]{32,1024}$", options: .regularExpression) != nil,
                  deviceToken.utf8.count.isMultiple(of: 2) else { throw APNsServiceError.protocolViolation }
        }
        let signed: String?
        if request.installed.channel == .unknown || request.installed.channel == .development {
            // Unknown StoreKit/JWS is NOT a heartbeat gate. The server must
            // prohibit version reminders until a later verified channel proof.
            signed = nil
        } else {
            if evidence.channel != request.installed.channel || evidence.signedAppTransaction == nil {
                _ = await refreshInstallationEvidence()
                try current(id)
            }
            guard evidence.channel == request.installed.channel,
                  let value = evidence.signedAppTransaction, !value.isEmpty, value.utf8.count <= 32_768 else {
                throw APNsServiceError.attestationUnavailable
            }
            signed = value
        }
        let tokenHash = deviceToken.map { hex(SHA256.hash(data: Data($0.utf8))) }
        let credentialHash = hex(SHA256.hash(data: secret))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let nonceData = try await http.enrollmentRequest(.nonce, body: encoder.encode(NonceRequest(
            installationID: request.installationID, tokenSHA256: tokenHash, credentialSHA256: credentialHash,
            signingEnvironment: request.signingEnvironment, channel: request.installed.channel)), secret: nil)
        try current(id)
        let nonce = try APNsWireJSON.decode(Nonce.self, from: nonceData)
        guard nonce.installationID == request.installationID, nonce.tokenSHA256 == tokenHash,
              nonce.credentialSHA256 == credentialHash, nonce.signingEnvironment == request.signingEnvironment,
              nonce.channel == request.installed.channel, nonce.topic == request.installed.bundleID,
              nonce.expiresAt > Date(), nonce.expiresAt.timeIntervalSinceNow <= 90,
              APNsEnrollmentEncoding.decode32(nonce.nonce) != nil,
              let rawChallenge = APNsEnrollmentEncoding.decode32(nonce.attestationChallenge) else { throw APNsServiceError.protocolViolation }
        let hash = Data(SHA256.hash(data: rawChallenge))
        guard isForeground() else { throw APNsServiceError.foregroundRequired }
        var proof = try await installation.proof(installationID: request.installationID,
            clientDataHash: hash, preference: .automatic)
        try current(id)
        try validate(proof)
        // Register BEFORE the HTTP call. A private APNs proof may arrive
        // before its response, but never before its nonce/installation fence.
        let lease = try deviceToken.map { _ in try waiter.prepare(installationID: request.installationID,
            nonceID: nonce.nonceID, expiresAt: nonce.expiresAt) }
        targetWait = lease.map { (id, $0) }
        targetProofConsumed = false; backgroundDeliveryDeadline = nil
        retryAfterInterruption = nonce.expiresAt
        let challengeData: Data
        do {
            challengeData = try await http.enrollmentRequest(.challenge, body: encoder.encode(ChallengeRequest(
                nonceID: nonce.nonceID, deviceToken: deviceToken, proof: proof, signedAppTransaction: signed)), secret: secret)
        } catch let error as APNsServiceError {
            let preference: APNsAppAttestPreference
            switch error {
            case .remote(.unknownAppAttestKey):
                guard proof.assertionObject != nil else { throw APNsServiceError.protocolViolation }
                preference = .attestationAfterServerUnknown
            case .remote(.appAttestAssertionRequired):
                guard proof.attestationObject != nil else { throw APNsServiceError.protocolViolation }
                preference = .assertionRequired
            case .rateLimited: throw error
            case .http, .unavailable: throw APNsServiceError.enrollmentDeferred(until: nonce.expiresAt)
            default: throw error
            }
            try current(id)
            guard Date() < nonce.expiresAt else { throw APNsServiceError.enrollmentPending }
            // Same authenticated nonce/secret/hash, at most ONE typed mode
            // negotiation. Never regenerate the installation or replay a new
            // target challenge because of an arbitrary network/HTTP failure.
            let oldKeyID = proof.keyID
            guard isForeground() else { throw APNsServiceError.foregroundRequired }
            proof = try await installation.proof(installationID: request.installationID,
                clientDataHash: hash, preference: preference)
            try current(id)
            try validate(proof)
            if preference == .assertionRequired && proof.keyID != oldKeyID { throw APNsServiceError.protocolViolation }
            do {
                challengeData = try await http.enrollmentRequest(.challenge, body: encoder.encode(ChallengeRequest(
                    nonceID: nonce.nonceID, deviceToken: deviceToken, proof: proof, signedAppTransaction: signed)), secret: secret)
            } catch APNsServiceError.unavailable { throw APNsServiceError.enrollmentDeferred(until: nonce.expiresAt) }
              catch APNsServiceError.http { throw APNsServiceError.enrollmentDeferred(until: nonce.expiresAt) }
        }
        try current(id, waitingForTarget: true)
        let challenge = try APNsWireJSON.decode(Challenge.self, from: challengeData)
        guard challenge.nonceID == nonce.nonceID, challenge.installationID == request.installationID,
              challenge.expiresAt > Date(), challenge.expiresAt <= nonce.expiresAt,
              challenge.status == (deviceToken == nil ? "verified" : "pending") else { throw APNsServiceError.protocolViolation }
        try installation.confirm(installationID: request.installationID, keyID: proof.keyID)
        let targetProof: String?
        if let lease {
            try waiter.bind(challenge.challengeID, to: lease, expiresAt: challenge.expiresAt)
            do { targetProof = try await waiter.wait(lease) }
            catch APNsServiceError.enrollmentPending { throw APNsServiceError.enrollmentDeferred(until: nonce.expiresAt) }
            targetProofConsumed = true
            try current(id)
        } else { targetProof = nil }
        let completeBody = try encoder.encode(CompleteRequest(nonceID: nonce.nonceID, proof: targetProof))
        let data: Data
        do { data = try await http.enrollmentRequest(.complete(challenge.challengeID), body: completeBody, secret: secret) }
        catch let error as APNsServiceError {
            switch error {
            case .unavailable: break
            case .http(let status) where status >= 500: break
            default: throw error
            }
            try current(id)
            guard Date().addingTimeInterval(1) < challenge.expiresAt else {
                throw APNsServiceError.enrollmentDeferred(until: nonce.expiresAt)
            }
            try await Task.sleep(for: .seconds(1))
            try current(id)
            // Same complete request can recover a lost response under the
            // server's atomic voucher replay; no second APNs challenge/send.
            do { data = try await http.enrollmentRequest(.complete(challenge.challengeID), body: completeBody, secret: secret) }
            catch APNsServiceError.unavailable { throw APNsServiceError.enrollmentDeferred(until: nonce.expiresAt) }
              catch APNsServiceError.http { throw APNsServiceError.enrollmentDeferred(until: nonce.expiresAt) }
        }
        try current(id)
        let voucher = try APNsWireJSON.decode(Voucher.self, from: data)
        guard voucher.nonceID == nonce.nonceID, voucher.voucher.utf8.count <= 8_192,
              voucher.voucher.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw APNsServiceError.protocolViolation
        }
        return .init(nonceID: nonce.nonceID.uuidString.lowercased(), voucher: voucher.voucher)
    }
    private func validate(_ proof: APNsAppAttestProof) throws {
        let bytes = proof.attestationObject ?? proof.assertionObject
        guard !proof.keyID.isEmpty, proof.keyID.utf8.count <= 512,
              (proof.attestationObject == nil) != (proof.assertionObject == nil),
              let bytes, !bytes.isEmpty, bytes.count <= 24_576 else { throw APNsServiceError.protocolViolation }
    }
    private func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
#endif
