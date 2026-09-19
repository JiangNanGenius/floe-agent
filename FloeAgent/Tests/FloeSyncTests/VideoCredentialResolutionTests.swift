import Foundation
import Testing
import FloeCore
import FloeSecurity
@testable import FloeSync

/// Video-generation jobs persist a `SecretReference` snapshot at submission
/// and must resolve it against the same secrets namespace as chat, image
/// generation and the speed test. These tests are hermetic: a fake reader
/// stands in for the Keychain, so no real secret is ever read, written or
/// printed, and no network call is made.
@Suite("Video credential reference resolution")
struct VideoCredentialResolutionTests {
    /// Records every (account, synchronizable) lookup so tests can pin both
    /// the fallback order and the absence of legacy-namespace reads.
    private final class FakeReader: @unchecked Sendable {
        var lookups: [(account: String, synchronizable: Bool)] = []
        var values: [Bool: Data] = [:]
        func read(account: String, synchronizable: Bool) -> Data? {
            lookups.append((account, synchronizable))
            return values[synchronizable]
        }
    }

    @Test("declared synchronizable scope is read first, the other scope falls back")
    func declaredScopePreferredWithFallback() {
        let reference = SecretReference(keychainAccount: "provider.fake", synchronizable: true)
        let fake = FakeReader()

        // Local-only value still resolves through the synchronizable-first
        // fallback (the common device-local opt-out shape).
        fake.values = [false: Data("fake-local-key".utf8)]
        let resolved = KeychainSecretStore.readSecret(reference: reference) {
            fake.read(account: $0, synchronizable: $1)
        }
        #expect(resolved == Data("fake-local-key".utf8))
        #expect(fake.lookups.count == 2)
        #expect(fake.lookups[0].synchronizable == true)
        #expect(fake.lookups[1].synchronizable == false)

        // When both scopes hold the value, the declared scope wins and no
        // second lookup happens.
        fake.values = [true: Data("fake-sync-key".utf8), false: Data("fake-local-key".utf8)]
        fake.lookups.removeAll()
        #expect(KeychainSecretStore.readSecret(reference: reference) {
            fake.read(account: $0, synchronizable: $1)
        } == Data("fake-sync-key".utf8))
        #expect(fake.lookups.count == 1)

        // Declared-local references prefer the local scope.
        let localReference = SecretReference(keychainAccount: "provider.fake", synchronizable: false)
        fake.lookups.removeAll()
        #expect(KeychainSecretStore.readSecret(reference: localReference) {
            fake.read(account: $0, synchronizable: $1)
        } == Data("fake-local-key".utf8))
        #expect(fake.lookups.first?.synchronizable == false)
    }

    @Test("a missing secret stays missing and only the two canonical scopes are consulted")
    func missingSecretStaysMissing() {
        let reference = SecretReference(keychainAccount: "provider.fake-missing", synchronizable: true)
        let fake = FakeReader()
        let resolved = KeychainSecretStore.readSecret(reference: reference) {
            fake.read(account: $0, synchronizable: $1)
        }
        #expect(resolved == nil)
        // Exactly one account was probed, in both synchronizable scopes —
        // never a third (legacy) namespace.
        #expect(fake.lookups.map(\.account) == ["provider.fake-missing", "provider.fake-missing"])
        #expect(Set(fake.lookups.map(\.synchronizable)) == [true, false])
    }

    @Test("two provider routes resolve only their own fake credential")
    func multiProviderRoutesAreIndependent() {
        let ark = FakeReader()
        ark.values = [false: Data("fake-ark-key".utf8)]
        let arkReference = SecretReference(keychainAccount: "provider.fake-ark", synchronizable: true)
        let google = FakeReader()
        google.values = [true: Data("fake-google-key".utf8)]
        let googleReference = SecretReference(keychainAccount: "provider.fake-google", synchronizable: false)

        let arkKey = KeychainSecretStore.readSecret(reference: arkReference) {
            ark.read(account: $0, synchronizable: $1)
        }
        let googleKey = KeychainSecretStore.readSecret(reference: googleReference) {
            google.read(account: $0, synchronizable: $1)
        }
        #expect(arkKey == Data("fake-ark-key".utf8))
        #expect(googleKey == Data("fake-google-key".utf8))
        #expect(arkKey != googleKey)
        #expect(ark.lookups.map(\.account) == ["provider.fake-ark", "provider.fake-ark"])
        #expect(google.lookups.map(\.account) == ["provider.fake-google", "provider.fake-google"])
    }

    @Test("the canonical namespace stays coherent across modules")
    func namespaceCoherence() {
        // The video path must read the namespace the vault and the provider
        // editor actually write; the legacy "org.floeagent.ios.providers"
        // namespace is never a valid source. A fresh default store keeps
        // using that canonical namespace.
        #expect(KeychainSecretStore.defaultService == "org.floeagent.ios.secrets")
        #expect(CredentialVaultService.serviceName == KeychainSecretStore.defaultService)
    }
}
