// FloeExecution — persistent services inside a Linux environment.
//
// `exec.localService` in a Linux environment is one detached process in that
// environment's guest. The host half is this supervisor plus the runner
// frames implemented in LinuxGuestCommandChannel:
//
//   host → \x1eFLOE-SPAWN <token> <payloadBytes> <chunkCount> + CHUNKs + RUN
//          payload = [cwd, logPath, argv...]
//   guest → \x1eFLOE-PID <token> <pid> then \x1eFLOE-END <token> 0
//   host → \x1eFLOE-KILL <token> <pid> / \x1eFLOE-ALIVE <token> <pid>
//   guest → \x1eFLOE-END <token> 0 (alive/killed) or 3 (unknown pid)
//
// stdout and stderr are appended by the guest to a log file inside the
// environment's 9p share, so the host reads live logs from the same file and
// never keeps a console pipe open for a service that outlives a reply. Ports
// are published with the engine's slirp host forwarding
// (`floe_vm_hostfwd_add`), which is why a guest service is reachable on
// 127.0.0.1 exactly like a native one.

import Foundation
import FloeCore
import FloeTools

public enum LinuxGuestLocalServiceRuntime: String, Sendable, Codable, CaseIterable {
    case node
    case python
}

public struct LinuxGuestLocalServiceRequest: Sendable {
    /// Host path of the entry script; must be inside the workspace or the
    /// environment layer (mapped to the guest's 9p mount).
    public var entry: String
    public var runtime: LinuxGuestLocalServiceRuntime
    public var arguments: [String]
    /// Host path of the working directory; nil keeps the guest default
    /// (`/workspace` when the share is mounted).
    public var workingDirectory: String?
    public var port: Int
    /// Host path of the service log; must be inside a shared directory so the
    /// guest writes and the host tail read the same file.
    public var logFile: URL
    public var environment: [String: String]

    public init(
        entry: String,
        runtime: LinuxGuestLocalServiceRuntime,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        port: Int,
        logFile: URL,
        environment: [String: String] = [:]
    ) {
        self.entry = entry
        self.runtime = runtime
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.port = port
        self.logFile = logFile
        self.environment = environment
    }
}

public struct LinuxGuestLocalServiceHandle: Sendable, Equatable {
    public var token: String
    public var environmentID: String
    public var runtime: LinuxGuestLocalServiceRuntime
    public var pid: Int32
    public var port: Int
    public var forward: LinuxGuestServiceForward
    public var logHostPath: String
    public var logGuestPath: String
    public var startedAt: Date

    public init(
        token: String,
        environmentID: String,
        runtime: LinuxGuestLocalServiceRuntime,
        pid: Int32,
        port: Int,
        forward: LinuxGuestServiceForward,
        logHostPath: String,
        logGuestPath: String,
        startedAt: Date
    ) {
        self.token = token
        self.environmentID = environmentID
        self.runtime = runtime
        self.pid = pid
        self.port = port
        self.forward = forward
        self.logHostPath = logHostPath
        self.logGuestPath = logGuestPath
        self.startedAt = startedAt
    }
}

public struct LinuxGuestLocalServiceSnapshot: Sendable, Equatable {
    /// starting | running | stopped | failed | notFound
    public var state: String
    public var pid: Int32?
    public var alive: Bool
    public var stdout: String
    public var stderr: String
    public var truncated: Bool
    public var logBytes: Int64
    public var lastError: String?

    public init(
        state: String,
        pid: Int32? = nil,
        alive: Bool = false,
        stdout: String = "",
        stderr: String = "",
        truncated: Bool = false,
        logBytes: Int64 = 0,
        lastError: String? = nil
    ) {
        self.state = state
        self.pid = pid
        self.alive = alive
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.logBytes = logBytes
        self.lastError = lastError
    }
}

/// The guest-side operations the supervisor needs. The registry implements
/// this; tests can script it.
public protocol LinuxGuestLocalServiceHosting: LinuxCommandRunning {
    func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor?
    func guestSpawn(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        logPath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> Int32
    func guestServiceAlive(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool
    func guestKillService(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool
    func guestEnsureForward(environmentID: String, forward: LinuxGuestServiceForward) async throws
    func guestRemoveForward(environmentID: String, forward: LinuxGuestServiceForward) async
}

/// Consumed by the app's `exec.localService` job runner when the environment
/// is a Linux guest.
public protocol LinuxGuestLocalServiceControlling: Sendable {
    func startLocalService(
        environmentID: String,
        request: LinuxGuestLocalServiceRequest,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLocalServiceHandle
    func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot
    func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async
    /// Stops every service of one environment (environment stop/delete).
    func stopLocalServices(environmentID: String) async
}

public actor LinuxGuestLocalServiceSupervisor: LinuxGuestLocalServiceControlling {
    private let host: any LinuxGuestLocalServiceHosting
    private let limits: LinuxGuestLimits
    private let maxLogTailBytes: Int
    private var active: [String: LinuxGuestLocalServiceHandle] = [:]

    public init(
        host: any LinuxGuestLocalServiceHosting,
        limits: LinuxGuestLimits = .standard,
        maxLogTailBytes: Int = 8_000
    ) {
        self.host = host
        self.limits = limits
        self.maxLogTailBytes = max(1024, maxLogTailBytes)
    }

    public func startLocalService(
        environmentID: String,
        request: LinuxGuestLocalServiceRequest,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLocalServiceHandle {
        guard let descriptor = await host.guestDescriptor(environmentID: environmentID) else {
            throw LinuxGuestError.notOwned(environmentID: environmentID)
        }
        guard await host.supports(environmentID: environmentID) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard (1024...65535).contains(request.port) else {
            throw LinuxGuestError.invalidConfiguration("service port must be 1024..65535")
        }
        let pathMap = LinuxGuestPathMap(shares: descriptor.shares)
        guard let entryGuest = pathMap.guestPath(forHostPath: request.entry) else {
            throw LinuxGuestError.invalidConfiguration("the service entry script must be inside the environment workspace or layer")
        }
        guard let logGuest = pathMap.guestPath(forHostPath: request.logFile.path) else {
            throw LinuxGuestError.invalidConfiguration("the service log must be inside the environment workspace or layer")
        }
        let workingGuest: String?
        if let workingDirectory = request.workingDirectory {
            // A provided working directory must map; silently keeping the
            // guest default would run the service somewhere else than the
            // caller asked for.
            guard let mapped = pathMap.guestPath(forHostPath: workingDirectory) else {
                throw LinuxGuestError.invalidConfiguration("the service working directory must be inside the environment workspace or layer")
            }
            workingGuest = mapped
        } else {
            workingGuest = nil
        }

        var command: [String]
        switch request.runtime {
        case .python:
            let python = try await LinuxGuestPythonProvisioner.shared.ensure(
                environmentID: environmentID,
                runner: host,
                cancellation: cancellation
            )
            command = [python.pythonPath, entryGuest] + request.arguments
        case .node:
            command = ["node", entryGuest] + request.arguments
        }

        var variables = request.environment
        variables["PORT"] = String(request.port)
        variables["FLOE_SERVICE_PORT"] = String(request.port)
        variables["FLOE_ENVIRONMENT_ID"] = environmentID
        variables["PYTHONUNBUFFERED"] = "1"
        if let injected = LinuxGuestEnvironmentEncoding.argv(variables) {
            command = ["env"] + injected + command
        }

        let pid = try await host.guestSpawn(
            environmentID: environmentID,
            argv: command,
            workingDirectory: workingGuest,
            logPath: logGuest,
            timeout: limits.clampedTimeout(nil),
            cancellation: cancellation
        )

        let forward = LinuxGuestServiceForward(
            hostAddress: "127.0.0.1",
            hostPort: UInt16(request.port),
            guestPort: UInt16(request.port)
        )
        do {
            try await host.guestEnsureForward(environmentID: environmentID, forward: forward)
        } catch {
            // A service nobody can reach is a leak: kill it before reporting.
            _ = try? await host.guestKillService(environmentID: environmentID, pid: pid, timeout: 10)
            throw error
        }

        let handle = LinuxGuestLocalServiceHandle(
            token: UUID().uuidString,
            environmentID: environmentID,
            runtime: request.runtime,
            pid: pid,
            port: request.port,
            forward: forward,
            logHostPath: request.logFile.path,
            logGuestPath: logGuest,
            startedAt: Date()
        )
        active[handle.token] = handle
        FloeLogger(category: .tools).info(
            "Linux guest service started environment=\(environmentID) pid=\(pid) port=\(request.port) runtime=\(request.runtime.rawValue)"
        )
        return handle
    }

    public func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot {
        guard active[handle.token] != nil else {
            return LinuxGuestLocalServiceSnapshot(state: "notFound", pid: handle.pid)
        }
        // A stopped guest takes its services with it; report that as stopped
        // instead of an error so the job can finish honestly.
        guard await host.supports(environmentID: handle.environmentID) else {
            active[handle.token] = nil
            let tail = Self.readLogTail(handle.logHostPath, maxBytes: maxLogTailBytes)
            return LinuxGuestLocalServiceSnapshot(
                state: "stopped",
                pid: handle.pid,
                alive: false,
                stdout: tail.text,
                truncated: tail.truncated,
                logBytes: tail.bytes,
                lastError: LinuxGuestError.notRunning(environmentID: handle.environmentID).localizedDescription
            )
        }
        let alive: Bool
        do {
            alive = try await host.guestServiceAlive(environmentID: handle.environmentID, pid: handle.pid, timeout: 10)
        } catch {
            return LinuxGuestLocalServiceSnapshot(
                state: "failed",
                pid: handle.pid,
                alive: false,
                lastError: error.localizedDescription
            )
        }
        let tail = Self.readLogTail(handle.logHostPath, maxBytes: maxLogTailBytes)
        if !alive {
            active[handle.token] = nil
            return LinuxGuestLocalServiceSnapshot(
                state: "stopped",
                pid: handle.pid,
                alive: false,
                stdout: tail.text,
                truncated: tail.truncated,
                logBytes: tail.bytes
            )
        }
        return LinuxGuestLocalServiceSnapshot(
            state: "running",
            pid: handle.pid,
            alive: true,
            stdout: tail.text,
            truncated: tail.truncated,
            logBytes: tail.bytes
        )
    }

    public func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async {
        active[handle.token] = nil
        _ = try? await host.guestKillService(environmentID: handle.environmentID, pid: handle.pid, timeout: 15)
        await host.guestRemoveForward(environmentID: handle.environmentID, forward: handle.forward)
    }

    public func stopLocalServices(environmentID: String) async {
        let owned = active.values.filter { $0.environmentID == environmentID }
        for handle in owned {
            await stopLocalService(handle)
        }
    }

    /// Used on app teardown: every guest is about to be destroyed.
    public func stopAllLocalServices() async {
        let owned = Array(active.values)
        for handle in owned {
            await stopLocalService(handle)
        }
    }

    /// `env KEY=VALUE …` prefix. Keys are validated so a hostile environment
    /// dictionary cannot smuggle argv/console framing.
    static func environmentArgv(_ variables: [String: String]) -> [String]? {
        LinuxGuestEnvironmentEncoding.argv(variables)
    }

    private struct LogTail {
        var text: String
        var bytes: Int64
        var truncated: Bool
    }

    /// Bounded tail read: the host sees the guest's appended log immediately
    /// because both sides use the same 9p file.
    private static func readLogTail(_ path: String, maxBytes: Int) -> LogTail {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return LogTail(text: "", bytes: 0, truncated: false)
        }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        let start = max(0, size - Int64(maxBytes))
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.readToEnd()) ?? Data()
        let redacted = SecretRedactor.redact(String(decoding: data, as: UTF8.self))
        return LogTail(text: redacted, bytes: size, truncated: size > Int64(maxBytes))
    }
}
