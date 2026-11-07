// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Security
import Testing
import FloeSecurity
@testable import FloeApp

@Suite("APNs native key callback lifecycle", .serialized)
@MainActor struct APNsNativeKeyLifecycleTests {
    @MainActor private final class NativeCalls {
        var generating: CheckedContinuation<String, Error>?
        var generateCount = 0
        var objectKeys: [String] = []
        var oldInvalid = false
        var operations: APNsAppAttestOperations {
            .init(isSupported: { true }, generateKey: {
                self.generateCount += 1
                return try await withCheckedThrowingContinuation { self.generating = $0 }
            }, object: { key, _, _ in
                self.objectKeys.append(key)
                if self.oldInvalid && key == "old-key" { throw APNsNativeAttestFailure.invalidKey }
                return Data([1, 2, 3, 4])
            })
        }
        func generated(_ id: String) { let value = generating; generating = nil; value?.resume(returning: id) }
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

    @Test("Cancelled late initial/allowed-rotation key success is saved before cancellation and the next retry reuses it")
    func lateGenerateIsRetainedAndReused() async throws {
        for rotation in [false, true] {
            let service = "org.floeagent.fixture.apns-key-\(UUID().uuidString.lowercased())"
            defer { removeFixture(service) }
            let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            let installationID = UUID(), prefix = installationID.uuidString.lowercased()
            let account = prefix + "/app-attest-key"
            let secret = Data(repeating: 0x42, count: 32), token = Data(repeating: 0x43, count: 32)
            try vault.store(account: prefix + "/credential", secret: secret)
            try vault.store(account: prefix + "/token", secret: token)
            if rotation { try vault.store(account: account, secret: JSONSerialization.data(withJSONObject: ["id": "old-key", "confirmed": true])) }
            let calls = NativeCalls(); calls.oldInvalid = rotation
            let provider = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
            let first = Task { try await provider.proof(installationID: installationID, clientDataHash: Data(repeating: 1, count: 32),
                preference: rotation ? .attestationAfterServerUnknown : .automatic) }
            try await wait { calls.generating != nil }
            // A second caller cannot create another native worker while the
            // original successful callback is still outstanding.
            do { _ = try await provider.proof(installationID: installationID, clientDataHash: Data(repeating: 2, count: 32), preference: .automatic); Issue.record("Concurrent key worker started") }
            catch APNsServiceError.enrollmentPending {}
            first.cancel()
            calls.generated("late-success-key")
            do { _ = try await first.value; Issue.record("Cancelled native proof continued") }
            catch is CancellationError {}
            #expect(try record(vault, account)["id"] as? String == "late-success-key")
            #expect(!calls.objectKeys.contains("late-success-key")) // No attest after cancellation.
            let retry = try await provider.proof(installationID: installationID, clientDataHash: Data(repeating: 3, count: 32), preference: .automatic)
            #expect(retry.keyID == "late-success-key" && calls.generateCount == 1)
            #expect(calls.objectKeys.last == "late-success-key")
            #expect(try vault.read(account: prefix + "/credential") == secret)
            #expect(try vault.read(account: prefix + "/token") == token)
        }
    }

    @Test("A late successful generation cannot overwrite a newer canonical key; its actual ID remains recoverable")
    func newerKeyIsNotOverwritten() async throws {
        let service = "org.floeagent.fixture.apns-key-cas-\(UUID().uuidString.lowercased())"
        defer { removeFixture(service) }
        let vault = KeychainStore(service: service, synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
        let installationID = UUID(), account = installationID.uuidString.lowercased() + "/app-attest-key"
        let calls = NativeCalls()
        let native = APNsNativeInstallationProofs(vault: vault, native: calls.operations)
        let first = Task { try await native.proof(installationID: installationID, clientDataHash: Data(repeating: 4, count: 32), preference: .automatic) }
        try await wait { calls.generating != nil }
        try vault.store(account: account, secret: JSONSerialization.data(withJSONObject: ["id": "newer-valid-key", "confirmed": true]))
        first.cancel(); calls.generated("late-older-key")
        do { _ = try await first.value; Issue.record("Cancelled old native worker continued") }
        catch is CancellationError {}
        #expect(try record(vault, account)["id"] as? String == "newer-valid-key")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true, kSecReturnData as String: true]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let rows = try #require(result as? [[String: Any]])
        let savedIDs = rows.compactMap { $0[kSecValueData as String] as? Data }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? String
        }
        #expect(savedIDs.contains("newer-valid-key") && savedIDs.contains("late-older-key"))
        #expect(calls.generateCount == 1 && calls.objectKeys.isEmpty)
    }
}
#endif
