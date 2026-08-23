// FloeExecution — Generic remote shell command execution over SSH.
//
// Unlike RemotePythonService (which wraps scripts in `python3 -c`), this
// runs an arbitrary command line and returns the raw bounded result so the
// agent can drive the remote host directly (ls, grep, git, npm, …).

import Foundation
import FloeCore
import FloeTools
import FloeSSH

/// Executes arbitrary commands on a paired SSH host. Reuses the same
/// session/host closures as RemotePythonService so production wires them
/// from the shared host store; tests inject fakes.
public struct SSHCommandService: Sendable {
    public typealias SessionFactory = RemotePythonService.SessionFactory
    public typealias HostResolver = RemotePythonService.HostResolver
    public typealias DefaultHostProvider = RemotePythonService.DefaultHostProvider

    private let sessionFactory: SessionFactory
    private let hostResolver: HostResolver
    private let defaultHostProvider: DefaultHostProvider

    public init(
        sessionFactory: @escaping SessionFactory,
        hostResolver: @escaping HostResolver,
        defaultHostProvider: @escaping DefaultHostProvider
    ) {
        self.sessionFactory = sessionFactory
        self.hostResolver = hostResolver
        self.defaultHostProvider = defaultHostProvider
    }

    /// Runs `command` on the resolved host and returns the bounded result
    /// (non-zero exit is a value, not a throw — the agent reads exitCode).
    public func run(
        command: String,
        hostID: UUID?,
        timeout: TimeInterval = 30,
        maxOutputBytes: Int = 64 * 1024,
        cancellation: CancellationToken? = nil
    ) async throws -> SSHExecResult {
        if cancellation?.isCancelled == true { throw SSHExecError.cancelled }

        let resolvedID: UUID
        if let hostID {
            resolvedID = hostID
        } else if let fallback = try await defaultHostProvider() {
            resolvedID = fallback
        } else {
            throw RemotePythonError.noHostConfigured
        }
        guard try await hostResolver(resolvedID) != nil else {
            throw RemotePythonError.hostNotFound(resolvedID)
        }

        let session: any RemotePythonSession
        do {
            session = try await sessionFactory(resolvedID)
        } catch let error as RemotePythonError {
            throw error
        } catch {
            throw RemotePythonError.connectionFailed(
                SecretRedactor.redact(error.localizedDescription)
            )
        }
        return try await session.execute(
            command,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }

    /// Performs read-only, vendor-neutral probes before the model chooses an
    /// execution strategy. Network appliances are probed with `show version`
    /// first so we never assume a POSIX shell merely because SSH connected.
    public func inspectTarget(
        hostID: UUID?,
        cancellation: CancellationToken? = nil
    ) async throws -> RemoteTargetInspection {
        let resolvedID = try await resolveHostID(hostID)
        let session = try await makeSession(hostID: resolvedID)

        let showVersion = try await boundedProbe("show version", session: session, cancellation: cancellation)
        if let appliance = RemoteTargetClassifier.classifyNetworkAppliance(showVersion.combined) {
            return Self.persist(RemoteTargetInspection(
                hostID: resolvedID,
                kind: .networkDevice,
                vendor: appliance.vendor,
                operatingSystem: appliance.operatingSystem,
                containerRuntime: nil,
                confidence: appliance.confidence,
                evidence: showVersion.combined
            ))
        }

        let unix = try await boundedProbe(
            "uname -s 2>/dev/null; uname -m 2>/dev/null; " +
            "(cat /etc/os-release 2>/dev/null || true); " +
            "(command -v docker 2>/dev/null || command -v podman 2>/dev/null || true)",
            session: session,
            cancellation: cancellation
        )
        if let inspection = RemoteTargetClassifier.classifyUnix(
            unix.combined,
            hostID: resolvedID
        ) { return Self.persist(inspection) }

        let windows = try await boundedProbe("cmd /c ver", session: session, cancellation: cancellation)
        if windows.combined.localizedCaseInsensitiveContains("Windows") {
            return Self.persist(RemoteTargetInspection(
                hostID: resolvedID,
                kind: .windows,
                vendor: "Microsoft",
                operatingSystem: windows.combined,
                containerRuntime: nil,
                confidence: 0.94,
                evidence: windows.combined
            ))
        }
        return Self.persist(RemoteTargetInspection(
            hostID: resolvedID,
            kind: .unknown,
            vendor: nil,
            operatingSystem: nil,
            containerRuntime: nil,
            confidence: 0.2,
            evidence: [showVersion.combined, unix.combined, windows.combined]
                .filter { !$0.isEmpty }.joined(separator: "\n---\n")
        ))
    }

    /// Runs a command using the target-aware policy. Linux uses an ephemeral,
    /// non-privileged task container by default. Host execution must be
    /// explicitly selected for host administration. Appliances always receive
    /// their native CLI command verbatim.
    public func runRouted(
        command: String,
        hostID: UUID?,
        mode: RemoteExecutionMode,
        containerNetwork: Bool,
        taskID: UUID,
        networkChangePlan: String?,
        networkRollbackCommand: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken? = nil
    ) async throws -> RoutedSSHResult {
        let inspection = try await inspectTarget(hostID: hostID, cancellation: cancellation)
        let effectiveMode: RemoteExecutionMode
        switch mode {
        case .automatic:
            switch inspection.kind {
            case .linux, .nas, .openWrt:
                guard inspection.containerRuntime != nil else {
                    return RoutedSSHResult(
                        inspection: inspection,
                        mode: .automatic,
                        result: SSHExecResult(
                            stdout: "",
                            stderr: "status=requiresBootstrap reason=no_container_runtime; use ssh.bootstrapExecutionHost or explicitly choose host mode for an authorized host-administration task",
                            exitCode: 78,
                            truncated: false
                        )
                    )
                }
                effectiveMode = .container
            case .networkDevice:
                effectiveMode = .networkDevice
            case .macOS, .windows:
                effectiveMode = .host
            case .unknown:
                return RoutedSSHResult(
                    inspection: inspection,
                    mode: .automatic,
                    result: SSHExecResult(
                        stdout: "",
                        stderr: "status=targetUnclassified; inspect the target and explicitly choose host or networkDevice mode",
                        exitCode: 65,
                        truncated: false
                    )
                )
            }
        default:
            effectiveMode = mode
        }

        if effectiveMode == .networkDevice,
           Self.looksLikeNetworkMutation(command),
           (networkChangePlan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
            networkRollbackCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
            return RoutedSSHResult(
                inspection: inspection,
                mode: effectiveMode,
                result: SSHExecResult(
                    stdout: "",
                    stderr: "status=networkChangePlanRequired; read current configuration, provide a bounded diff and rollback command, then request approval before mutation",
                    exitCode: 77,
                    truncated: false
                )
            )
        }

        if effectiveMode == .networkDevice,
           inspection.kind != .networkDevice,
           inspection.kind != .unknown {
            return RoutedSSHResult(
                inspection: inspection,
                mode: effectiveMode,
                result: SSHExecResult(stdout: "", stderr: "status=modeMismatch target is not classified as a network device", exitCode: 64, truncated: false)
            )
        }
        if effectiveMode == .container {
            guard [.linux, .nas, .openWrt].contains(inspection.kind),
                  let runtime = inspection.containerRuntime else {
                return RoutedSSHResult(
                    inspection: inspection,
                    mode: effectiveMode,
                    result: SSHExecResult(stdout: "", stderr: "status=containerUnavailable", exitCode: 69, truncated: false)
                )
            }
            let wrapped = Self.containerCommand(
                command,
                runtime: runtime,
                networkEnabled: containerNetwork,
                taskID: taskID
            )
            let result = try await run(
                command: wrapped,
                hostID: inspection.hostID,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
                cancellation: cancellation
            )
            return RoutedSSHResult(inspection: inspection, mode: effectiveMode, result: result)
        }
        let result = try await run(
            command: command,
            hostID: inspection.hostID,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
        return RoutedSSHResult(inspection: inspection, mode: effectiveMode, result: result)
    }

    private func resolveHostID(_ requested: UUID?) async throws -> UUID {
        if let requested { return requested }
        if let fallback = try await defaultHostProvider() { return fallback }
        throw RemotePythonError.noHostConfigured
    }

    private func makeSession(hostID: UUID) async throws -> any RemotePythonSession {
        guard try await hostResolver(hostID) != nil else {
            throw RemotePythonError.hostNotFound(hostID)
        }
        do { return try await sessionFactory(hostID) }
        catch let error as RemotePythonError { throw error }
        catch {
            throw RemotePythonError.connectionFailed(SecretRedactor.redact(error.localizedDescription))
        }
    }

    /// Opens the concrete verified SSH session required by tunnel-backed
    /// services. Test doubles intentionally fail this capability instead of
    /// silently falling back to shell transport.
    public func openTunnelSession(hostID: UUID?) async throws -> (UUID, SSHSessionHandle) {
        let resolvedID = try await resolveHostID(hostID)
        let session = try await makeSession(hostID: resolvedID)
        guard let handle = session as? SSHSessionHandle else {
            throw RemotePythonError.connectionFailed("SSH tunnel transport is unavailable")
        }
        return (resolvedID, handle)
    }

    private func boundedProbe(
        _ command: String,
        session: any RemotePythonSession,
        cancellation: CancellationToken?
    ) async throws -> SSHExecResult {
        do {
            return try await session.execute(command, timeout: 12, maxOutputBytes: 16 * 1024, cancellation: cancellation)
        } catch SSHExecError.timedOut {
            return SSHExecResult(stdout: "", stderr: "probe timed out", exitCode: 124, truncated: false)
        }
    }

    private static func containerCommand(
        _ command: String,
        runtime: RemoteContainerRuntime,
        networkEnabled: Bool,
        taskID: UUID
    ) -> String {
        let payload = Data(command.utf8).base64EncodedString()
        let network = networkEnabled ? "bridge" : "none"
        let taskDirectory = "$HOME/.floe/tasks/\(taskID.uuidString)"
        return "mkdir -p \"\(taskDirectory)\" && \(runtime.rawValue) run --rm --pull=never --network \(network) --cpus 1 --memory 512m --pids-limit 128 --security-opt no-new-privileges -v \"\(taskDirectory):/workspace\" -w /workspace ubuntu:24.04 sh -lc \"echo \(payload) | base64 -d | sh\"; _floe_status=$?; printf '\\nfloeTaskDirectory=\(taskDirectory)\\n'; exit $_floe_status"
    }

    private static func looksLikeNetworkMutation(_ command: String) -> Bool {
        let normalized = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let readOnlyPrefixes = ["show ", "display ", "get ", "ping ", "traceroute ", "tracert "]
        if readOnlyPrefixes.contains(where: normalized.hasPrefix) { return false }
        let mutationMarkers = [
            "configure", "conf t", "system-view", "interface ", "vlan ",
            "set ", "delete ", "undo ", "commit", "write memory", "copy run"
        ]
        return mutationMarkers.contains(where: normalized.contains)
    }

    private static func persist(_ inspection: RemoteTargetInspection) -> RemoteTargetInspection {
        if let data = try? JSONEncoder().encode(inspection) {
            UserDefaults.standard.set(data, forKey: "floe.remoteTargetInspection.\(inspection.hostID.uuidString)")
        }
        return inspection
    }
}

public enum RemoteExecutionMode: String, Codable, Sendable, CaseIterable {
    case automatic, container, host, networkDevice
}

public enum RemoteTargetKind: String, Codable, Sendable, CaseIterable {
    case linux, macOS, windows, networkDevice, nas, openWrt, unknown
}

public enum RemoteContainerRuntime: String, Codable, Sendable {
    case docker, podman
}

public struct RemoteTargetInspection: Codable, Sendable, Equatable {
    public var hostID: UUID
    public var kind: RemoteTargetKind
    public var vendor: String?
    public var operatingSystem: String?
    public var containerRuntime: RemoteContainerRuntime?
    public var confidence: Double
    public var evidence: String
}

public struct RoutedSSHResult: Sendable {
    public var inspection: RemoteTargetInspection
    public var mode: RemoteExecutionMode
    public var result: SSHExecResult
}

enum RemoteTargetClassifier {
    struct ApplianceMatch {
        var vendor: String
        var operatingSystem: String
        var confidence: Double
    }

    static func classifyNetworkAppliance(_ evidence: String) -> ApplianceMatch? {
        let lower = evidence.lowercased()
        let signatures: [(String, String, String)] = [
            ("cisco ios", "Cisco", "IOS"), ("cisco nx-os", "Cisco", "NX-OS"),
            ("vrp (r)", "Huawei", "VRP"), ("huawei versatile routing platform", "Huawei", "VRP"),
            ("comware", "H3C", "Comware"), ("junos", "Juniper", "Junos"),
            ("routeros", "MikroTik", "RouterOS"), ("fortios", "Fortinet", "FortiOS"),
            ("pan-os", "Palo Alto Networks", "PAN-OS"), ("arubaos", "Aruba", "ArubaOS")
        ]
        guard let match = signatures.first(where: { lower.contains($0.0) }) else { return nil }
        return ApplianceMatch(vendor: match.1, operatingSystem: match.2, confidence: 0.98)
    }

    static func classifyUnix(_ evidence: String, hostID: UUID) -> RemoteTargetInspection? {
        let lower = evidence.lowercased()
        let kind: RemoteTargetKind
        let vendor: String?
        if lower.contains("darwin") {
            kind = .macOS; vendor = "Apple"
        } else if lower.contains("openwrt") || lower.contains("lede") {
            kind = .openWrt; vendor = "OpenWrt"
        } else if lower.contains("synology") || lower.contains("diskstation") || lower.contains("qnap") {
            kind = .nas; vendor = lower.contains("synology") ? "Synology" : "QNAP"
        } else if lower.contains("linux") || lower.contains("id=") {
            kind = .linux; vendor = nil
        } else { return nil }
        let runtime: RemoteContainerRuntime? = lower.contains("/podman") ? .podman : (lower.contains("/docker") ? .docker : nil)
        return RemoteTargetInspection(
            hostID: hostID,
            kind: kind,
            vendor: vendor,
            operatingSystem: String(evidence.prefix(2048)),
            containerRuntime: runtime,
            confidence: 0.95,
            evidence: String(evidence.prefix(8192))
        )
    }
}

private extension SSHExecResult {
    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
