// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools

public struct GitCloneRepositoryTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public let address: String
        public let destination: String?
        public let importAsProject: Bool?
    }
    public static let name = "git.clone"
    public static let toolDescription = "Clone a configured generic HTTPS/SSH/SCP repository into a new task-workspace directory, preserve partial data on failure/cancel, and optionally register it as a native project. Return repositoryPath for subsequent git tools and ordinary workspace/exec.shell paths; never changes the task's execution root or silently switches the UI."
    public static let parametersJSON = #"{"type":"object","properties":{"address":{"type":"string","description":"HTTPS, ssh:// or user@host:relative/repository.git; no secret URL"},"destination":{"type":"string","description":"New directory relative to this task workspace; defaults to the repository name"},"importAsProject":{"type":"boolean","description":"Register successful exact clone as a native project, default true; does not silently open/switch it"}},"required":["address"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles, .networkAccess, .accessesCredentials]
    public static let isSideEffecting = true
    public static let requiresHostScope = false
    private let environment: GitToolEnvironment
    public init(environment: GitToolEnvironment) { self.environment = environment }
    public func validate(_ args: Arguments) throws { _ = try GitRemoteEndpoint(args.address) }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let endpoint = try GitRemoteEndpoint(args.address)
        let relative = args.destination ?? endpoint.suggestedDirectoryName
        try environment.authorize([relative], repositoryPath: nil, context: context)
        let root = try environment.scopedRoot(context: context, repositoryPath: nil)
        let destination = root.appendingPathComponent(relative).standardizedFileURL
        guard destination.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              !FileManager.default.fileExists(atPath: destination.path) else { throw FloeError.validationFailed("Choose a new clone directory inside this task workspace") }
        return try await GitDailyOutput.run(context: context) {
            try await environment.performRemote(endpoint: endpoint, context: context) { authentication in
                try context.cancellation.throwIfCancelled()
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let receipt = try await environment.git.clone(to: destination, authentication: authentication)
                struct Result: Encodable {
                    let state = "cloned"
                    let repositoryPath: String
                    let defaultBranch: String?
                    var projectID: UUID?
                    var projectImportWarning: String?
                }
                var result = Result(repositoryPath: relative, defaultBranch: receipt.defaultBranch)
                if args.importAsProject != false, let importer = environment.projectImporter, !context.cancellation.isCancelled, !Task.isCancelled {
                    do { result.projectID = try await importer(destination, endpoint.suggestedDirectoryName, context) }
                    catch { result.projectImportWarning = SecretRedactor.redact(error.localizedDescription) }
                }
                // The saved clone remains a known result even if optional
                // project registration failed; do not provoke another clone.
                return try GitDailyOutput.make(result)
            }
        }
    }
}
