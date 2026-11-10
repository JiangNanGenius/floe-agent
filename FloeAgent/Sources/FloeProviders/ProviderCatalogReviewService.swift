// FloeProviders — the single reviewed-catalog-update state shared by the
// provider list, onboarding and the provider editor.
//
// RQ06 contract implemented here once, for BOTH update sources: the ACTIVE
// catalog (installed remote document or the built-in baseline that wins after
// an App upgrade — `ContentUpdateCenter.providerCatalogIndex()` hands the
// same value to every entry point) is hashed per provider entry; a provider
// is "unreviewed" while its recorded signature differs from that hash.
//
//   * Merely opening or cancelling a review never acknowledges an update:
//     only `recordSaved` (called after a successful local save) writes.
//   * A legacy installation has no recorded signature, so the first bundled
//     upgrade after an App update is flagged, never silently acknowledged.
//   * An unchanged pending batch presents its prompt at most once
//     (`shouldPresentPrompt`), while the persistent list section keeps a
//     deferred batch re-viewable.
//   * Stored key layout matches the pre-existing `providers.catalog.*`
//     defaults so existing installations keep their reviewed history.
//
// Pure and injectable (UserDefaults parameter) so the exact behaviour is
// testable off-device with synthetic fixtures.

import Foundation
import FloeCore

public enum ProviderCatalogReviewService {
    /// Default-storage key layout (byte-identical to the previous inline
    /// view/store strings; old reviewed signatures must survive this move).
    public static let reviewedKeyPrefix = "providers.catalog.reviewed."
    public static let lastPresentedKey = "providers.catalog.lastPresentedUpdate"

    public static func reviewedKey(_ providerID: UUID) -> String {
        reviewedKeyPrefix + providerID.uuidString
    }

    /// Deterministic identity of one catalog entry as currently offered.
    /// Any visible field change (models, metadata, availability, endpoints)
    /// produces a different signature; an unencodable entry yields nil,
    /// which callers must treat as "nothing to review", never as a change.
    public static func signature(_ entry: ProviderCatalogEntry) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return nil }
        return FloeDigest.sha256Hex(data)
    }

    public static func recordedSignature(
        providerID: UUID,
        defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: reviewedKey(providerID))
    }

    /// Records the acknowledgement of a review. Callers invoke this ONLY on
    /// a successful local save of the reviewed entry; opening or cancelling
    /// an editor never reaches here.
    public static func recordSaved(
        providerID: UUID,
        entry: ProviderCatalogEntry,
        defaults: UserDefaults = .standard
    ) {
        guard let signature = signature(entry) else { return }
        defaults.set(signature, forKey: reviewedKey(providerID))
    }

    /// True while the ACTIVE catalog entry differs from the entry the user
    /// last saved. A nil signature (preset not in the catalog) is never
    /// "unreviewed" — there is nothing to review. A legacy installation
    /// without any recorded signature is unreviewed from the first bundled
    /// or remote change and stays unreviewed until a real save acknowledges
    /// it (so a deferral, an editor open or a cancel cannot dismiss it).
    public static func isUnreviewed(
        providerID: UUID,
        signature: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let signature else { return false }
        return recordedSignature(providerID: providerID, defaults: defaults) != signature
    }

    /// Deterministic identity of the currently pending review batch: the
    /// metadata proposals first, then the catalog signatures, each joined in
    /// the exact order the UI presents them. Same pending content always
    /// yields the same identity, any real change always yields another.
    public static func updateIdentity(
        metadata: [String],
        catalogSignatures: [String]
    ) -> String {
        FloeDigest.sha256Hex(
            Data((metadata.joined(separator: "\n")
                  + catalogSignatures.joined(separator: "\n")).utf8))
    }

    /// Presents a batch at most once per identity: unchanged pending data
    /// never reopens the prompt, while a deferred batch stays re-viewable
    /// through the persistent list sections. Records before returning true.
    public static func shouldPresentPrompt(
        identity: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.string(forKey: lastPresentedKey) != identity else { return false }
        defaults.set(identity, forKey: lastPresentedKey)
        return true
    }
}
