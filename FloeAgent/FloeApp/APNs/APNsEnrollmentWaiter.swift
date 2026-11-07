// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreFoundation

/// Independent protocol. Enrollment proof never becomes a task payload,
/// heartbeat, release record, persistent dedupe entry or model-visible value.
struct APNsEnrollmentChallenge: Sendable {
    let eventID: UUID
    let installationID: UUID
    let nonceID: UUID
    let challengeID: UUID
    let sentAt: Date
    let expiresAt: Date
    let proof: String
}

nonisolated enum APNsEnrollmentChallengeDecoder {
    static func decode(userInfo: [AnyHashable: Any], now: Date = Date()) throws -> APNsEnrollmentChallenge {
        guard userInfo.count == 2, userInfo.keys.allSatisfy({ ($0 as? String).map { ["aps", "floe"].contains($0) } == true }),
              JSONSerialization.isValidJSONObject(userInfo),
              (try JSONSerialization.data(withJSONObject: userInfo)).count <= 4_096,
              let aps = userInfo["aps"] as? [String: Any], aps.count == 1,
              let silent = aps["content-available"] as? NSNumber,
              CFGetTypeID(silent) != CFBooleanGetTypeID(), silent.doubleValue == 1,
              let body = userInfo["floe"] as? [String: Any],
              Set(body.keys) == Set(["schemaVersion", "kind", "eventID", "installationID", "nonceID", "challengeID", "sentAt", "expiresAt", "proof"]),
              let version = body["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              body["kind"] as? String == "enrollmentChallenge",
              let eventID = uuid(body["eventID"]), let installationID = uuid(body["installationID"]),
              let nonceID = uuid(body["nonceID"]), let challengeID = uuid(body["challengeID"]),
              let sentAt = date(body["sentAt"]), let expiresAt = date(body["expiresAt"]),
              sentAt <= now.addingTimeInterval(60), expiresAt > now, expiresAt > sentAt,
              expiresAt.timeIntervalSince(sentAt) <= 90,
              let proof = body["proof"] as? String, APNsEnrollmentEncoding.decode32(proof) != nil else {
            throw APNsServiceError.invalidPayload
        }
        return .init(eventID: eventID, installationID: installationID, nonceID: nonceID,
            challengeID: challengeID, sentAt: sentAt, expiresAt: expiresAt, proof: proof)
    }
    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String, value.utf8.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

nonisolated enum APNsEnrollmentEncoding {
    static func decode32(_ raw: String) -> Data? {
        guard raw.utf8.count == 43, raw.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let bytes = Data(base64Encoded: raw.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32,
              encode(bytes) == raw else { return nil }
        return bytes
    }
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One active nonce, no disk storage. Prepares BEFORE POST /challenges so an
/// APNs proof that races its HTTP response is retained and cross-checked.
@MainActor final class APNsEnrollmentWaiter {
    struct Lease: Sendable { let id: UUID; let installationID: UUID; let nonceID: UUID; let deadline: Date }
    private struct Pending {
        let lease: Lease
        var challengeID: UUID?
        var challengeExpiresAt: Date?
        var early: [APNsEnrollmentChallenge] = [] // <=4 tiny, nonce-bound arrivals.
        var continuation: CheckedContinuation<String, Error>?
        var expiry: Task<Void, Never>?
    }
    private var pending: Pending?

    func prepare(installationID: UUID, nonceID: UUID, expiresAt: Date) throws -> Lease {
        guard expiresAt.timeIntervalSinceNow > 0, expiresAt.timeIntervalSinceNow <= 90 else {
            throw APNsServiceError.stalePayload
        }
        cancel()
        let lease = Lease(id: UUID(), installationID: installationID, nonceID: nonceID, deadline: expiresAt)
        pending = Pending(lease: lease)
        pending?.expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow))) }
            catch { return }
            self?.cancel(id: lease.id, error: APNsServiceError.enrollmentPending)
        }
        return lease
    }
    func bind(_ challengeID: UUID, to lease: Lease, expiresAt: Date) throws {
        guard var value = pending, value.lease.id == lease.id,
              Date() < value.lease.deadline, expiresAt > Date(), expiresAt <= lease.deadline else {
            throw APNsServiceError.stalePayload
        }
        if let bound = value.challengeID, bound != challengeID { throw APNsServiceError.protocolViolation }
        value.challengeID = challengeID
        value.challengeExpiresAt = expiresAt
        value.expiry?.cancel()
        value.expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow))) }
            catch { return }
            self?.cancel(id: lease.id, error: APNsServiceError.enrollmentPending)
        }
        value.early.removeAll { $0.challengeID != challengeID || $0.expiresAt > expiresAt }
        pending = value
        finishIfReady()
    }
    @discardableResult func receive(_ challenge: APNsEnrollmentChallenge, beforeResume: () -> Void = {}) -> Bool {
        guard var value = pending, Date() < value.lease.deadline,
              challenge.installationID == value.lease.installationID, challenge.nonceID == value.lease.nonceID,
              challenge.expiresAt > Date(), challenge.expiresAt <= (value.challengeExpiresAt ?? value.lease.deadline),
              challenge.sentAt <= Date().addingTimeInterval(60),
              APNsEnrollmentEncoding.decode32(challenge.proof) != nil,
              value.challengeID == nil || value.challengeID == challenge.challengeID else { return false }
        guard !value.early.contains(where: { $0.eventID == challenge.eventID }) else { return false }
        if value.early.count == 4 { value.early.removeFirst() }
        // The exact matched delivery may bind a finite system budget before
        // the suspended original worker is resumed. Rejected input cannot.
        beforeResume()
        value.early.append(challenge); pending = value
        finishIfReady()
        return true
    }
    func wait(_ lease: Lease) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard var value = pending, value.lease.id == lease.id, Date() < value.lease.deadline,
                      value.continuation == nil else { continuation.resume(throwing: APNsServiceError.stalePayload); return }
                value.continuation = continuation; pending = value; finishIfReady()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id: lease.id) } }
    }
    func cancel(id: UUID? = nil, error: Error = CancellationError()) {
        guard let value = pending, id == nil || value.lease.id == id else { return }
        pending = nil; value.expiry?.cancel(); value.continuation?.resume(throwing: error)
    }
    private func finishIfReady() {
        guard let value = pending, Date() < (value.challengeExpiresAt ?? value.lease.deadline), let challengeID = value.challengeID,
              let continuation = value.continuation,
              let proof = value.early.last(where: { $0.challengeID == challengeID && $0.expiresAt > Date() })?.proof else { return }
        pending = nil; value.expiry?.cancel(); continuation.resume(returning: proof)
    }
}
#endif
