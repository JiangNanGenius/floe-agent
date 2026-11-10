// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeProviders

/// Review state is shared by onboarding and Settings. Merely opening an
/// editor never acknowledges an update; only its successful local save does.
/// The state itself now lives in the shared `ProviderCatalogReviewService`
/// (same code path the provider list uses for legacy detection, deferral and
/// prompt dedupe); this wrapper keeps the App call sites unchanged.
@MainActor
enum ProviderCatalogReviewStore {
    static func signature(_ entry: ProviderCatalogEntry) -> String? {
        ProviderCatalogReviewService.signature(entry)
    }

    static func recordSaved(providerID: UUID, entry: ProviderCatalogEntry, defaults: UserDefaults = .standard) {
        ProviderCatalogReviewService.recordSaved(providerID: providerID, entry: entry, defaults: defaults)
    }
}
