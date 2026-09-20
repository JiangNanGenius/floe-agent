// FloeApp — Linux component update-needed state.
import Foundation

enum LinuxComponentUpdatePolicy {
    // Keep aligned with LinuxGuestFraming.requiredProtocol and the guest runner.
    static let minimumRunnerProtocol = 3

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

    /// Missing installation is handled by the download UI. An installed
    /// manifest without protocol metadata predates the concurrent runner.
    static func updateNeededReason(manifestData: Data?) -> String? {
        guard let manifestData else { return nil }
        let updateReason = String(localized: "environment.backend.update_needed")
        guard let metadata = try? JSONDecoder().decode(RunnerMetadata.self, from: manifestData) else {
            return updateReason
        }
        let capabilityProtocol = metadata.runnerCapabilities?
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix("protocol=") })
            .flatMap { Int($0.dropFirst("protocol=".count)) }
        guard let version = capabilityProtocol ?? metadata.runner?.protocolVersion,
              version >= minimumRunnerProtocol else { return updateReason }
        return nil
    }
}
