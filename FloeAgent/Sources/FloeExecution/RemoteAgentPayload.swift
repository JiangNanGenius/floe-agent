import Foundation

/// App-bundled, same-repository payload for the optional long-lived SSH host
/// helper. The exact files shipped in the app are also packaged as GitHub
/// Release assets by `scripts/package_remote_agent.sh`.
public enum RemoteAgentPayload {
    public static let version = "1.4.2"
    public static let defaultPort = 43_187
    public static let mutualTLSPort = 43_188

    public enum PayloadError: LocalizedError {
        case missingResource(String)

        public var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                "Bundled Floe remote-agent resource is missing: \(name)"
            }
        }
    }

    public static func agentSource() throws -> String {
        try source(named: "floe_remote_agent", extension: "py")
    }

    public static func updaterSource() throws -> String {
        try source(named: "floe_agent_update", extension: "py")
    }

    private static func source(named name: String, extension ext: String) throws -> String {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "RemoteAgent"
        ) else {
            throw PayloadError.missingResource("\(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
