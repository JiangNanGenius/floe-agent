import Foundation
import Crypto
import FloeCore
import FloeTools

/// Idempotent setup flow for a disposable Linux task-container environment.
public struct SSHBootstrapExecutionHostTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String?
        public var apply: Bool?
        public var installContainerRuntime: Bool?

        public init(hostID: String? = nil, apply: Bool? = nil, installContainerRuntime: Bool? = nil) {
            self.hostID = hostID
            self.apply = apply
            self.installContainerRuntime = installContainerRuntime
        }
    }

    public static let name = "ssh.bootstrapExecutionHost"
    public static let toolDescription =
        "Plan or apply Floe's standard remote Linux execution environment. It classifies the target first, creates a per-user task directory, optionally installs Docker through the detected system package manager, pulls the fixed Ubuntu task image, and runs a bounded non-privileged health check. Default is plan-only. Apply only after the user authorizes host environment changes; this never runs on switches, routers, firewalls, macOS, Windows or unknown targets."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"},"apply":{"type":"boolean","description":"False by default; true performs host changes after approval"},"installContainerRuntime":{"type":"boolean","description":"When applying, install Docker if absent using apt/dnf/yum; default false"}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.executesRemoteCommand, .modifiesRemoteSystem, .networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: SSHCommandService
    public init(service: SSHCommandService) { self.service = service }

    public func validate(_ args: Arguments) throws {
        if let hostID = args.hostID, UUID(uuidString: hostID) == nil {
            throw FloeError.validationFailed("hostID must be a UUID when provided")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let hostID = args.hostID.flatMap(UUID.init(uuidString:))
        let inspection = try await service.inspectTarget(hostID: hostID, cancellation: context.cancellation)
        guard inspection.kind == .linux || inspection.kind == .nas else {
            return Self.output("status=unsupportedTarget kind=\(inspection.kind.rawValue); bootstrap is limited to Linux shell hosts", code: 64)
        }
        guard args.apply == true else {
            return Self.output(
                "status=planOnly kind=\(inspection.kind.rawValue) containerRuntime=\(inspection.containerRuntime?.rawValue ?? "missing") steps=classify,create_user_task_directory,install_runtime_if_authorized,pull_fixed_ubuntu_image,nonprivileged_health_check,register_capabilities rollback=remove_~/.floe/tasks_and_optional_runtime",
                code: 0
            )
        }

        var script = "set -eu; mkdir -p \"$HOME/.floe/tasks\"; "
        if inspection.containerRuntime == nil {
            guard args.installContainerRuntime == true else {
                return Self.output("status=runtimeMissing; rerun with installContainerRuntime=true after explicit host-change approval", code: 78)
            }
            script += "if command -v apt-get >/dev/null; then sudo apt-get update && sudo apt-get install -y docker.io; "
            script += "elif command -v dnf >/dev/null; then sudo dnf install -y docker; "
            script += "elif command -v yum >/dev/null; then sudo yum install -y docker; "
            script += "else echo 'status=unsupportedPackageManager' >&2; exit 69; fi; "
        }
        script += "_floe_runtime=$(command -v docker || command -v podman); "
        script += "$_floe_runtime pull ubuntu:24.04; "
        script += "$_floe_runtime run --rm --network none --cpus 1 --memory 256m --pids-limit 64 --security-opt no-new-privileges ubuntu:24.04 sh -lc 'printf floe-container-ready'; "
        script += "printf '\\nstatus=ready taskDirectory=%s\\n' \"$HOME/.floe/tasks\""
        let result = try await service.run(
            command: script,
            hostID: inspection.hostID,
            timeout: 120,
            maxOutputBytes: 64 * 1024,
            cancellation: context.cancellation
        )
        return Self.output("targetKind=\(inspection.kind.rawValue) exitCode=\(result.exitCode)\n\(result.stdout)\n\(result.stderr)", code: result.exitCode)
    }

    private static func output(_ text: String, code: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: code)
    }
}
