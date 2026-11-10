import Foundation
import CryptoKit
import Testing
import FloeCore
import FloeGit
import FloePersistence
import FloeSecurity
import FloeSSH
import FloeSync
@testable import FloeApp

private final class GitTestBindings: GitBindingStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(_ bytes: Data, account: String) throws { lock.withLock { values[account] = bytes } }
    func delete(_ account: String) throws { lock.withLock { values[account] = nil } }
}
private actor GitChallengeProbe {
    private(set) var calls = 0
    let challenge: GitSSHHostKeyChallenge
    init(_ challenge: GitSSHHostKeyChallenge) { self.challenge = challenge }
    func perform(_ authentication: GitRemoteAuthentication) throws -> String {
        calls += 1
        if calls == 1 { throw GitRemoteFailure.hostKeyNotTrusted(challenge) }
        // This is a resolver boundary test, not a network/SSH acceptance claim.
        return authentication.description
    }
}
private actor GitTrustGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var entered = false
    private var replied: Bool?
    func wait() async -> Bool { entered = true; if let replied { return replied }; return await withCheckedContinuation { continuation = $0 } }
    func reply(_ value: Bool) { replied = value; continuation?.resume(returning: value); continuation = nil }
}
@Suite("Git native credential scope and host trust", .serialized)
struct NextRoundGitCredentialTests {
    private let fingerprint = "SHA256:" + Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    private let other = "SHA256:" + Data(repeating: 8, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    private struct Fixture: Sendable {
        let database: DatabaseManager
        let hosts: RemoteHostStore
        let resolver: GitRemoteCredentialResolver
        let scope: GitCredentialScope
        let endpoint: GitRemoteEndpoint
        let profile: RemoteHostProfile
        let challenge: GitSSHHostKeyChallenge
    }
    private func fixture() async throws -> Fixture {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let hosts = RemoteHostStore(database: database), credentials = CredentialStore(database: database)
        let profile = RemoteHostProfile(displayName: "Synthetic Git Host", address: "git.fixture.invalid", port: 22,
            user: "git", auth: .password(.init(keychainAccount: "synthetic-git-fixture", synchronizable: false)))
        let encoder = JSONEncoder()
        try await hosts.saveHost(id: profile.id, displayName: profile.displayName, address: profile.address, port: profile.port, user: profile.user,
            authJSON: String(decoding: try encoder.encode(profile.auth), as: UTF8.self), jumpChainJSON: "[]", hostKeyPolicy: "tofu", allowsLegacyAlgorithms: false, vncEndpointJSON: nil)
        let resolver = GitRemoteCredentialResolver(vault: CredentialVaultService(records: credentials), credentials: credentials,
            hosts: hosts, bindings: GitTestBindings(), secret: { _ in Data("synthetic-password-not-a-real-credential".utf8) })
        return .init(database: database, hosts: hosts, resolver: resolver,
            scope: .init(workspaceRoot: URL(fileURLWithPath: "/synthetic/git/project"), workspaceID: nil, conversationID: nil),
            endpoint: try .init("git@git.fixture.invalid:owner/repo.git"), profile: profile,
            challenge: .init(host: profile.address, port: 22, user: "git", keyType: "ssh-ed25519", fingerprintSHA256: fingerprint))
    }
    @Test("Saved credentials remain bound to exact origin, owner and credential kind")
    func ownerAndOrigin() throws {
        let project = UUID(), task = UUID(), endpoint = try GitRemoteEndpoint("https://git.example.invalid:8443/owner/repo.git")
        let scope = GitCredentialScope(workspaceRoot: URL(fileURLWithPath: "/synthetic/project"), workspaceID: project, conversationID: task)
        var record = CredentialRecord(id: UUID(), kind: .genericToken, owner: .workspace(project), label: "Fixture", keychainAccount: "synthetic", synchronizable: false)
        record.origin = "https://git.example.invalid:8443"
        #expect(GitRemoteCredentialResolver.admits(record, endpoint: endpoint, scope: scope))
        record.origin = "https://git.example.invalid"
        #expect(!GitRemoteCredentialResolver.admits(record, endpoint: endpoint, scope: scope))
        record.origin = nil; record.owner = .workspace(UUID())
        #expect(!GitRemoteCredentialResolver.admits(record, endpoint: endpoint, scope: scope))
        record.owner = .conversation(task)
        #expect(GitRemoteCredentialResolver.admits(record, endpoint: endpoint, scope: scope))
        record.owner = .conversation(UUID())
        #expect(!GitRemoteCredentialResolver.admits(record, endpoint: endpoint, scope: scope))
        record.owner = .vault; record.kind = .providerAPIKey
        #expect(!GitRemoteCredentialResolver.admits(record, endpoint: endpoint, scope: scope))
    }
    @Test("Existing raw P256 profile bytes convert to the same actual in-memory PEM key")
    func privateKeyConversion() throws {
        let key = P256.Signing.PrivateKey()
        let bytes = try GitRemoteCredentialResolver.privateKey(key.rawRepresentation, type: .ecdsaP256)
        let pem = try #require(String(data: bytes, encoding: .utf8))
        #expect(try P256.Signing.PrivateKey(pemRepresentation: pem).rawRepresentation == key.rawRepresentation)
        #expect(try GitRemoteCredentialResolver.privateKey(Data("synthetic-ed25519-format".utf8), type: .ed25519) == Data("synthetic-ed25519-format".utf8))
    }
    @Test("Host-bound selection metadata does not cross workspace or endpoint")
    func bindingIsolation() async throws {
        let f = try await fixture(), endpoint = try GitRemoteEndpoint("https://git.fixture.invalid/owner/repo.git")
        try await f.resolver.save(.anonymous, endpoint: endpoint, scope: f.scope)
        #expect(try await f.resolver.choice(for: endpoint, scope: f.scope) == .anonymous)
        let otherScope = GitCredentialScope(workspaceRoot: URL(fileURLWithPath: "/synthetic/other"), workspaceID: nil, conversationID: nil)
        #expect(try await f.resolver.choice(for: endpoint, scope: otherScope) == .automatic)
        #expect(try await f.resolver.choice(for: GitRemoteEndpoint("https://other.fixture.invalid/repo.git"), scope: f.scope) == .automatic)
    }
    @Test("Two real database stores cannot overwrite a host key during first-use approval")
    func atomicTrust() async throws {
        let f = try await fixture(), secondStore = RemoteHostStore(database: f.database)
        let first = KnownHostRecord(hostID: f.profile.id, address: f.profile.address, port: 22, keyType: "ssh-ed25519", fingerprintSHA256: fingerprint)
        let second = KnownHostRecord(hostID: f.profile.id, address: f.profile.address, port: 22, keyType: "ssh-ed25519", fingerprintSHA256: other)
        async let a = f.hosts.trustIfAbsentOrMatching(first)
        async let b = secondStore.trustIfAbsentOrMatching(second)
        let values = try await [a, b]
        #expect(values.filter { $0 }.count == 1)
        let saved = try #require(await f.hosts.knownHost(address: f.profile.address, port: 22, keyType: "ssh-ed25519"))
        #expect(saved.fingerprintSHA256 == (values[0] ? fingerprint : other))
        let same = KnownHostRecord(hostID: f.profile.id, address: f.profile.address, port: 22, keyType: "ssh-ed25519", fingerprintSHA256: saved.fingerprintSHA256 + "=")
        #expect(try await secondStore.trustIfAbsentOrMatching(same))
    }
    @Test("Previously trusted exact host resolves once then retries only the pre-auth challenge")
    func knownHostBridge() async throws {
        let f = try await fixture(), probe = GitChallengeProbe(f.challenge)
        _ = try await f.hosts.trustIfAbsentOrMatching(.init(hostID: f.profile.id, address: f.profile.address, port: 22, keyType: "ssh-ed25519", fingerprintSHA256: fingerprint))
        let result = try await f.resolver.withAuthentication(endpoint: f.endpoint, scope: f.scope, authorize: {}, operation: { try await probe.perform($0) })
        #expect(await probe.calls == 2)
        #expect(!result.contains("synthetic-password"))
    }
    @Test("A changed host key is refused without retrying or replacing its record")
    func changedKeyRefused() async throws {
        let f = try await fixture(), probe = GitChallengeProbe(f.challenge)
        _ = try await f.hosts.trustIfAbsentOrMatching(.init(hostID: f.profile.id, address: f.profile.address, port: 22, keyType: "ssh-ed25519", fingerprintSHA256: other))
        await #expect(throws: GitRemoteFailure.hostKeyChanged(expected: other, received: fingerprint)) {
            try await f.resolver.withAuthentication(endpoint: f.endpoint, scope: f.scope, authorize: {}, operation: { try await probe.perform($0) })
        }
        #expect(await probe.calls == 1)
        #expect(try await f.hosts.knownHost(address: f.profile.address, port: 22, keyType: "ssh-ed25519")?.fingerprintSHA256 == other)
    }
    @Test("A competing key saved during native approval is preserved and blocks the retry")
    func trustRaceRefused() async throws {
        let f = try await fixture(), probe = GitChallengeProbe(f.challenge), competing = other
        await #expect(throws: (any Error).self) {
            try await f.resolver.withAuthentication(endpoint: f.endpoint, scope: f.scope, authorize: {}, trust: { _ in
                _ = try? await f.hosts.trustIfAbsentOrMatching(.init(hostID: f.profile.id, address: f.profile.address, port: 22, keyType: "ssh-ed25519", fingerprintSHA256: competing))
                return true
            }, operation: { try await probe.perform($0) })
        }
        #expect(await probe.calls == 1)
        #expect(try await f.hosts.knownHost(address: f.profile.address, port: 22, keyType: "ssh-ed25519")?.fingerprintSHA256 == other)
    }
    @Test("Cancellation while approval waits cannot persist trust or start a new native attempt")
    func cancelPendingTrust() async throws {
        let f = try await fixture(), probe = GitChallengeProbe(f.challenge), gate = GitTrustGate()
        let worker = Task { try await f.resolver.withAuthentication(endpoint: f.endpoint, scope: f.scope, authorize: {}, trust: { _ in await gate.wait() }, operation: { try await probe.perform($0) }) }
        for _ in 0..<1000 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.entered)
        worker.cancel(); await gate.reply(true)
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(await probe.calls == 1)
        #expect(try await f.hosts.knownHost(address: f.profile.address, port: 22, keyType: "ssh-ed25519") == nil)
    }
    @Test("Workspace operation lease never becomes valid again after A-B-A navigation")
    func operationLeaseFence() throws {
        let a = URL(fileURLWithPath: "/synthetic/a"), b = URL(fileURLWithPath: "/synthetic/b"), id = UUID()
        let lease = SourceControlOperationLease(workspaceRoot: a, repositoryRoot: a, workspaceID: id)
        #expect(lease.matches(root: a, workspaceID: id)); #expect(!lease.matches(root: b, workspaceID: UUID()))
        lease.cancel()
        #expect(lease.matches(root: a, workspaceID: id))
        #expect(throws: CancellationError.self) { try lease.check() }
    }
}
