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
struct HTTPAPNsTransport: APNsEnrollmentTransport, APNsReleaseResolving {
    let baseURL: URL
    private let session: URLSession
    private let enrollmentProof: APNsEnrollmentProofProvider?
    init(baseURL: URL, enrollmentProof: APNsEnrollmentProofProvider? = nil) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw APNsServiceError.unconfigured
        }
        self.baseURL = baseURL
        self.enrollmentProof = enrollmentProof
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        session = URLSession(configuration: configuration, delegate: APNsRedirectGuard(origin: baseURL), delegateQueue: nil)
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
        catch APNsServiceError.http(401) {
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
        let receipt = try APNsWireJSON.decoder().decode(APNsRegistrationReceipt.self, from: result)
        guard receipt.installationID == body.installationID, receipt.acceptedRevision == body.revision,
              receipt.enabled == body.enabled, receipt.leaseExpiresAt > receipt.acceptedAt,
              receipt.leaseExpiresAt.timeIntervalSince(receipt.acceptedAt) <= 90 * 86_400 else {
            throw APNsServiceError.protocolViolation
        }
        return receipt
    }
    func release(id: String, channel: APNsInstallChannel) async throws -> APNsReleaseRecord {
        guard id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              channel == .appStore || channel == .testFlight else { throw APNsServiceError.invalidPayload }
        var components = URLComponents(url: baseURL.appendingPathComponent("releases").appendingPathComponent(id), resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "channel", value: channel.rawValue)]
        guard let url = components?.url else { throw APNsServiceError.invalidPayload }
        let data = try await bytes(URLRequest(url: url))
        let release = try APNsWireJSON.decoder().decode(APNsReleaseRecord.self, from: data)
        guard release.id == id, release.channel == channel, release.isInstallable,
              !release.version.isEmpty, !release.build.isEmpty, release.version.utf8.count <= 80,
              release.build.utf8.count <= 80, release.title.utf8.count <= 1_024,
              release.notes.utf8.count <= 48_000, release.availableAt <= Date().addingTimeInterval(60) else {
            throw APNsServiceError.protocolViolation
        }
        return release
    }
    private func bytes(_ request: URLRequest) async throws -> Data {
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw APNsServiceError.protocolViolation }
            guard (200..<300).contains(http.statusCode) else { throw APNsServiceError.http(http.statusCode) }
            guard response.expectedContentLength <= 65_536 else { throw APNsServiceError.protocolViolation }
            var data = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < 65_536 else { throw APNsServiceError.protocolViolation }
                data.append(byte)
            }
            return data
        } catch let error as APNsServiceError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw APNsServiceError.unavailable }
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

private enum APNsWireJSON {
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
