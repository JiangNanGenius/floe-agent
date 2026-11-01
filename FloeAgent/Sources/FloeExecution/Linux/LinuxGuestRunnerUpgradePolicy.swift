import Foundation

/// Pure compatibility policy for the runner inside a persistent environment
/// disk.
///
/// The LIVE `FLOE-CAPS` answer is the only proof of what the booted runner can
/// do; the runner-upgrade ledger is a record, never live proof. The trusted
/// installed-image manifest may additionally require an additive capability:
/// when `runnerCapabilities` explicitly carries `env=1`, a runner that only
/// answers `protocol=3` is stale for that image and must be replaced through
/// the existing verified in-guest upgrade path. Manifests without an `env`
/// field keep the previous protocol-3 acceptance, so an older image never
/// forces an upgrade it did not ask for.
///
/// This type performs no I/O and owns no installation behaviour. Callers still
/// probe the live runner, require the image's verified artifact, replace only
/// `/usr/local/bin/floe-exec`, and re-verify the post-reboot CAPS.
struct LinuxGuestRunnerUpgradePolicy: Sendable {
    /// The additive capability that a current image explicitly requires. Only
    /// the exact token is honoured; a missing, malformed or different value
    /// is not an explicit `env=1` requirement.
    static let perProcessEnvironmentCapability = "env=1"

    /// Guest protocol this host speaks. Kept aligned with
    /// `LinuxGuestFraming.requiredProtocol`.
    static let minimumProtocolVersion = 3

    enum UpgradeReason: Equatable, Sendable {
        /// The live runner did not answer, or answered an older protocol.
        case legacyRunner
        /// The live runner is protocol-current but lacks a capability the
        /// trusted image manifest explicitly requires.
        case requiredCapabilityMissing(String)
    }

    enum Decision: Equatable, Sendable {
        case current
        case upgrade(UpgradeReason)
    }

    /// Compares one live probe result with the trusted manifest payload.
    ///
    /// `required` is `LinuxGuestImage.runnerCapabilities`; `live` is the CAPS
    /// answer from the booted guest (nil when the probe did not answer).
    ///
    /// - No answer / protocol below 3: upgrade through the legacy path.
    /// - Required metadata has no `env` field: keep the previous protocol-3
    ///   acceptance.
    /// - Required metadata explicitly carries `env=1`: require the live CAPS
    ///   to carry the same capability; a nominal version alone is not enough.
    static func evaluate(required: String?, live: String?) -> Decision {
        guard protocolVersion(in: live) >= minimumProtocolVersion else {
            return .upgrade(.legacyRunner)
        }
        if requiresPerProcessEnvironment(required),
           !declaresPerProcessEnvironment(live) {
            return .upgrade(
                .requiredCapabilityMissing(perProcessEnvironmentCapability)
            )
        }
        return .current
    }

    /// True only when the live answer satisfies the trusted requirement.
    static func satisfies(required: String?, live: String?) -> Bool {
        evaluate(required: required, live: live) == .current
    }

    /// True when the trusted image metadata explicitly requires the additive
    /// per-process environment capability.
    static func requiresPerProcessEnvironment(_ capabilities: String?) -> Bool {
        capabilityTokens(in: capabilities).contains(perProcessEnvironmentCapability)
    }

    /// True when the live CAPS answer advertises the additive capability.
    static func declaresPerProcessEnvironment(_ capabilities: String?) -> Bool {
        capabilityTokens(in: capabilities).contains(perProcessEnvironmentCapability)
    }

    /// First valid `protocol=` field, matching the channel's historical
    /// acceptance: an unparseable token is skipped rather than read as a
    /// lower version, and a missing field is 0.
    static func protocolVersion(in capabilities: String?) -> Int {
        guard let capabilities else { return 0 }
        for field in capabilities.split(whereSeparator: { $0.isWhitespace })
        where field.hasPrefix("protocol=") {
            if let value = Int(field.dropFirst("protocol=".count)) {
                return value
            }
        }
        return 0
    }

    private static func capabilityTokens(in capabilities: String?) -> Set<String> {
        guard let capabilities else { return [] }
        return Set(
            capabilities.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        )
    }
}
