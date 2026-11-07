// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

private final class APNsHTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let data: Data }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var handlers: [String: @Sendable (URLRequest) -> Reply] = [:]
        func handler(_ host: String) -> (@Sendable (URLRequest) -> Reply)? { lock.withLock { handlers[host] } }
        func set(_ host: String, _ handler: (@Sendable (URLRequest) -> Reply)?) { lock.withLock { handlers[host] = handler } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host.map { state.handler($0) != nil } ?? false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.state.handler(host) else { return }
        let reply = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("APNs real HTTP error and proof exchange contracts", .serialized)
struct APNsHTTPContractTests {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock(); private var value = 0
        func increment() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }
    private func request() -> APNsRegistrationRequest {
        .init(installationID: UUID(), revision: 7, enabled: true, versionReminders: false,
            hasEligibleSchedules: false, visibleAuthorization: .denied, backgroundRefreshAvailable: true,
            installed: .init(version: "1.0", build: "7", channel: .development, bundleID: "org.floeagent.ios"),
            signingEnvironment: .development, deviceToken: String(repeating: "ab", count: 32))
    }
    private func transport(_ handler: @escaping @Sendable (URLRequest) -> APNsHTTPFixtureProtocol.Reply,
                           proof: APNsEnrollmentProofProvider? = nil) throws -> (HTTPAPNsTransport, String) {
        let host = "apns-\(UUID().uuidString.lowercased()).invalid"
        APNsHTTPFixtureProtocol.state.set(host, handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APNsHTTPFixtureProtocol.self]
        return (try HTTPAPNsTransport(baseURL: URL(string: "https://\(host)/api/v1/push")!,
            enrollmentProof: proof, sessionConfiguration: configuration), host)
    }
    @Test("Only enrollmentProofRequired invokes the trusted provider; invalid authorization and an unknown 401 do not")
    func typedUnauthorizedDoesNotEnrollArbitrarily() async throws {
        for code in ["invalidAuthorization", "unknownError"] {
            let counter = Counter(), request = request()
            let (transport, host) = try transport({ _ in
                .init(status: 401, data: Data("{\"error\":\"\(code)\"}".utf8))
            }, proof: { _, _ in
                _ = counter.increment()
                return .init(nonceID: UUID().uuidString, voucher: "AA.BB")
            })
            defer { APNsHTTPFixtureProtocol.state.set(host, nil) }
            do {
                _ = try await transport.apply(request, installationSecret: Data(repeating: 0x61, count: 32))
                Issue.record("Unauthorized response was accepted")
            } catch APNsServiceError.remote(.invalidAuthorization) { #expect(code == "invalidAuthorization") }
              catch APNsServiceError.http(401) { #expect(code == "unknownError") }
            #expect(counter.count == 0)
        }
    }
    @Test("An authenticated nonce/voucher exchange replays the identical PUT once and validates its receipt")
    func proofRequiredHasOneBoundedReplay() async throws {
        let counter = Counter(), proofCount = Counter(), request = request(), nonce = UUID().uuidString
        let receipt = APNsRegistrationReceipt(installationID: request.installationID, acceptedRevision: request.revision,
            enabled: true, acceptedAt: Date(), leaseExpiresAt: Date().addingTimeInterval(300))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(receipt)
        let (transport, host) = try transport({ call in
            if counter.increment() == 1 { return .init(status: 401, data: Data(#"{"error":"enrollmentProofRequired"}"#.utf8)) }
            guard call.value(forHTTPHeaderField: "X-Floe-Enrollment-Nonce") == nonce,
                  call.value(forHTTPHeaderField: "X-Floe-Enrollment-Proof") == "AA.BB" else {
                return .init(status: 401, data: Data(#"{"error":"enrollmentProofMismatch"}"#.utf8))
            }
            return .init(status: 200, data: encoded)
        }, proof: { body, secret in
            #expect(body.installationID == request.installationID && body.revision == request.revision)
            #expect(secret == Data(repeating: 0x61, count: 32))
            _ = proofCount.increment()
            return .init(nonceID: nonce, voucher: "AA.BB")
        })
        defer { APNsHTTPFixtureProtocol.state.set(host, nil) }
        let accepted = try await transport.apply(request, installationSecret: Data(repeating: 0x61, count: 32))
        #expect(accepted.acceptedRevision == request.revision)
        #expect(counter.count == 2 && proofCount.count == 1)
    }
    @Test("Only status 409 plus tokenNeedsRenewal starts the renewal lifecycle")
    func renewalRequiresExactStatusAndCode() async throws {
        for status in [401, 409] {
            let request = request()
            let (transport, host) = try transport({ _ in
                .init(status: status, data: Data(#"{"error":"tokenNeedsRenewal"}"#.utf8))
            })
            defer { APNsHTTPFixtureProtocol.state.set(host, nil) }
            do {
                _ = try await transport.apply(request, installationSecret: Data(repeating: 0x61, count: 32))
                Issue.record("Renewal response was accepted as a receipt")
            } catch APNsServiceError.remote(.tokenNeedsRenewal) { #expect(status == 409) }
              catch APNsServiceError.http(401) { #expect(status == 401) }
        }
    }
}
#endif
