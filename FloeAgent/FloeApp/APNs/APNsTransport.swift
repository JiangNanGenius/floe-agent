// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

struct APNsEnrollmentProof: Sendable {
    let nonceID: String
    let voucher: String
}
typealias APNsEnrollmentProofProvider = @Sendable (APNsRegistrationRequest, Data) async throws -> APNsEnrollmentProof

/// First-party wire adapter, configured only by the native service graph.
/// There is deliberately no default URL or model-supplied service endpoint.
struct HTTPAPNsTransport: APNsEnrollmentTransport, APNsReleaseHistoryResolving {
    let baseURL: URL
    private let session: URLSession
    private var enrollmentProof: APNsEnrollmentProofProvider?
    private let backoff = APNsHTTPBackoff()
    init(baseURL: URL, enrollmentProof: APNsEnrollmentProofProvider? = nil,
         sessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw APNsServiceError.unconfigured
        }
        self.baseURL = baseURL
        self.enrollmentProof = enrollmentProof
        guard let configuration = sessionConfiguration.copy() as? URLSessionConfiguration else {
            throw APNsServiceError.unconfigured
        }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        session = URLSession(configuration: configuration, delegate: APNsRedirectGuard(origin: baseURL), delegateQueue: nil)
    }
    /// Retains the SAME bounded session, origin redirect policy and cooldown.
    /// Only the native service graph can install this provider.
    func withEnrollmentProof(_ provider: @escaping APNsEnrollmentProofProvider) -> Self {
        var result = self
        result.enrollmentProof = provider
        return result
    }
    enum EnrollmentEndpoint: Sendable {
        case nonce, challenge, complete(UUID)
        var components: [String] {
            switch self {
            case .nonce: ["enrollment", "nonces"]
            case .challenge: ["enrollment", "challenges"]
            case .complete(let id): ["enrollment", "challenges", id.uuidString.lowercased(), "complete"]
            }
        }
    }
    func enrollmentRequest(_ endpoint: EnrollmentEndpoint, body: Data, secret: Data?) async throws -> Data {
        guard body.count <= 65_536 else { throw APNsServiceError.protocolViolation }
        var url = baseURL
        for component in endpoint.components { url.appendPathComponent(component) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret {
            guard secret.count == 32 else { throw APNsServiceError.storage }
            request.setValue("Bearer " + secret.base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        return try await bytes(request)
    }

    func apply(_ body: APNsRegistrationRequest, installationSecret: Data) async throws -> APNsRegistrationReceipt {
        guard installationSecret.count == 32 else { throw APNsServiceError.storage }
        var request = URLRequest(url: baseURL.appendingPathComponent("installations").appendingPathComponent(body.installationID.uuidString.lowercased()))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + installationSecret.base64EncodedString(), forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        let result: Data
        do { result = try await bytes(request) }
        catch APNsServiceError.remote(.enrollmentProofRequired) {
            guard let enrollmentProof else { throw APNsServiceError.unconfigured }
            let proof = try await enrollmentProof(body, installationSecret)
            try Task.checkCancellation()
            guard UUID(uuidString: proof.nonceID) != nil, proof.voucher.utf8.count <= 8_192,
                  proof.voucher.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw APNsServiceError.protocolViolation
            }
            request.setValue(proof.nonceID, forHTTPHeaderField: "X-Floe-Enrollment-Nonce")
            request.setValue(proof.voucher, forHTTPHeaderField: "X-Floe-Enrollment-Proof")
            result = try await bytes(request)
        }
        let receipt = try APNsWireJSON.decode(APNsRegistrationReceipt.self, from: result)
        guard receipt.installationID == body.installationID, receipt.acceptedRevision == body.revision,
              receipt.enabled == body.enabled, receipt.leaseExpiresAt > receipt.acceptedAt,
              receipt.leaseExpiresAt.timeIntervalSince(receipt.acceptedAt) <= 90 * 86_400 else {
            throw APNsServiceError.protocolViolation
        }
        return receipt
    }
    func release(id: String, channel: APNsInstallChannel) async throws -> APNsReleaseRecord {
        try await readRelease(id: id, channel: channel, history: false)
    }
    func releaseHistory(id: String, channel: APNsInstallChannel) async throws -> APNsReleaseRecord {
        try await readRelease(id: id, channel: channel, history: true)
    }
    private func readRelease(id: String, channel: APNsInstallChannel, history: Bool) async throws -> APNsReleaseRecord {
        guard id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              channel == .appStore || channel == .testFlight else { throw APNsServiceError.invalidPayload }
        var components = URLComponents(url: baseURL.appendingPathComponent(history ? "release-history" : "releases").appendingPathComponent(id), resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "channel", value: channel.rawValue)]
        guard let url = components?.url else { throw APNsServiceError.invalidPayload }
        let data = try await bytes(URLRequest(url: url))
        let release = try APNsWireJSON.decode(APNsReleaseRecord.self, from: data)
        guard release.id == id, release.channel == channel, release.isInstallable == !history,
              !release.version.isEmpty, !release.build.isEmpty, release.version.utf8.count <= 80,
              release.build.utf8.count <= 80, release.title.utf8.count <= 1_024,
              release.notes.utf8.count <= 48_000, release.availableAt <= Date().addingTimeInterval(60) else {
            throw APNsServiceError.protocolViolation
        }
        return release
    }
    private func bytes(_ request: URLRequest) async throws -> Data {
        do {
            try Task.checkCancellation()
            if let retryAt = await backoff.nextAttempt(), retryAt > Date() {
                throw APNsServiceError.rateLimited(until: retryAt)
            }
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw APNsServiceError.protocolViolation }
            if http.statusCode == 429 {
                let retryAt = APNsRetryAfter.date(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
                await backoff.deferUntil(retryAt)
                throw APNsServiceError.rateLimited(until: retryAt)
            }
            guard response.expectedContentLength <= 65_536 else { throw APNsServiceError.protocolViolation }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < 65_536 else { throw APNsServiceError.protocolViolation }
                data.append(byte)
            }
            if !(200..<300).contains(http.statusCode) {
                // Parse only the closed machine-code envelope, never retain
                // or display server bodies. Every other 401/409 is terminal
                // and cannot trigger proof, token renewal or a new UUID.
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object.count == 1, let code = object["error"] as? String,
                   let failure = APNsRemoteFailure(rawValue: code), failure.status == http.statusCode {
                    throw APNsServiceError.remote(failure)
                }
                throw APNsServiceError.http(http.statusCode)
            }
            return data
        } catch let error as APNsServiceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw APNsServiceError.unavailable }
    }
}

private actor APNsHTTPBackoff {
    private var retryAt: Date?
    func nextAttempt() -> Date? { retryAt }
    func deferUntil(_ date: Date) { retryAt = max(retryAt ?? .distantPast, date) }
}

nonisolated enum APNsRetryAfter {
    static func date(_ header: String?, now: Date) -> Date {
        // No in-call sleep or compensating retry. Missing/invalid values get
        // a conservative one-minute cooldown; valid origin headers retain
        // their actual later time (no artificial shortening to wake budget).
        guard let raw = header, raw.utf8.count <= 128 else { return now.addingTimeInterval(60) }
        if raw.range(of: "^[0-9]{1,10}$", options: .regularExpression) != nil,
           let seconds = UInt32(raw) { return now.addingTimeInterval(TimeInterval(seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        if let date = formatter.date(from: raw), formatter.string(from: date) == raw { return max(now, date) }
        return now.addingTimeInterval(60)
    }
}

private final class APNsRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == origin.scheme, url.host == origin.host,
              url.port == origin.port, url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum APNsWireJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder().decode(type, from: data) }
        catch { throw APNsServiceError.protocolViolation }
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer(), raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else { throw APNsServiceError.protocolViolation }
            return date
        }
        return decoder
    }
}
#endif
