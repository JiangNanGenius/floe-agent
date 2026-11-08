import Foundation
import Testing
@testable import FloeSkills

private actor TransferPolicyLoader {
    private var continuation: CheckedContinuation<GitHubTransportMirrorPolicyStore.Downloaded, Error>?
    private(set) var count = 0
    func load() async throws -> GitHubTransportMirrorPolicyStore.Downloaded {
        count += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release(_ value: GitHubTransportMirrorPolicyStore.Downloaded) {
        let waiting = continuation; continuation = nil; waiting?.resume(returning: value)
    }
    func fail() {
        let waiting = continuation; continuation = nil; waiting?.resume(throwing: URLError(.timedOut))
    }
}

@Suite("FloeSkills.GitHubTransportMirrorTransferWait", .serialized)
struct GitHubTransportMirrorTransferWaitTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-08T14:00:00Z")!
    // Public immutable Gen2 at Hub71207f4; no private signer material. The
    // fixed fixture clock tests its originally valid period, not live expiry.
    private let payload = Data("{\"expiresAt\":\"2026-11-15T13:16:22Z\",\"generation\":2,\"issuedAt\":\"2026-11-08T13:16:22Z\",\"purpose\":\"floe-github-transport-mirrors\",\"roles\":{\"atom\":[\"gh-proxy.com\"],\"rawFiles\":[\"ghfast.top\",\"gh-proxy.com\"],\"releaseAssets\":[\"ghfast.top\",\"gh-proxy.com\"]},\"schemaVersion\":1}\n".utf8)
    private let signature = Data("{\"keyID\":\"official-2026-09\",\"signature\":\"VzkW1jDb5UFR5V47iV5MUMsdG9gTs7l7tgFC4ftMHbCcPstm7WDPtrJTDw7+1GJF5dwzegvyo2J42yPZ7PTfAA==\"}".utf8)
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transport-wait-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("policy.json")
    }
    private func waitForLoad(_ loader: TransferPolicyLoader) async throws {
        for _ in 0..<100 { if await loader.count > 0 { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("policy refresh did not start")
    }

    @Test func coldTransferAdoptsRealSignedGenTwoAndReopensSameFloor() async throws {
        let location = try file(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let now = self.now
        let store = GitHubTransportMirrorPolicyStore(persistenceURL: location, clock: { now })
        let loader = TransferPolicyLoader()
        let task = Task { await store.policyForTransfer { try await loader.load() } }
        try await waitForLoad(loader)
        await loader.release(.init(payload: payload, signature: signature))
        let result = await task.value
        #expect(result.generation == 2 && result.highestGeneration == 2 && !result.usesBundledDefaults)
        #expect(result.roles.releaseAssets == [.ghfast, .ghProxy])
        #expect(await loader.count == 1)
        let reopened = GitHubTransportMirrorPolicyStore(persistenceURL: location, clock: { now })
        let saved = await reopened.snapshot()
        #expect(saved.generation == 2 && saved.highestGeneration == 2 && !saved.usesBundledDefaults)
    }

    @Test func cancellingOneWaiterDoesNotCancelSharedRefreshOrOtherTransfer() async throws {
        let location = try file(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let now = self.now
        let store = GitHubTransportMirrorPolicyStore(persistenceURL: location, clock: { now })
        let loader = TransferPolicyLoader()
        let first = Task { await store.policyForTransfer { try await loader.load() } }
        try await waitForLoad(loader)
        let second = Task { await store.policyForTransfer { try await loader.load() } }
        try await Task.sleep(for: .milliseconds(10))
        // Rescue bounds a broken cancellation implementation, producing a
        // real failed deadline assertion rather than a hanging qualification.
        let rescue = Task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { await loader.fail() } }
        defer { rescue.cancel() }
        let started = ContinuousClock.now
        first.cancel()
        let cancelled = await first.value
        #expect(started.duration(to: .now) < .milliseconds(200))
        #expect(cancelled.usesBundledDefaults)
        #expect(await loader.count == 1)
        await loader.release(.init(payload: payload, signature: signature))
        let result = await second.value
        #expect(result.generation == 2 && result.roles.releaseAssets == [.ghfast, .ghProxy])
        #expect(await loader.count == 1)
    }

    @Test func invalidSignatureAndAvailabilityFailureWakeWithoutInventingRoles() async throws {
        for invalidSignature in [false, true] {
            let location = try file(); defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
            let now = self.now
            let store = GitHubTransportMirrorPolicyStore(persistenceURL: location, clock: { now })
            let loader = TransferPolicyLoader()
            let task = Task { await store.policyForTransfer { try await loader.load() } }
            try await waitForLoad(loader)
            if invalidSignature { await loader.release(.init(payload: payload, signature: Data("invalid".utf8))) }
            else { await loader.fail() }
            let result = await task.value
            #expect(result.generation == nil && result.highestGeneration == 0 && result.usesBundledDefaults)
            #expect(result.roles.releaseAssets.isEmpty)
            #expect(result.diagnostic == (invalidSignature ? .signature : .unavailable))
            #expect(!FileManager.default.fileExists(atPath: location.path))
        }
    }
}
