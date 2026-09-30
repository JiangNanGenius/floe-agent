// FloeApp — Linux component update-needed state.
import Foundation

enum LinuxComponentUpdatePolicy {
    // Keep aligned with LinuxGuestFraming.requiredProtocol and the guest runner.
    static let minimumRunnerProtocol = 3

    /// The truthful three-state answer, derived ONLY from what the installed
    /// manifest declares. The current published SMP image
    /// (`floe-debian13-riscv64-202609202607-basic-…`, release
    /// floe-linux-guest-smp-20260928.1) ships a manifest with NO runner or
    /// runnerCapabilities fields at all, so absence can never be read as
    /// "predates the concurrent runner": that reading falsely labelled the
    /// fresh image obsolete. Absence means not declared.
    enum RunnerState: String, Sendable, Equatable {
        /// The manifest declares a runner protocol at or above this build's
        /// minimum: evidence-backed current.
        case current
        /// The manifest declares a runner protocol below the minimum: the
        /// explicit, evidence-backed update state.
        case outdated
        /// The manifest declares no runner metadata (or none that decodes).
        /// Nothing is invented from silence: the boot handshake — never this
        /// policy — stays the authority for an undeclared runner, and the UI
        /// must not claim "outdated" without evidence.
        case undeclared
    }

    private struct RunnerMetadata: Decodable {
        struct Runner: Decodable {
            var protocolVersion: Int?
            enum CodingKeys: String, CodingKey {
                case protocolVersion = "protocol"
            }
        }
        var runner: Runner?
        var runnerCapabilities: String?
    }

    /// Source of truth: manifest bytes → runner state. A manifest that is
    /// absent or does not decode declares nothing → `.undeclared`, never
    /// `.outdated`.
    static func runnerState(manifestData: Data?) -> RunnerState {
        guard let manifestData else { return .undeclared }
        guard let metadata = try? JSONDecoder().decode(RunnerMetadata.self, from: manifestData) else {
            return .undeclared
        }
        let capabilityProtocol = metadata.runnerCapabilities?
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix("protocol=") })
            .flatMap { Int($0.dropFirst("protocol=".count)) }
        guard let version = capabilityProtocol ?? metadata.runner?.protocolVersion else {
            return .undeclared
        }
        return version >= minimumRunnerProtocol ? .current : .outdated
    }

    /// The update-needed reason the UI surfaces: non-nil ONLY for the
    /// evidence-backed `.outdated` state. `.current` and `.undeclared` both
    /// answer nil — the latter is not a claim of currency, just the absence
    /// of an outdated claim.
    static func updateNeededReason(manifestData: Data?) -> String? {
        guard runnerState(manifestData: manifestData) == .outdated else { return nil }
        return String(localized: "environment.backend.update_needed")
    }
}
