// FloeProvidersTests — RQ06 reviewed-catalog-update state service.
//
// Synthetic fixtures only: injected UserDefaults suites, hand-built catalog
// entries and a fixed UUID. No network, no real keys, no shared storage and
// no dependency on the checkout's bundled catalog. Covers the exact states
// the acceptance scenarios name: legacy user without an old signature, first
// bundled upgrade never silently acknowledged, deferral (open/cancel) that
// does not acknowledge, acknowledgement only after a successful save, a
// remote update after acknowledgement re-opening the review, unchanged data
// presenting at most once, and the stored key layout staying byte-identical
// so upgraded installations keep their reviewed history.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

private func syntheticEntry(
    presetID: String = "synthetic.provider",
    name: String = "Synthetic Provider",
    models: [String] = ["synthetic-model-a"],
    availability: ProviderCatalogAvailability = .available
) -> ProviderCatalogEntry {
    ProviderCatalogEntry(
        presetID: presetID,
        name: name,
        kind: .openAI,
        defaultProtocol: .openAIChatCompletions,
        baseURL: URL(string: "https://synthetic.invalid/v1"),
        models: models,
        availability: availability,
        unsupportedReason: nil,
        upstreamID: presetID,
        authStyle: "bearer",
        serviceOffers: nil,
        modelMetadata: nil
    )
}

private func isolatedSuite(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("FloeProviders.CatalogReviewState")
struct ProviderCatalogReviewServiceTests {

    @Test("Signature is deterministic and sensitive to visible entry content")
    func signatureStability() throws {
        let entry = syntheticEntry()
        let first = try #require(ProviderCatalogReviewService.signature(entry))
        let second = try #require(ProviderCatalogReviewService.signature(entry))
        #expect(first == second, "same entry must not look like an update")
        // A new offered model is a content change.
        #expect(ProviderCatalogReviewService.signature(
            syntheticEntry(models: ["synthetic-model-a", "synthetic-model-b"])) != first)
        // An availability change is a content change.
        #expect(ProviderCatalogReviewService.signature(
            syntheticEntry(availability: .unsupported)) != first)
        // A display name change is a content change.
        #expect(ProviderCatalogReviewService.signature(
            syntheticEntry(name: "Renamed Synthetic")) != first)
    }

    @Test("Stored key layout stays byte-identical for upgraded installations")
    func keyLayoutCompatibility() {
        let providerID = UUID(uuidString: "8F0A9C5E-3B2D-4E6F-9A01-7B5D3E1F2A40")!
        #expect(
            ProviderCatalogReviewService.reviewedKey(providerID)
                == "providers.catalog.reviewed.8F0A9C5E-3B2D-4E6F-9A01-7B5D3E1F2A40")
        #expect(ProviderCatalogReviewService.lastPresentedKey == "providers.catalog.lastPresentedUpdate")
    }

    @Test("Legacy install: no old signature flags the first bundled upgrade; open/cancel never acknowledge")
    func legacyFirstBundledUpgradeIsNotSilentlyAcknowledged() throws {
        let defaults = isolatedSuite("FloeRQ06.legacy")
        let providerID = UUID()
        let entry = syntheticEntry()
        let signature = try #require(ProviderCatalogReviewService.signature(entry))
        // Old user, new App: nothing recorded yet. The bundled catalog entry
        // IS pending review — detection must not treat "no old signature" as
        // "acknowledged".
        #expect(ProviderCatalogReviewService.recordedSignature(providerID: providerID, defaults: defaults) == nil)
        #expect(ProviderCatalogReviewService.isUnreviewed(
            providerID: providerID, signature: signature, defaults: defaults))
        // Merely opening the editor / cancelling records nothing (the App
        // only calls recordSaved on a successful local save).
        #expect(ProviderCatalogReviewService.isUnreviewed(
            providerID: providerID, signature: signature, defaults: defaults))
        // A successful save acknowledges exactly the entry the user saw.
        ProviderCatalogReviewService.recordSaved(providerID: providerID, entry: entry, defaults: defaults)
        #expect(!ProviderCatalogReviewService.isUnreviewed(
            providerID: providerID, signature: signature, defaults: defaults))
    }

    @Test("Remote update after acknowledgement re-opens the review")
    func remoteUpdateAfterAckReopensReview() throws {
        let defaults = isolatedSuite("FloeRQ06.remote")
        let providerID = UUID()
        let first = syntheticEntry()
        ProviderCatalogReviewService.recordSaved(providerID: providerID, entry: first, defaults: defaults)
        let firstSignature = try #require(ProviderCatalogReviewService.signature(first))
        #expect(!ProviderCatalogReviewService.isUnreviewed(
            providerID: providerID, signature: firstSignature, defaults: defaults))
        // Remote refresh installs a catalog whose entry now carries an extra
        // model: the acknowledged signature no longer matches.
        let updated = syntheticEntry(models: ["synthetic-model-a", "synthetic-model-b"])
        let updatedSignature = try #require(ProviderCatalogReviewService.signature(updated))
        #expect(ProviderCatalogReviewService.isUnreviewed(
            providerID: providerID, signature: updatedSignature, defaults: defaults))
        // Bundled-version change and remote change are the SAME detection:
        // both arrive as a different signature of the ACTIVE entry.
        ProviderCatalogReviewService.recordSaved(providerID: providerID, entry: updated, defaults: defaults)
        #expect(!ProviderCatalogReviewService.isUnreviewed(
            providerID: providerID, signature: updatedSignature, defaults: defaults))
    }

    @Test("Provider without a catalog entry is never flagged")
    func missingEntryNeverFlagged() {
        let defaults = isolatedSuite("FloeRQ06.missing")
        #expect(!ProviderCatalogReviewService.isUnreviewed(
            providerID: UUID(), signature: nil, defaults: defaults))
    }

    @Test("Pending identity is order/content deterministic")
    func updateIdentityDeterministic() {
        let meta = ["model-1:vision:0", "model-2:vision:1048576"]
        let signatures = ["signature-a", "signature-b"]
        let first = ProviderCatalogReviewService.updateIdentity(metadata: meta, catalogSignatures: signatures)
        let second = ProviderCatalogReviewService.updateIdentity(metadata: meta, catalogSignatures: signatures)
        #expect(first == second, "unchanged pending batch must produce the same identity")
        #expect(
            ProviderCatalogReviewService.updateIdentity(
                metadata: Array(meta.reversed()), catalogSignatures: signatures) != first,
            "presentation order changes the identity of the batch")
        #expect(
            ProviderCatalogReviewService.updateIdentity(
                metadata: meta, catalogSignatures: ["signature-a"]) != first,
            "one acknowledged provider must change the identity")
        #expect(
            ProviderCatalogReviewService.updateIdentity(metadata: [], catalogSignatures: []) != first)
    }

    @Test("Unchanged pending data presents at most once; changed data presents again")
    func promptPresentsOncePerIdentity() {
        let defaults = isolatedSuite("FloeRQ06.dedupe")
        let identity = ProviderCatalogReviewService.updateIdentity(
            metadata: ["m1:vision:0"], catalogSignatures: ["s1"])
        #expect(ProviderCatalogReviewService.shouldPresentPrompt(identity: identity, defaults: defaults))
        // Same pending content on the next task/on-change pass: no second popup.
        #expect(!ProviderCatalogReviewService.shouldPresentPrompt(identity: identity, defaults: defaults))
        // A genuinely different batch (e.g. after deferral one provider got
        // saved, or a remote refresh adds changes): presents once again.
        let changed = ProviderCatalogReviewService.updateIdentity(
            metadata: ["m1:vision:0", "m2:vision:0"], catalogSignatures: ["s1"])
        #expect(ProviderCatalogReviewService.shouldPresentPrompt(identity: changed, defaults: defaults))
        #expect(!ProviderCatalogReviewService.shouldPresentPrompt(identity: changed, defaults: defaults))
    }

    @Test("Injected suites never touch the shared standard defaults")
    func storageIsolation() throws {
        let providerID = UUID()
        let key = ProviderCatalogReviewService.reviewedKey(providerID)
        UserDefaults.standard.removeObject(forKey: key)
        let defaults = isolatedSuite("FloeRQ06.isolation")
        ProviderCatalogReviewService.recordSaved(providerID: providerID, entry: syntheticEntry(), defaults: defaults)
        #expect(UserDefaults.standard.string(forKey: key) == nil)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
