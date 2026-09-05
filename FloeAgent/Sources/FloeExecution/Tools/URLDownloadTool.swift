// FloeExecution — network.download agent tool.
//
// Saves a bounded public HTTPS (or explicitly enabled LAN) GET response
// directly into the task workspace. The file never exists partially: the
// service downloads to a sandbox temporary file first, enforces the byte
// cap, and only then moves it beside the user's files.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

/// Downloads a URL straight into the workspace without routing the payload
/// through the model context.
public struct URLDownloadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var url: String
        public var destination: String
        public var maxBytes: Int?
        public var timeout: Double?
        public var localNetwork: Bool?

        public init(
            url: String,
            destination: String,
            maxBytes: Int? = nil,
            timeout: Double? = nil,
            localNetwork: Bool? = nil
        ) {
            self.url = url
            self.destination = destination
            self.maxBytes = maxBytes
            self.timeout = timeout
            self.localNetwork = localNetwork
        }
    }

    public static let name = "network.download"
    public static let toolDescription =
        "Download a URL directly into the task workspace as a new file (GET only). Public endpoints require HTTPS; set localNetwork only for a user-requested LAN target. The download is size-capped (default 32 MB, max 64 MB), every redirect is revalidated, and an existing destination is never overwritten. Prefer this over network.http when the content belongs in a file rather than in the conversation."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "url": {"type": "string", "description": "HTTPS URL or local HTTP diagnostic endpoint to download"},
        "destination": {"type": "string", "description": "Workspace-relative output path; must not already exist"},
        "maxBytes": {"type": "integer", "description": "Download cap in bytes (default 33554432, max 67108864)"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 60, max 120)"},
        "localNetwork": {"type": "boolean", "description": "Enable only for a local-network target requested by the user"}
      },
      "required": ["url", "destination"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let defaultMaxBytes = 32 * 1_024 * 1_024
    static let defaultTimeout: TimeInterval = 60

    private let service: HTTPRequestService

    public init(service: HTTPRequestService = HTTPRequestService()) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        guard let url = URL(string: args.url), !args.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("url must be a valid http/https URL")
        }
        do {
            if args.localNetwork == true { try DiagnosticNetworkTargetPolicy.validate(url) }
            else { try PublicNetworkTargetPolicy.validate(url) }
        } catch {
            throw FloeError.validationFailed(error.localizedDescription)
        }
        let destination = args.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, !destination.hasPrefix("/"), !destination.hasPrefix("~"),
              !destination.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed("destination must be a workspace-relative path")
        }
        if let maxBytes = args.maxBytes, maxBytes <= 0 {
            throw FloeError.validationFailed("maxBytes must be > 0")
        }
        if let timeout = args.timeout, timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let url = URL(string: args.url) else {
            return Self.output("status=error error=\(HTTPRequestError.invalidURL(args.url).localizedDescription)", exitStatus: 2)
        }
        guard let root = context.workspaceRootURL else {
            return Self.output("status=error error=No task workspace is available", exitStatus: 2)
        }
        do {
            try context.authorizeWorkspacePath(args.destination)
            let guarder = WorkspacePathGuard(rootURL: root)
            let destination = try guarder.resolve(args.destination)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw FloeError.validationFailed("Destination already exists: \(args.destination)")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let transport = args.localNetwork == true ? HTTPRequestService(allowsPrivateNetwork: true) : service
            let result = try await transport.download(
                url: url,
                timeout: args.timeout ?? Self.defaultTimeout,
                maxBytes: args.maxBytes ?? Self.defaultMaxBytes,
                to: destination
            )
            let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return Self.output(
                "status=ok path=\(args.destination) statusCode=\(result.statusCode) contentType=\(result.contentType) bytes=\(result.byteCount) sha256=\(digest)",
                exitStatus: 0
            )
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
