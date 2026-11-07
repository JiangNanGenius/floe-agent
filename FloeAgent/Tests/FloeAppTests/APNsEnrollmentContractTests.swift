// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import Testing
import UIKit
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
        var proofForegroundStates: [Bool] = []
        var isForeground: @MainActor () -> Bool = { true }
        func evidence() async -> APNsInstallationEvidence { .unknown }
        func proof(installationID: UUID, clientDataHash: Data, preference: APNsAppAttestPreference) async throws -> APNsAppAttestProof {
            hashes.append(clientDataHash); preferences.append(preference)
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
}
#endif
