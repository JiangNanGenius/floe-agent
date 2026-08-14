// FloeCore — Runtime capability probe contract.
// See docs/ARCHITECTURE_SETTINGS.md §3.3. P2 ships honest probes (JS via
// JavaScriptCore presence, Python unavailable until P3); P3 replaces the
// implementations without touching the UI.

import Foundation

/// Result of probing a runtime capability.
public enum CapabilityState: Sendable, Hashable {
    /// The capability is usable; carries a version string when known.
    case available(version: String)
    /// The capability is definitively absent or gated; the reason is shown
    /// to the user verbatim (honest-unavailable rule).
    case unavailable(reason: String)
    /// The probe could not determine the state.
    case unknown
}

/// Probes one runtime capability (JS engine, local Python, remote Python…).
/// Implementations must be side-effect free and must never fabricate
/// availability — unimplemented capabilities report `.unavailable`.
public protocol CapabilityProbe: Sendable {
    /// Stable display/identifier name (e.g. "javascript", "python.local").
    var name: String { get }
    /// Performs the probe. Must be safe to call on every settings load.
    func probe() async -> CapabilityState
}
