// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import Testing
import UIKit
import Security
import FloeSecurity
@testable import FloeApp

/// URLProtocol intercepts all owned .invalid fixtures even after teardown;
/// a late task fails closed and can never fall through to a real endpoint.
private nonisolated final class APNsEnrollmentFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var data: Data; var headers: [String: String] = [:] }
    final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var handlers: [String: @Sendable (URLRequest) async -> Reply] = [:]
        func get(_ host: String) -> (@Sendable (URLRequest) async -> Reply)? { lock.withLock { handlers[host] } }
        func set(_ host: String, _ handler: (@Sendable (URLRequest) async -> Reply)?) { lock.withLock { handlers[host] = handler } }
    }
    static let registry = Registry()
    private let lock = NSLock()
    private var work: Task<Void, Never>?
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map { $0.hasPrefix("apns-enroll-") && $0.hasSuffix(".invalid") } ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let handler = Self.registry.get(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        let fixtureRequest = request
        let task = Task { @Sendable [self, fixtureRequest, handler] in
            let reply = await handler(fixtureRequest)
            guard !Task.isCancelled, !lock.withLock({ stopped }), let url = fixtureRequest.url,
                  let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                    headerFields: reply.headers.merging(["Content-Type": "application/json"]) { a, _ in a }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        let cancelled = lock.withLock { work = task; return stopped }
        if cancelled { task.cancel() }
    }
    override func stopLoading() { let task = lock.withLock { stopped = true; return work }; task?.cancel() }
}

@Suite("APNs native enrollment wire and finite delivery", .serialized)
@MainActor struct APNsEnrollmentContractTests {
    private typealias Reply = APNsEnrollmentFixtureProtocol.Reply
    private final class Credentials: APNsCredentials, @unchecked Sendable {
        let bytes = Data(repeating: 0x33, count: 32)
        func secret(installationID: UUID, create: Bool) throws -> Data? { bytes }
        func token(installationID: UUID) throws -> Data? { Data(repeating: 0xab, count: 32) }
        func saveToken(_ token: Data, installationID: UUID) throws {}
    }
    @MainActor private final class Installation: APNsInstallationProving {
        var hashes: [Data] = [], preferences: [APNsAppAttestPreference] = []
        var confirmations = 0, initialAssertion = false
        var failure: APNsServiceError?
        var proofForegroundStates: [Bool] = []
        var isForeground: @MainActor () -> Bool = { true }
        func evidence() async -> APNsInstallationEvidence { .unknown }
        func proof(installationID: UUID, clientDataHash: Data, preference: APNsAppAttestPreference) async throws -> APNsAppAttestProof {
            hashes.append(clientDataHash); preferences.append(preference)
            if let failure { throw failure }
            proofForegroundStates.append(isForeground())
            let asserting = preference == .assertionRequired || (preference == .automatic && initialAssertion)
            return .init(keyID: "synthetic-native-key", attestationObject: asserting ? nil : Data([1, 2, 3, 4]),
                assertionObject: asserting ? Data([5, 6, 7, 8]) : nil)
        }
        func confirm(installationID: UUID, keyID: String) throws { confirmations += 1 }
    }
    @MainActor private final class Server {
        let installationID: UUID
        var topic = "org.floeagent.ios"
        let nonceID = UUID(), challengeID = UUID()
        let secret = Data(repeating: 0x33, count: 32)
        let rawChallenge = Data(0..<32)
        let proof = APNsEnrollmentEncoding.encode(Data(32..<64))
        let expires = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 60)
        var nonceCalls = 0, challengeCalls = 0, completeCalls = 0, putCalls = 0, privateTargetSends = 0, historyCalls = 0
        var initialKeyError: APNsRemoteFailure?
        var challengeUnavailable = false, completeFailureOnce = false, blockComplete = false, rateLimit = false
        var completeBodies: [Data] = []
        var challengeProofBodies: [[String: Any]] = []
        var completeGate: CheckedContinuation<Reply, Never>?
        var onTarget: (([AnyHashable: Any]) -> Void)?
        var nonceSawExplicitNull = false, challengeSawExplicitNullJWS = false
        var nullableTarget = false
        init(_ installationID: UUID = UUID()) { self.installationID = installationID }
        private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
        private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        private func json(_ value: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            .init(status: status, data: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), headers: headers)
        }
        func payload() -> [AnyHashable: Any] {
            ["aps": ["content-available": 1], "floe": ["schemaVersion": 1, "kind": "enrollmentChallenge",
                "eventID": UUID().uuidString, "installationID": installationID.uuidString,
                "nonceID": nonceID.uuidString, "challengeID": challengeID.uuidString,
                "sentAt": iso(Date()), "expiresAt": iso(expires), "proof": proof]]
        }
        func body(_ request: URLRequest) -> Data {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open(); defer { stream.close() }
            var result = Data(), bytes = [UInt8](repeating: 0, count: 1_024)
            while result.count <= 65_536 {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }; result.append(contentsOf: bytes.prefix(n))
            }
            return result
        }
        func handle(_ request: URLRequest) async -> Reply {
            let path = request.url?.path ?? "", bytes = body(request)
            let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
            if path.contains("/installations/") {
                putCalls += 1
                if rateLimit { return json(["error": "rateLimited"], status: 429, headers: ["Retry-After": "3600"]) }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret.base64EncodedString() else {
                    return json(["error": "invalidAuthorization"], status: 401)
                }
                guard request.value(forHTTPHeaderField: "X-Floe-Enrollment-Proof") == "AA.BB" else {
                    return json(["error": "enrollmentProofRequired"], status: 401)
                }
                return json(["installationID": installationID.uuidString, "acceptedRevision": object["revision"] ?? 0,
                    "enabled": object["enabled"] ?? false, "acceptedAt": iso(Date()), "leaseExpiresAt": iso(Date().addingTimeInterval(300))])
            }
            if path.hasSuffix("/enrollment/nonces") {
                nonceCalls += 1
                nullableTarget = object["tokenSHA256"] is NSNull
                nonceSawExplicitNull = object["tokenSHA256"] is NSNull
                return json(["installationID": installationID.uuidString, "tokenSHA256": object["tokenSHA256"] ?? "MISSING",
                    "credentialSHA256": digest(secret), "signingEnvironment": "production", "channel": "unknown",
                    "topic": topic, "nonceID": nonceID.uuidString,
                    "nonce": APNsEnrollmentEncoding.encode(Data(96..<128)), "expiresAt": iso(expires),
                    "attestationChallenge": APNsEnrollmentEncoding.encode(rawChallenge)])
            }
            if path.hasSuffix("/enrollment/challenges") {
                challengeCalls += 1
                challengeProofBodies.append(object)
                challengeSawExplicitNullJWS = object["signedAppTransaction"] is NSNull
                guard object["nonceID"] as? String == nonceID.uuidString,
                      request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret.base64EncodedString() else {
                    return json(["error": "invalidAuthorization"], status: 401)
                }
                if let error = initialKeyError, challengeCalls == 1 { return json(["error": error.rawValue], status: 409) }
                if challengeUnavailable { return json(["error": "pushUnavailable"], status: 503) }
                if nullableTarget {
                    guard object["deviceToken"] is NSNull else { return json(["error": "invalidAppProof"], status: 422) }
                } else {
                    guard object["deviceToken"] as? String == String(repeating: "ab", count: 32) else {
                        return json(["error": "invalidAppProof"], status: 422)
                    }
                    privateTargetSends += 1
                    onTarget?(payload()) // Arrives before the HTTP response.
                }
                return json(["challengeID": challengeID.uuidString, "nonceID": nonceID.uuidString,
                    "installationID": installationID.uuidString, "expiresAt": iso(expires), "status": nullableTarget ? "verified" : "pending"])
            }
            if path.hasSuffix("/complete") {
                completeCalls += 1; completeBodies.append(bytes)
                guard nullableTarget ? object["proof"] is NSNull : object["proof"] as? String == proof else {
                    return json(["error": "enrollmentProofMismatch"], status: 401)
                }
                if completeFailureOnce && completeCalls == 1 { return json(["error": "pushUnavailable"], status: 503) }
                if blockComplete { return await withCheckedContinuation { completeGate = $0 } }
                return json(["nonceID": nonceID.uuidString, "voucher": "AA.BB"])
            }
            if path.contains("/release-history/") {
                historyCalls += 1
                return json(["id": "old-public", "channel": "testFlight", "version": "1.0", "build": "1",
                    "title": "Previously public fixture", "notes": "Original public notes", "isInstallable": false, "availableAt": iso(Date().addingTimeInterval(-300))])
            }
            return json(["error": "notFound"], status: 404)
        }
        func releaseComplete() {
            let value = completeGate; completeGate = nil
            value?.resume(returning: json(["nonceID": nonceID.uuidString, "voucher": "AA.BB"]))
        }
    }
    private func http(_ server: Server) throws -> (HTTPAPNsTransport, String) {
        let host = "apns-enroll-\(UUID().uuidString.lowercased()).invalid"
        APNsEnrollmentFixtureProtocol.registry.set(host) { request in await server.handle(request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APNsEnrollmentFixtureProtocol.self]
        return (try HTTPAPNsTransport(baseURL: URL(string: "https://\(host)/api/v1/push")!, sessionConfiguration: configuration), host)
    }
    private func request(_ server: Server, enabled: Bool = true) -> APNsRegistrationRequest {
        .init(installationID: server.installationID, revision: 7, enabled: enabled, versionReminders: true,
            hasEligibleSchedules: enabled, visibleAuthorization: .authorized, backgroundRefreshAvailable: true,
            installed: .init(version: "1.0", build: "7", channel: .unknown, bundleID: server.topic),
            signingEnvironment: .production, deviceToken: enabled ? String(repeating: "ab", count: 32) : nil)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "Bounded fixture transition did not settle")
    }

    @Test("Raw-byte hashing, strict payload and early target delivery use only the exact in-memory nonce")
    func strictWaiterAndEarlyProof() async throws {
        let server = Server(), waiter = APNsEnrollmentWaiter()
        let payload = server.payload()
        #expect(throws: APNsServiceError.self) { _ = try APNsPayloadDecoder.decode(userInfo: payload) }
        let challenge = try APNsEnrollmentChallengeDecoder.decode(userInfo: payload)
        let lease = try waiter.prepare(installationID: server.installationID, nonceID: server.nonceID, expiresAt: server.expires)
        #expect(waiter.receive(challenge))
        try waiter.bind(server.challengeID, to: lease, expiresAt: server.expires)
        #expect(try await waiter.wait(lease) == server.proof)
        #expect(!waiter.receive(challenge))
        let other = try waiter.prepare(installationID: UUID(), nonceID: UUID(), expiresAt: server.expires)
        #expect(!waiter.receive(challenge))
        waiter.cancel(id: other.id)
        do { _ = try await waiter.wait(other); Issue.record("Cancelled proof lease was reused") }
        catch APNsServiceError.stalePayload {}
        var invalid = payload
        var body = try #require(invalid["floe"] as? [String: Any]); body["proof"] = server.proof + "="; invalid["floe"] = body
        #expect(throws: APNsServiceError.self) { _ = try APNsEnrollmentChallengeDecoder.decode(userInfo: invalid) }
    }

    @Test("Actual HTTP first enrollment uses decoded AppAttest challenge bytes, private APNs proof and original PUT; unknown JWS is null")
    func originalHTTPChainAndUnknownChannel() async throws {
        let server = Server(), installation = Installation()
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
        server.onTarget = { payload in
            #expect(enrollment.receive(try! APNsEnrollmentChallengeDecoder.decode(userInfo: payload)))
        }
        let transport = http.withEnrollmentProof { body, secret in try await enrollment.proof(for: body, secret: secret) }
        let receipt = try await transport.apply(request(server), installationSecret: server.secret)
        #expect(receipt.installationID == server.installationID && receipt.acceptedRevision == 7 && receipt.enabled)
        #expect(installation.hashes == [Data(SHA256.hash(data: server.rawChallenge))])
        #expect(server.challengeSawExplicitNullJWS && server.privateTargetSends == 1)
        #expect(server.nonceCalls == 1 && server.challengeCalls == 1 && server.completeCalls == 1 && server.putCalls == 2)
    }

    @Test("Unknown key and known-key assertion-required replies negotiate once on the SAME nonce/secret")
    func exactTypedKeyNegotiation() async throws {
        for error in [APNsRemoteFailure.unknownAppAttestKey, .appAttestAssertionRequired] {
            let server = Server(), installation = Installation(); server.initialKeyError = error
            installation.initialAssertion = error == .unknownAppAttestKey
            let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
            let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
            server.onTarget = { payload in _ = enrollment.receive(try! APNsEnrollmentChallengeDecoder.decode(userInfo: payload)) }
            let value = try await enrollment.proof(for: request(server), secret: server.secret)
            #expect(value.nonceID == server.nonceID.uuidString.lowercased())
            #expect(installation.preferences == [.automatic, error == .unknownAppAttestKey ? .attestationAfterServerUnknown : .assertionRequired])
            #expect(installation.hashes.count == 2 && installation.hashes[0] == installation.hashes[1])
            #expect(server.nonceCalls == 1 && server.challengeCalls == 2 && server.privateTargetSends == 1)
        }
    }

    @Test("A disabled null-target exchange sends explicit nulls and never emits a private target push")
    func disabledTargetIsNotAnEnabledVoucher() async throws {
        let server = Server(), installation = Installation()
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
        _ = try await enrollment.proof(for: request(server, enabled: false), secret: server.secret)
        #expect(server.nonceSawExplicitNull && server.challengeSawExplicitNullJWS)
        #expect(server.privateTargetSends == 0 && server.completeCalls == 1)
    }

    @Test("A lost complete response retries the identical complete only; unknown challenge503 never generates another key/target")
    func lostCompleteAndUnknownChallengeAreBounded() async throws {
        for failChallenge in [false, true] {
            let server = Server(), installation = Installation()
            server.completeFailureOnce = !failChallenge; server.challengeUnavailable = failChallenge
            let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
            let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
            server.onTarget = { payload in _ = enrollment.receive(try! APNsEnrollmentChallengeDecoder.decode(userInfo: payload)) }
            do {
                _ = try await enrollment.proof(for: request(server), secret: server.secret)
                #expect(!failChallenge)
            } catch APNsServiceError.enrollmentDeferred { #expect(failChallenge) }
            #expect(server.nonceCalls == 1 && server.challengeCalls == 1 && installation.preferences == [.automatic])
            if !failChallenge { #expect(server.completeBodies.count == 2 && server.completeBodies[0] == server.completeBodies[1]) }
        }
    }

    private func platform(channel: APNsInstallChannel = .unknown) -> APNsPlatform {
        .init(authorization: { .authorized }, requestVisibleAuthorization: { Issue.record("Enrollment requested an alert permission") },
            register: {}, unregister: {}, backgroundRefreshAvailable: { true }, installChannel: { channel }, isForeground: { true })
    }
    private func center(_ server: Server, http: HTTPAPNsTransport, enrollment: APNsEnrollmentCoordinator?,
                        directory: URL, isForeground: @escaping @MainActor @Sendable () -> Bool = { true },
                        wake: @escaping APNsCenter.Wake) throws -> APNsCenter {
        let store = try APNsStateStore(directory: directory)
        var initial = APNsPersistentState(); initial.installationID = server.installationID
        initial.preferences.enabled = true; initial.preferences.versionReminders = true
        try store.save(initial)
        server.topic = Bundle.main.bundleIdentifier ?? "org.floeagent.ios"
        let transport = enrollment.map { enrollment in http.withEnrollmentProof { body, secret in
            try await enrollment.proof(for: body, secret: secret)
        } }
        var nativePlatform = platform(); nativePlatform.isForeground = isForeground
        return APNsCenter(store: store, signingEnvironment: .production, transport: transport, releaseLookup: http,
            credentials: Credentials(), platform: nativePlatform, enrollment: enrollment,
            eligibility: { .init(hasEnabledSchedule: true, hasProgressableExecution: false) }, performWake: wake)
    }

    @Test("Background enrollment intake completes only after original complete+PUT receipt and never invokes task wake")
    func intakeJoinsActualRegistration() async throws {
        let server = Server(), installation = Installation()
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil); server.onTarget = nil }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-enrollment-intake-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var wakes = 0, results: [UIBackgroundFetchResult.RawValue] = []
        let center = try center(server, http: http, enrollment: enrollment, directory: directory) { _ in wakes += 1; return .newData }
        server.onTarget = { payload in
            #expect(APNsNotificationIntake.background(userInfo: payload, center: { center }) { result in
                Task { @MainActor in results.append(result.rawValue) }
            })
        }
        await center.reload()
        try await wait { !results.isEmpty }
        #expect(results == [UIBackgroundFetchResult.newData.rawValue])
        #expect(center.status().serverConnected && server.putCalls == 2 && server.completeCalls == 1)
        #expect(wakes == 0 && center.state.lastWakeOutcome == nil && center.state.seen.isEmpty)
    }

    @Test("The background deadline cancels only its original exchange; late complete cannot write a receipt or run tasks")
    func deadlineDoesNotOutliveSystemCallback() async throws {
        let server = Server(), installation = Installation(); server.blockComplete = true
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil); server.onTarget = nil }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-enrollment-deadline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var wakes = 0, result: APNsEnrollmentDeliveryResult?
        let center = try center(server, http: http, enrollment: enrollment, directory: directory) { _ in wakes += 1; return .newData }
        defer { center.applicationStateChanged(isForeground: false); server.releaseComplete() }
        server.onTarget = { payload in
            let challenge = try! APNsEnrollmentChallengeDecoder.decode(userInfo: payload)
            Task { @MainActor in result = await center.receiveEnrollmentChallenge(challenge, deadline: Date().addingTimeInterval(1)) }
        }
        let retry = Task { await center.reload() }
        try await wait { server.completeGate != nil }
        try #require(server.completeGate != nil)
        try await wait { result != nil }
        #expect(result == .pending && !center.status().serverConnected && wakes == 0)
        #expect(center.state.nextRegistrationAttemptAt == server.expires)
        server.releaseComplete()
        await retry.value
        #expect(server.putCalls == 1 && center.state.receipt == nil)
        #expect(!center.receiveEnrollmentChallenge(try APNsEnrollmentChallengeDecoder.decode(userInfo: server.payload())))
    }

    @Test("Opt-out cancels its proof owner; a late enrollment payload cannot re-enable or run anything")
    func optOutRejectsLateProof() async throws {
        let server = Server(), installation = Installation()
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil); server.onTarget = nil }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-enrollment-optout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var late: [AnyHashable: Any]?, wakes = 0
        let center = try center(server, http: http, enrollment: enrollment, directory: directory) { _ in wakes += 1; return .newData }
        server.onTarget = { late = $0 }
        let retry = Task { await center.reload() }
        try await wait { late != nil }
        await center.setEnabled(false)
        await retry.value
        let challenge = try APNsEnrollmentChallengeDecoder.decode(userInfo: try #require(late))
        #expect(!center.receiveEnrollmentChallenge(challenge))
        await center.reload() // Waits only for its own finite disabled sync.
        #expect(!center.preferences.enabled && !center.status().serverConnected)
        #expect(wakes == 0 && center.state.seen.isEmpty && center.state.lastWakeOutcome == nil)
        #expect(server.privateTargetSends == 1)
    }

    @Test("Only an explicit old notification can read formerly public history, which remains unavailable to install")
    func historicalNotesDoNotCreateAReleaseReminder() async throws {
        let server = Server()
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-release-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var state = APNsPersistentState(); state.installationID = server.installationID
        state.preferences.enabled = true; state.preferences.versionReminders = true; try store.save(state)
        let center = APNsCenter(store: store, releaseLookup: http, credentials: Credentials(), platform: platform(channel: .testFlight),
            eligibility: { .unavailable }, performWake: { _ in Issue.record("Release notes invoked a task"); return .newData })
        await center.reload()
        let payload = APNsPayload(schemaVersion: 1, kind: .release, eventID: UUID(), installationID: server.installationID,
            registrationRevision: center.preferences.revision, sentAt: Date(), expiresAt: Date().addingTimeInterval(60),
            releaseID: "old-public", channel: .testFlight)
        #expect(await center.receive(payload: payload, source: .foreground) == .rejected)
        #expect(server.historyCalls == 0 && center.presentedRelease == nil)
        await center.openRelease(payload: payload)
        #expect(server.historyCalls == 1 && center.presentedRelease?.isInstallable == false)
        #expect(center.presentedRelease?.notes == "Original public notes")
    }

    @MainActor private final class Scene { var foreground = true }

    @Test("A foreground-proven target wait survives the real background scene callback, then APNs intake joins complete and PUT once")
    func foregroundToBackgroundDeliveryCompletesOriginalRegistration() async throws {
        let server = Server(), installation = Installation(), scene = Scene()
        installation.isForeground = { scene.foreground }
        let (http, host) = try http(server)
        defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil); server.onTarget = nil }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { scene.foreground })
        defer { enrollment.cancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-fg-bg-success-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var late: [AnyHashable: Any]?, results: [UIBackgroundFetchResult.RawValue] = [], wakes = 0
        let center = try center(server, http: http, enrollment: enrollment, directory: directory,
            isForeground: { scene.foreground }) { _ in wakes += 1; return .newData }
        server.onTarget = { late = $0 }
        let retry = Task { await center.reload() }
        try await wait { late != nil && installation.confirmations == 1 }
        try #require(late != nil && installation.confirmations == 1)
        #expect(enrollment.canAwaitTargetInBackground && server.completeCalls == 0)
        scene.foreground = false
        center.applicationStateChanged(isForeground: false)
        #expect(enrollment.canAwaitTargetInBackground && enrollment.hasActiveExchange)
        let payload = try #require(late)
        let challenge = try APNsEnrollmentChallengeDecoder.decode(userInfo: payload)
        // A plain route is not an OS delivery and grants no background work.
        #expect(!center.receiveEnrollmentChallenge(challenge))
        #expect(server.completeCalls == 0)
        #expect(APNsNotificationIntake.background(userInfo: payload, center: { center }) { value in
            Task { @MainActor in results.append(value.rawValue) }
        })
        await retry.value
        try await wait { results.count == 1 }
        #expect(results == [UIBackgroundFetchResult.newData.rawValue])
        #expect(center.status().serverConnected && server.completeCalls == 1 && server.putCalls == 2)
        #expect(installation.proofForegroundStates == [true] && wakes == 0)
        #expect(center.state.lastWakeOutcome == nil && center.state.seen.isEmpty)
    }

    @Test("The same real foreground-to-background transition expires a short delivery budget and rejects late complete/receipt")
    func backgroundDeliveryDeadlineFencesLateReceipt() async throws {
        let server = Server(), installation = Installation(), scene = Scene()
        server.blockComplete = true; installation.isForeground = { scene.foreground }
        let (http, host) = try http(server)
        defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil); server.onTarget = nil; server.releaseComplete() }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { scene.foreground })
        defer { enrollment.cancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APNs-fg-bg-expiry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var late: [AnyHashable: Any]?, wakes = 0
        let center = try center(server, http: http, enrollment: enrollment, directory: directory,
            isForeground: { scene.foreground }) { _ in wakes += 1; return .newData }
        server.onTarget = { late = $0 }
        let retry = Task { await center.reload() }
        try await wait { late != nil && installation.confirmations == 1 }
        try #require(late != nil && installation.confirmations == 1)
        scene.foreground = false
        center.applicationStateChanged(isForeground: false)
        #expect(enrollment.canAwaitTargetInBackground)
        let challenge = try APNsEnrollmentChallengeDecoder.decode(userInfo: try #require(late))
        // The same service method used by native Intake also accepts a
        // caller's smaller remaining budget; no sleep-to-green deadline reset.
        let delivery = Task { await center.receiveEnrollmentChallenge(challenge, deadline: Date().addingTimeInterval(1)) }
        try await wait { server.completeGate != nil }
        try #require(server.completeGate != nil)
        center.applicationStateChanged(isForeground: false) // Does not reset/extend its existing grant.
        #expect(await delivery.value == .pending)
        #expect(!center.status().serverConnected && center.state.receipt == nil)
        #expect(center.state.nextRegistrationAttemptAt == server.expires)
        server.releaseComplete()
        await retry.value
        #expect(server.putCalls == 1 && center.state.receipt == nil)
        #expect(installation.proofForegroundStates == [true] && wakes == 0)
        #expect(!center.receiveEnrollmentChallenge(challenge))
    }

    @Test("Background without an existing foreground instance proof cannot start a key/nonce exchange")
    func backgroundCannotStartInstanceProof() async throws {
        let server = Server(), installation = Installation(), scene = Scene(); scene.foreground = false
        installation.isForeground = { scene.foreground }
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { scene.foreground })
        do { _ = try await enrollment.proof(for: request(server), secret: server.secret); Issue.record("Background started native proof") }
        catch APNsServiceError.foregroundRequired {}
        #expect(server.nonceCalls == 0 && installation.preferences.isEmpty)
    }

    @Test("Missing approved native configuration remains genuinely unconfigured")
    func noConfiguredServiceCannotClaimEnrollment() {
        let service = APNsFirstPartyService(configuration: nil)
        #expect(service.transport == nil && service.enrollment == nil)
        #expect(service.appStoreURL == nil && service.testFlightURL == nil)
    }

    @Test("A long Retry-After ends this call and blocks another immediate origin request")
    func rateLimitCannotRetryInsideBudget() async throws {
        let server = Server(); server.rateLimit = true
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
        for _ in 0..<2 {
            do { _ = try await http.apply(request(server), installationSecret: server.secret); Issue.record("429 was accepted") }
            catch APNsServiceError.rateLimited(let retryAt) { #expect(retryAt.timeIntervalSinceNow > 3_590) }
        }
        #expect(server.putCalls == 1 && server.nonceCalls == 0)
    }

    @Test("An orphan attestation recovers through the actual HTTP coordinator: explicit server unknown, native invalidKey, one replacement attestation")
    func orphanProofHTTPRecoveryIncludingLegacyRecord() async throws {
        for legacy in [false, true] {
            let service = "org.floeagent.fixture.orphan-wire-\(UUID())"
            defer {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrSynchronizable as String: false] as CFDictionary)
            }
            let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            let server = Server(); server.initialKeyError = .unknownAppAttestKey
            let account = server.installationID.uuidString.lowercased() + "/app-attest-key"
            var record: [String: Any] = ["id": "orphan-fixture-key", "confirmed": false]
            if !legacy { record["attested"] = true }
            try vault.store(account: account, secret: JSONSerialization.data(withJSONObject: record))
            let calls = OrphanCalls()
            let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
            let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
            let enrollment = try APNsEnrollmentCoordinator(http: http, installation: native, isForeground: { true })
            let voucher = try await enrollment.proof(for: request(server, enabled: false), secret: server.secret)
            #expect(voucher.voucher == "AA.BB")
            #expect(calls.generations == 1)
            #expect(server.nonceCalls == 1 && server.challengeCalls == 2 && server.completeCalls == 1)
            #expect(server.privateTargetSends == 0)
            let bodies = server.challengeProofBodies
            try #require(bodies.count == 2)
            #expect(bodies[0]["appAttestKeyID"] as? String == "orphan-fixture-key")
            #expect(bodies[0]["assertionObject"] != nil && bodies[0]["attestationObject"] == nil)
            #expect(bodies[1]["appAttestKeyID"] as? String == "replacement-fixture-key")
            #expect(bodies[1]["attestationObject"] != nil && bodies[1]["assertionObject"] == nil)
            #expect(bodies[0]["nonceID"] as? String == bodies[1]["nonceID"] as? String)
            #expect(calls.hashes.allSatisfy { $0 == calls.hashes.first })
            #expect(calls.modes == (legacy ? [false, true, false, false] : [true, false, false]))
            let saved = try #require(JSONSerialization.jsonObject(with: vault.read(account: account)) as? [String: Any])
            #expect(saved["id"] as? String == "replacement-fixture-key")
            #expect(saved["confirmed"] as? Bool == true && saved["attested"] as? Bool == true)
        }
    }
    @MainActor private final class OrphanCalls {
        var generations = 0
        var modes: [Bool] = []
        var hashes: [Data] = []
        var operations: APNsAppAttestOperations {
            .init(isSupported: { true }, generateKey: {
                self.generations += 1; return "replacement-fixture-key"
            }, object: { key, hash, asserting in
                self.modes.append(asserting); self.hashes.append(hash)
                // Model Apple's documented already-attested key behavior,
                // instead of permitting an impossible second attestation.
                if key == "orphan-fixture-key" && !asserting { throw APNsNativeAttestFailure.invalidKey }
                return Data([1, 2, 3, 4])
            })
        }
    }

    @MainActor private final class InvalidKeyWireCalls {
        struct Step: Equatable { let key: String; let asserting: Bool }
        var generated = 0
        var steps: [Step] = []
        var hashes: [Data] = []
        var oldAttestationSucceeds = false
        var newInvalid = false
        var oldFailure: APNsServiceError?
        var holdOld = false
        var pending: CheckedContinuation<Data, Error>?
        var operations: APNsAppAttestOperations {
            .init(isSupported: { true }, generateKey: {
                self.generated += 1; return "replacement-fixture-key"
            }, object: { key, hash, asserting in
                self.steps.append(.init(key: key, asserting: asserting)); self.hashes.append(hash)
                if key == "unusable-fixture-key" {
                    if self.holdOld { return try await withCheckedThrowingContinuation { self.pending = $0 } }
                    if let failure = self.oldFailure { throw failure }
                    if asserting || !self.oldAttestationSucceeds { throw APNsNativeAttestFailure.invalidKey }
                } else if self.newInvalid { throw APNsNativeAttestFailure.invalidKey }
                return Data([1, 2, 3, 4])
            })
        }
    }
    private func clearRecoveryFixture(_ service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false] as CFDictionary)
    }

    @Test("Typed unusable old keys recover once through Native provider and HTTP, including confirmed and legacy states")
    func unusableNativeKeyHTTPRecovery() async throws {
        for variant in ["legacy", "attested", "confirmed", "assertionRequired"] {
            let service = "org.floeagent.fixture.unusable-wire-\(UUID())"
            defer { clearRecoveryFixture(service) }
            let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            let server = Server(), calls = InvalidKeyWireCalls()
            let account = server.installationID.uuidString.lowercased() + "/app-attest-key"
            var record: [String: Any] = ["id": "unusable-fixture-key", "confirmed": variant == "confirmed"]
            if variant == "attested" { record["attested"] = true }
            if variant == "assertionRequired" {
                calls.oldAttestationSucceeds = true
                server.initialKeyError = .appAttestAssertionRequired
            }
            try vault.store(account: account, secret: JSONSerialization.data(withJSONObject: record))
            let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
            let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
            let enrollment = try APNsEnrollmentCoordinator(http: http, installation: native, isForeground: { true })
            _ = try await enrollment.proof(for: request(server, enabled: false), secret: server.secret)
            #expect(calls.generated == 1 && server.nonceCalls == 1 && server.completeCalls == 1)
            #expect(server.challengeCalls == (variant == "assertionRequired" ? 2 : 1))
            #expect(server.privateTargetSends == 0)
            let last = try #require(server.challengeProofBodies.last)
            #expect(last["appAttestKeyID"] as? String == "replacement-fixture-key")
            #expect(last["attestationObject"] != nil && last["assertionObject"] == nil)
            #expect(last["nativeKeyRecovery"] == nil) // Internal provenance never enters wire JSON.
            #expect(calls.hashes.allSatisfy { $0 == calls.hashes.first })
            let expectedModes: [Bool] = (variant == "legacy" || variant == "assertionRequired")
                ? [false, true, false] : [true, false]
            #expect(calls.steps.map(\.asserting) == expectedModes)
            let saved = try #require(JSONSerialization.jsonObject(with: vault.read(account: account)) as? [String: Any])
            #expect(saved["id"] as? String == "replacement-fixture-key" && saved["confirmed"] as? Bool == true)
        }
    }

    @Test("A replacement error cannot create another key on the same challenge; initial fresh-key failure never loops")
    func replacementInvalidKeyNeverLoops() async throws {
        for existing in [false, true] {
            let service = "org.floeagent.fixture.invalidkey-budget-\(UUID())"
            defer { clearRecoveryFixture(service) }
            let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            let id = UUID(), account = id.uuidString.lowercased() + "/app-attest-key"
            if existing {
                try vault.store(account: account, secret: JSONSerialization.data(withJSONObject: ["id": "unusable-fixture-key", "confirmed": true]))
            }
            let calls = InvalidKeyWireCalls(); calls.newInvalid = true
            let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
            let hash = Data(repeating: 0x51, count: 32)
            do { _ = try await native.proof(installationID: id, clientDataHash: hash, preference: .automatic); Issue.record("Unusable replacement accepted") }
            catch let error as APNsServiceError {
                #expect(error == .nativeVerification(.init(stage: .attestation, code: .invalidKey)))
            }
            #expect(calls.generated == 1)
            #expect(calls.steps.filter { $0.key == "replacement-fixture-key" }.count == 1)
            if existing {
                do { _ = try await native.proof(installationID: id, clientDataHash: hash, preference: .automatic); Issue.record("Repeated unusable key accepted") }
                catch let error as APNsServiceError { if case .nativeVerification = error {} else { Issue.record("Unexpected error") } }
                #expect(calls.generated == 1) // A second proof negotiation does not reset budget.
            }
        }
    }

    @Test("Cancellation wins over late invalidKey and prevents replacement native work")
    func cancelledInvalidKeyCannotReplace() async throws {
        let service = "org.floeagent.fixture.invalidkey-cancel-\(UUID())"
        defer { clearRecoveryFixture(service) }
        let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
        let id = UUID(), account = id.uuidString.lowercased() + "/app-attest-key"
        let original = try JSONSerialization.data(withJSONObject: ["id": "unusable-fixture-key", "confirmed": true])
        try vault.store(account: account, secret: original)
        let calls = InvalidKeyWireCalls(); calls.holdOld = true
        let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        let task = Task { try await native.proof(installationID: id, clientDataHash: Data(repeating: 0x52, count: 32), preference: .automatic) }
        try await wait { calls.pending != nil }
        task.cancel(); let continuation = calls.pending; calls.pending = nil
        continuation?.resume(throwing: APNsNativeAttestFailure.invalidKey)
        do { _ = try await task.value; Issue.record("Cancelled invalidKey continued") }
        catch is CancellationError {}
        #expect(calls.generated == 0 && calls.steps.count == 1)
        #expect(try vault.read(account: account) == original)
    }

    @Test("Unknown native errors and HTTP503 never authorize key replacement")
    func unknownAndHTTPFailureCannotReplaceKey() async throws {
        for failNative in [false, true] {
            let service = "org.floeagent.fixture.invalidkey-negative-\(UUID())"
            defer { clearRecoveryFixture(service) }
            let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            let server = Server(), calls = InvalidKeyWireCalls()
            server.challengeUnavailable = !failNative
            let account = server.installationID.uuidString.lowercased() + "/app-attest-key"
            try vault.store(account: account, secret: JSONSerialization.data(withJSONObject: ["id": "unusable-fixture-key", "confirmed": true]))
            if failNative { calls.oldFailure = .nativeVerification(.init(stage: .assertion, code: .unknown)) }
            // For HTTP503, allow the old native assertion and fail only HTTP.
            let operations = APNsAppAttestOperations(isSupported: { true }, generateKey: calls.operations.generateKey,
                object: { key, hash, asserting in
                    calls.steps.append(.init(key: key, asserting: asserting)); calls.hashes.append(hash)
                    if let error = calls.oldFailure { throw error }
                    return Data([1, 2, 3, 4])
                })
            let native = APNsNativeInstallationProofs(vault: vault, native: operations)
            let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
            let enrollment = try APNsEnrollmentCoordinator(http: http, installation: native, isForeground: { true })
            do { _ = try await enrollment.proof(for: request(server, enabled: false), secret: server.secret); Issue.record("Failure accepted") }
            catch let error as APNsServiceError {
                if failNative { #expect(error == calls.oldFailure) }
                else { if case .enrollmentDeferred = error {} else { Issue.record("503 did not defer") } }
            }
            #expect(calls.generated == 0 && calls.steps.count == 1 && server.privateTargetSends == 0)
            #expect(server.challengeCalls == (failNative ? 0 : 1))
        }
    }

    private actor RegistrationRecoveryTransport: APNsEnrollmentTransport {
        private var count = 0
        private var failure: APNsServiceError?
        init(failure: APNsServiceError? = nil) { self.failure = failure }
        func apply(_ request: APNsRegistrationRequest, installationSecret: Data) async throws -> APNsRegistrationReceipt {
            count += 1
            if let failure { throw failure }
            return .init(installationID: request.installationID, acceptedRevision: request.revision,
                enabled: request.enabled, acceptedAt: Date(), leaseExpiresAt: Date().addingTimeInterval(300))
        }
        func calls() -> Int { count }
    }
    private func recoveryCenter(store: APNsStateStore, transport: RegistrationRecoveryTransport) -> APNsCenter {
        APNsCenter(store: store, signingEnvironment: .production, transport: transport,
            credentials: Credentials(), platform: platform(),
            eligibility: { .init(hasEnabledSchedule: true, hasProgressableExecution: false) },
            performWake: { _ in .noData })
    }

    @Test("Cold restart retains typed waits: only an actual 429 is busy; legacy deadlines stay pending")
    func persistedRegistrationWaitsKeepTheirCause() async throws {
        let deadline = Date().addingTimeInterval(600)
        let nativeFailure = APNsServiceError.nativeVerification(.init(stage: .attestation, code: .unknown))
        let cases: [(APNsServiceError?, String)] = [
            (nil, "pending"), (.enrollmentDeferred(until: deadline), "pending"),
            (.foregroundRequired, "pending"), (nativeFailure, "verificationUnavailable"),
            (.rateLimited(until: deadline), "rateLimited")
        ]
        for (cause, expected) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apns-recovery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try APNsStateStore(directory: directory)
            var state = APNsPersistentState(); state.preferences.enabled = true
            state.nextRegistrationAttemptAt = deadline; state.registrationFailure = cause
            // Real legacy JSON omits the newly added optional field entirely.
            if cause == nil {
                var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
                json.removeValue(forKey: "registrationFailure")
                state = try JSONDecoder().decode(APNsPersistentState.self, from: JSONSerialization.data(withJSONObject: json))
            }
            try store.save(state)
            let transport = RegistrationRecoveryTransport()
            for _ in 0..<2 {
                let center = recoveryCenter(store: store, transport: transport)
                await center.reload()
                #expect(center.syncState == expected)
                #expect(center.failure == (cause ?? .enrollmentDeferred(until: deadline)).localizedDescription)
                #expect(center.state.registrationFailure == cause)
                #expect(center.status().nextRegistrationAttemptAt == deadline)
                #expect(center.state.installationID == state.installationID)
                #expect(!center.status().serverConnected)
            }
            #expect(await transport.calls() == 0)
        }
    }

    @Test("Actual 429 persists its cause and deadline; cold reopen cannot retry early")
    func rateLimitPersistsAcrossCenterReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apns-rate-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var state = APNsPersistentState(); state.preferences.enabled = true; try store.save(state)
        let deadline = Date().addingTimeInterval(600)
        let transport = RegistrationRecoveryTransport(failure: .rateLimited(until: deadline))
        let first = recoveryCenter(store: store, transport: transport)
        await first.reload()
        #expect(first.state.registrationFailure == .rateLimited(until: deadline))
        #expect(first.syncState == "rateLimited" && !first.status().serverConnected)
        let reopened = recoveryCenter(store: store, transport: transport)
        await reopened.reload()
        #expect(reopened.state.registrationFailure == .rateLimited(until: deadline))
        #expect(reopened.status().nextRegistrationAttemptAt == deadline)
        #expect(reopened.state.installationID == state.installationID)
        #expect(await transport.calls() == 1)
    }

    @Test("Only a final valid registration receipt clears persisted failure and establishes connection")
    func finalReceiptClearsRegistrationFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apns-final-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try APNsStateStore(directory: directory)
        var state = APNsPersistentState(); state.preferences.enabled = true
        state.nextRegistrationAttemptAt = Date().addingTimeInterval(-1)
        state.registrationFailure = .nativeVerification(.init(stage: .attestation, code: .serverUnavailable))
        try store.save(state)
        let transport = RegistrationRecoveryTransport(), center = recoveryCenter(store: store, transport: transport)
        #expect(!center.status().serverConnected)
        await center.reload()
        #expect(center.status().serverConnected && center.syncState == "connected")
        #expect(center.state.registrationFailure == nil && center.state.nextRegistrationAttemptAt == nil)
        let persisted = try store.load()
        #expect(persisted.registrationFailure == nil && persisted.nextRegistrationAttemptAt == nil)
        #expect(persisted.installationID == state.installationID)
        #expect(await transport.calls() == 1)
    }

    @Test("A native proof failure persists its typed cause through the actual center and blocks another request until nonce expiry")
    func nativeFailurePersistsAcrossCenterReopen() async throws {
        let server = Server(), installation = Installation()
        let failure = APNsServiceError.nativeVerification(.init(stage: .attestation, code: .unknown))
        installation.failure = failure
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apns-native-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try center(server, http: http, enrollment: enrollment, directory: directory, wake: { _ in .noData })
        await first.reload()
        #expect(first.state.registrationFailure == failure)
        #expect(first.syncState == "verificationUnavailable" && !first.status().serverConnected)
        #expect(first.state.nextRegistrationAttemptAt == server.expires)
        let unused = RegistrationRecoveryTransport()
        let reopened = recoveryCenter(store: try APNsStateStore(directory: directory), transport: unused)
        await reopened.reload()
        #expect(reopened.state.registrationFailure == failure && reopened.syncState == "verificationUnavailable")
        #expect(reopened.status().nextRegistrationAttemptAt == server.expires)
        #expect(reopened.state.installationID == server.installationID)
        #expect(await unused.calls() == 0)
        #expect(server.nonceCalls == 1 && server.challengeCalls == 0 && installation.hashes.count == 1)
    }

    @Test("Native failure before challenge preserves the real nonce deadline and closed diagnostic")
    func nativeFailureBeforeChallengeRetainsDeadline() async throws {
        let server = Server(), installation = Installation()
        installation.failure = .nativeVerification(.init(stage: .attestation, code: .unknown))
        let (http, host) = try http(server); defer { APNsEnrollmentFixtureProtocol.registry.set(host, nil) }
        let enrollment = try APNsEnrollmentCoordinator(http: http, installation: installation, isForeground: { true })
        do { _ = try await enrollment.proof(for: request(server), secret: server.secret); Issue.record("Native failure accepted") }
        catch let error as APNsServiceError { #expect(error == installation.failure) }
        #expect(enrollment.retryAfterInterruption == server.expires)
        #expect(server.nonceCalls == 1 && server.challengeCalls == 0 && server.privateTargetSends == 0)
        #expect(installation.confirmations == 0)
    }

}

@Suite("APNs registration native recovery", .serialized)
@MainActor struct APNsRegistrationNativeRecoveryTests {
    private struct Call: Equatable { let key: String; let hash: Data; let asserting: Bool }
    @MainActor private final class Calls {
        var generated = 0
        var objects: [Call] = []
        var failures: [APNsServiceError] = []
        var hold = false
        var pending: CheckedContinuation<Data, Error>?
        var operations: APNsAppAttestOperations {
            .init(isSupported: { true }, generateKey: {
                self.generated += 1; return "fixture-native-key"
            }, object: { key, hash, asserting in
                self.objects.append(.init(key: key, hash: hash, asserting: asserting))
                if !self.failures.isEmpty { throw self.failures.removeFirst() }
                if self.hold { return try await withCheckedThrowingContinuation { self.pending = $0 } }
                return Data([1, 2, 3, 4])
            })
        }
        func finish() { let continuation = pending; pending = nil; continuation?.resume(returning: Data([1, 2, 3, 4])) }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }
    private func removeFixture(_ service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false] as CFDictionary)
    }
    private func record(_ vault: KeychainStore, _ account: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: vault.read(account: account)) as? [String: Any])
    }

    @Test("Native success is retained independently from server confirmation; a new nonce uses assertion after recreation")
    func nativeSuccessAndServerConfirmationAreSeparate() async throws {
        let service = "org.floeagent.fixture.native-recovery-\(UUID())"
        defer { removeFixture(service) }
        let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
        let id = UUID(), account = id.uuidString.lowercased() + "/app-attest-key"
        let calls = Calls(), hash = Data(repeating: 1, count: 32)
        let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        let proof = try await native.proof(installationID: id, clientDataHash: hash, preference: .automatic)
        #expect(proof.attestationObject != nil && proof.assertionObject == nil)
        #expect(try record(vault, account)["attested"] as? Bool == true)
        #expect(try record(vault, account)["confirmed"] as? Bool == false)
        _ = try await native.proof(installationID: id, clientDataHash: hash, preference: .automatic)
        #expect(calls.objects.count == 1) // Lost HTTP reply can reuse the exact cached attestation.
        let reopened = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        let assertion = try await reopened.proof(installationID: id, clientDataHash: Data(repeating: 2, count: 32), preference: .automatic)
        #expect(assertion.assertionObject != nil && assertion.attestationObject == nil)
        #expect(calls.generated == 1 && calls.objects.count == 2 && calls.objects.last?.asserting == true)
        #expect(try record(vault, account)["confirmed"] as? Bool == false)
        try reopened.confirm(installationID: id, keyID: proof.keyID)
        #expect(try record(vault, account)["confirmed"] as? Bool == true)
    }

    @Test("A cancelled successful native callback retains attested state before cancellation without changing credentials")
    func cancelledAttestationSuccessIsRetained() async throws {
        let service = "org.floeagent.fixture.native-cancel-\(UUID())"
        defer { removeFixture(service) }
        let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
        let id = UUID(), prefix = id.uuidString.lowercased(), account = prefix + "/app-attest-key"
        let secret = Data(repeating: 0x47, count: 32), token = Data(repeating: 0x48, count: 32)
        try vault.store(account: prefix + "/credential", secret: secret)
        try vault.store(account: prefix + "/token", secret: token)
        let calls = Calls(); calls.hold = true
        let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        let task = Task { try await native.proof(installationID: id, clientDataHash: Data(repeating: 3, count: 32), preference: .automatic) }
        try await wait { calls.pending != nil }
        task.cancel(); calls.finish()
        do { _ = try await task.value; Issue.record("Cancelled callback returned a usable proof") }
        catch is CancellationError {}
        #expect(try record(vault, account)["attested"] as? Bool == true)
        #expect(try record(vault, account)["confirmed"] as? Bool == false)
        calls.hold = false
        let reopened = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        _ = try await reopened.proof(installationID: id, clientDataHash: Data(repeating: 4, count: 32), preference: .automatic)
        #expect(calls.objects.last?.asserting == true && calls.generated == 1)
        #expect(try vault.read(account: prefix + "/credential") == secret)
        #expect(try vault.read(account: prefix + "/token") == token)
    }

    @Test("Late native success cannot mark or overwrite a newer canonical key")
    func lateAttestationDoesNotOverwriteNewerKey() async throws {
        let service = "org.floeagent.fixture.native-attest-cas-\(UUID())"
        defer { removeFixture(service) }
        let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
        let id = UUID(), account = id.uuidString.lowercased() + "/app-attest-key"
        let calls = Calls(); calls.hold = true
        let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        let task = Task { try await native.proof(installationID: id, clientDataHash: Data(repeating: 5, count: 32), preference: .automatic) }
        try await wait { calls.pending != nil }
        let newer = try JSONSerialization.data(withJSONObject: ["id": "newer-fixture-key", "confirmed": true])
        try vault.store(account: account, secret: newer)
        calls.finish()
        do { _ = try await task.value; Issue.record("Stale callback accepted a replaced key") }
        catch APNsServiceError.storage {}
        #expect(try vault.read(account: account) == newer)
        #expect(calls.generated == 1)
    }

    @Test("Only native attestation serverUnavailable retries once with the identical key and hash")
    func transientRetryKeepsKeyAndHash() async throws {
        for unavailableCount in [1, 2] {
            let service = "org.floeagent.fixture.native-transient-\(UUID())"
            defer { removeFixture(service) }
            let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            let calls = Calls()
            let failure = APNsServiceError.nativeVerification(.init(stage: .attestation, code: .serverUnavailable))
            calls.failures = Array(repeating: failure, count: unavailableCount)
            let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
            do {
                _ = try await native.proof(installationID: UUID(), clientDataHash: Data(repeating: 6, count: 32), preference: .automatic)
                #expect(unavailableCount == 1)
            } catch let error as APNsServiceError { #expect(unavailableCount == 2 && error == failure) }
            #expect(calls.generated == 1 && calls.objects.count == 2)
            #expect(calls.objects[0] == calls.objects[1] && !calls.objects[0].asserting)
        }
    }

    @Test("Unknown native failure and assertion serverUnavailable never retry or generate another key; legacy records remain readable")
    func nonTransientFailureDoesNotRegenerate() async throws {
        for asserting in [false, true] {
            let service = "org.floeagent.fixture.native-no-retry-\(UUID())"
            defer { removeFixture(service) }
            let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            let id = UUID(), account = id.uuidString.lowercased() + "/app-attest-key"
            if asserting { try vault.store(account: account, secret: JSONSerialization.data(withJSONObject: ["id": "legacy-key", "confirmed": true])) }
            let calls = Calls()
            let failure = APNsServiceError.nativeVerification(.init(stage: asserting ? .assertion : .attestation,
                code: asserting ? .serverUnavailable : .unknown))
            calls.failures = [failure]
            let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
            do { _ = try await native.proof(installationID: id, clientDataHash: Data(repeating: 7, count: 32), preference: .automatic); Issue.record("Failure accepted") }
            catch let error as APNsServiceError { #expect(error == failure) }
            #expect(calls.objects.count == 1 && calls.objects[0].asserting == asserting)
            #expect(calls.generated == (asserting ? 0 : 1))
            #expect(try record(vault, account)["attested"] == nil)
        }
    }

    @Test("Cancellation fences the one transient retry before a second native call")
    func cancellationStopsTransientRetry() async throws {
        let service = "org.floeagent.fixture.native-retry-cancel-\(UUID())"
        defer { removeFixture(service) }
        let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
        let calls = Calls(); calls.failures = [.nativeVerification(.init(stage: .attestation, code: .serverUnavailable))]
        let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        let task = Task { try await native.proof(installationID: UUID(), clientDataHash: Data(repeating: 8, count: 32), preference: .automatic) }
        try await wait { calls.objects.count == 1 }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled transient operation continued") }
        catch is CancellationError {}
        #expect(calls.generated == 1 && calls.objects.count == 1)
    }
}

#endif
