// FloeExecution — environment.prepareLinux agent tool.
//
// Explicit capability that prepares (downloads, verifies and installs) the
// App-shared Linux environment image. The model calls it when execution
// needs Linux; the handler is injected by the app and never accepts an
// arbitrary image URL or install script.

import Foundation
import FloeCore
import FloeTools

/// Request handed to the app-provided preparation handler.
public struct LinuxPreparationRequest: Sendable {
    public let environmentID: String?
    public let cancellation: CancellationToken

    public init(environmentID: String?, cancellation: CancellationToken) {
        self.environmentID = environmentID
        self.cancellation = cancellation
    }
}

/// App-supplied handler that prepares the Linux image and returns a
/// truthful status string.
public typealias LinuxPreparationHandler = @Sendable (LinuxPreparationRequest) async throws -> String

public struct PrepareLinuxEnvironmentTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public init() {}
    }

    public static let name = "environment.prepareLinux"
    public static let toolDescription =
        "Prepare this device's Linux environment: download, verify and install the App-provided Linux image required to run Linux commands, Python 3, Node, apt packages or services. Call it explicitly when Linux is needed and the image is not installed, then wait for the result and resume the original command. The image is App-provided; no URL, script or custom image is accepted. Returns an honest failure with the reason when storage is unavailable, space is insufficient, the digest does not match, or the download is cancelled."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let prepare: LinuxPreparationHandler

    public init(prepare: @escaping LinuxPreparationHandler) {
        self.prepare = prepare
    }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let status = try await prepare(
                LinuxPreparationRequest(
                    environmentID: context.environmentID ?? context.environment?.id,
                    cancellation: context.cancellation
                )
            )
            return ToolExecutionOutput(digesting: "status=prepared\n\(status)", exitStatus: 0)
        } catch FloeError.cancelled {
            return ToolExecutionOutput(digesting: "status=cancelled", exitStatus: 130)
        } catch let installError as LinuxGuestImageInstallError {
            if case .cancelled = installError {
                return ToolExecutionOutput(digesting: "status=cancelled", exitStatus: 130)
            }
            return ToolExecutionOutput(
                digesting: "exit=125 status=prepareFailed\n\(installError.localizedDescription)",
                exitStatus: 125
            )
        }
    }
}
