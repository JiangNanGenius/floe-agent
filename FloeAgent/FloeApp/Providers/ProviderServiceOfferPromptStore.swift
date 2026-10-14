// FloeApp — Decline memory for the optional multi-service provider prompt.
//
// The editor may offer to configure additional image/video roles for a
// provider whose kind has a real shipped adapter. The prompt is shown once:
// after the user declines a role, that role is not offered again for the same
// provider identity. This store holds only non-secret preference bits.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

/// Persists the per-provider set of declined optional service roles.
///
/// `@unchecked Sendable`: the store holds only `UserDefaults`, which is
/// documented thread-safe for its read/write operations, and no other mutable
/// state; it is used from the MainActor editor view model in practice.
struct ProviderServiceOfferPromptStore: @unchecked Sendable {
    static let shared = ProviderServiceOfferPromptStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for providerID: UUID) -> String {
        "providers.serviceOffer.declined.\(providerID.uuidString)"
    }

    /// Roles the user already declined for this provider.
    func declinedRoles(for providerID: UUID) -> Set<ProviderServiceRole> {
        let raw = defaults.string(forKey: key(for: providerID)) ?? ""
        return Set(
            raw.split(separator: ",").compactMap {
                ProviderServiceRole(rawValue: String($0))
            }
        )
    }

    /// Records a decline. Idempotent; unknown roles are ignored by the raw
    /// value mapping.
    func recordDecline(roles: Set<ProviderServiceRole>, for providerID: UUID) {
        guard !roles.isEmpty else { return }
        var current = declinedRoles(for: providerID)
        current.formUnion(roles)
        let value = current.map(\.rawValue).sorted().joined(separator: ",")
        defaults.set(value, forKey: key(for: providerID))
    }

    /// Removes the memory (used when the provider is deleted).
    func clear(for providerID: UUID) {
        defaults.removeObject(forKey: key(for: providerID))
    }
}
#endif
