// FloeExecution — Linux guest registry and command service.
//
// One registry owns at most one running guest process-wide (the engine links
// a single slirp instance) and exactly one guest per environment, so the
// shell, localPython and localService paths for an environment share the same
// interpreter and the same 9p views. Sessions are keyed by environment id and
// record the task that started them for ownership teardown.

import Foundation
import FloeCore
import FloeTools

/// One guest session's lifecycle closures. The registry only needs these
/// seams, which keeps the TinyEMU C bridge out of the scheduling logic.
public struct LinuxGuestSessionHandle: Sendable {
    public var transport: any LinuxGuestConsoleTransport
    public var start: @Sendable () async throws -> Void
    public var stop: @Sendable () async -> Void
    public var close: @Sendable () async -> Void
    public var isRunning: @Sendable () async -> Bool
    public var addForward: @Sendable (LinuxGuestServiceForward) throws -> Void
    public var removeForward: @Sendable (LinuxGuestServiceForward) throws -> Void

    public init(
        transport: any LinuxGuestConsoleTransport,
        start: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        close: @escaping @Sendable () async -> Void,
        isRunning: @escaping @Sendable () async -> Bool,
        addForward: @escaping @Sendable (LinuxGuestServiceForward) throws -> Void,
        removeForward: @escaping @Sendable (LinuxGuestServiceForward) throws -> Void
    ) {
        self.transport = transport
        self.start = start
        self.stop = stop
        self.close = close
        self.isRunning = isRunning
        self.addForward = addForward
        self.removeForward = removeForward
    }
}

/// Session creation seam: production = TinyEMU, tests = scripted transports.
public protocol LinuxGuestSessionCreating: Sendable {
    func makeSession(
        descriptor: LinuxGuestEnvironmentDescriptor,
        image: LinuxGuestImage,
        limits: LinuxGuestLimits
    ) throws -> LinuxGuestSessionHandle
}

extension TinyEMUGuestSessionFactory: LinuxGuestSessionCreating {}

public actor TinyEMULinuxGuestRegistry {
    private struct Session {
        var descriptor: LinuxGuestEnvironmentDescriptor
        var image: LinuxGuestImage
        var handle: LinuxGuestSessionHandle
        var channel: LinuxGuestCommandChannel
        var startedAt: Date
        var taskID: String?
        var forwards: [LinuxGuestServiceForward]
    }

    private let environments: any LinuxGuestEnvironmentProviding
    private let images: any LinuxGuestImageResolving
    private let limits: LinuxGuestLimits
    private let factory: any LinuxGuestSessionCreating
    private var sessions: [String: Session] = [:]
    private var lastErrors: [String: String] = [:]
    private var terminalSessions: [String: TerminalSession] = [:]

    /// One interactive guest terminal plus its buffered output.
    private struct TerminalSession {
        var environmentID: String
        var handle: LinuxGuestInteractiveSession
    }

    public init(
        environments: any LinuxGuestEnvironmentProviding,
        images: any LinuxGuestImageResolving,
        limits: LinuxGuestLimits = .standard,
        factory: any LinuxGuestSessionCreating = TinyEMUGuestSessionFactory()
    ) {
        self.environments = environments
        self.images = images
        self.limits = limits
        self.factory = factory
    }

    /// True when this service owns the environment as a Linux guest, running
    /// or not. Native environments (and unknown ids) answer false.
    public func owns(environmentID: String) async -> Bool {
        await environments.linuxGuestEnvironment(id: environmentID) != nil
    }

    /// True only when the owned guest is actually running.
    public func supports(environmentID: String) async -> Bool {
        guard await environments.linuxGuestEnvironment(id: environmentID) != nil else {
            await stop(environmentID: environmentID)
            return false
        }
        guard let session = sessions[environmentID] else { return false }
        return await session.handle.isRunning()
    }

    public func status(environmentID: String) async -> LinuxGuestStatus {
        let descriptor = await environments.linuxGuestEnvironment(id: environmentID)
        var imageInstalled: Bool?
        var imageFailure: String?
        var distributable: Bool?
        if let imageID = descriptor?.imageID {
            imageInstalled = await images.linuxGuestImage(id: imageID) != nil
            imageFailure = await images.linuxGuestImageVerificationFailure(id: imageID)
            distributable = LinuxGuestImageDistributionCatalog.entry(id: imageID) != nil
        }
        if let session = sessions[environmentID] {
            return LinuxGuestStatus(
                environmentID: environmentID,
                running: await session.handle.isRunning(),
                imageID: session.image.id,
                ramMB: limits.clampedRAMMB(session.descriptor.ramMB),
                startedAt: session.startedAt,
                lastError: lastErrors[environmentID],
                imageInstalled: imageInstalled,
                imageVerificationFailure: imageFailure,
                imageDistributable: distributable
            )
        }
        return LinuxGuestStatus(
            environmentID: environmentID,
            running: false,
            imageID: descriptor?.imageID,
            ramMB: descriptor?.ramMB,
            lastError: lastErrors[environmentID],
            imageInstalled: imageInstalled,
            imageVerificationFailure: imageFailure,
            imageDistributable: distributable
        )
    }

    /// Starts the environment's guest. Returns false when the environment is
    /// not a Linux guest this service owns.
    @discardableResult
    public func start(environmentID: String, taskID: String?) async throws -> Bool {
        guard let descriptor = await environments.linuxGuestEnvironment(id: environmentID) else {
            return false
        }
        if let existing = sessions[environmentID], await existing.handle.isRunning() {
            return true
        }
        // The engine has one process-wide slirp instance and is not
        // reentrant: only one guest may run at a time on this device.
        for (otherID, session) in sessions where otherID != environmentID {
            if await session.handle.isRunning() {
                throw LinuxGuestError.guestBusy(environmentID: otherID)
            }
        }

        guard let image = await images.linuxGuestImage(id: descriptor.imageID) else {
            let reason = "no guest image manifest for id '\(descriptor.imageID)'"
            lastErrors[environmentID] = reason
            throw LinuxGuestError.imageNotQualified(environmentID: environmentID, reason: reason)
        }
        // Digest verification is the gate that makes a manifest's `qualified`
        // flag meaningful: a hand-written flag with no matching artifact bytes
        // is rejected here, before any VM is created.
        if let failure = await images.linuxGuestImageVerificationFailure(id: descriptor.imageID) {
            lastErrors[environmentID] = failure
            throw LinuxGuestError.imageNotQualified(environmentID: environmentID, reason: failure)
        }
        if let failure = image.qualificationFailure(imageDirectory: images.imageRoot?.appendingPathComponent(descriptor.imageID, isDirectory: true)) {
            lastErrors[environmentID] = failure
            throw LinuxGuestError.imageNotQualified(environmentID: environmentID, reason: failure)
        }

        // The verified manifest is not what the C engine can boot: its paths
        // are relative to the image directory (the app has no usable cwd) and
        // its disk is the shared, immutable base. Resolve bios/kernel/initrd
        // to absolute files inside the verified directory and prepare (or
        // reuse) this environment's own writable disk copy. A resolver
        // without an image root is the in-memory test seam and cannot verify
        // digests; the app never assembles one.
        let runtimeImage: LinuxGuestImage
        if let imageRoot = images.imageRoot {
            do {
                runtimeImage = try LinuxGuestRuntimeImagePreparer().prepare(
                    image: image,
                    imageDirectory: imageRoot.appendingPathComponent(descriptor.imageID, isDirectory: true),
                    environmentID: environmentID,
                    writableDirectory: descriptor.writableDirectory
                )
            } catch {
                lastErrors[environmentID] = error.localizedDescription
                throw error
            }
        } else {
            runtimeImage = image
        }

        let handle = try factory.makeSession(descriptor: descriptor, image: runtimeImage, limits: limits)
        do {
            try await handle.start()
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            await handle.close()
            throw error
        }

        var session = Session(
            descriptor: descriptor,
            image: runtimeImage,
            handle: handle,
            channel: LinuxGuestCommandChannel(transport: handle.transport, limits: limits),
            startedAt: Date(),
            taskID: taskID,
            forwards: []
        )
        do {
            // Requested forwards are part of the start contract: if the
            // engine cannot honor them, the caller must hear it now.
            guard descriptor.serviceForwards.count <= limits.maxServiceForwards else {
                throw LinuxGuestError.invalidConfiguration(
                    "at most \(limits.maxServiceForwards) host forwards are supported per guest"
                )
            }
            for forward in descriptor.serviceForwards {
                try handle.addForward(forward)
                session.forwards.append(forward)
            }
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            await handle.close()
            throw error
        }
        sessions[environmentID] = session
        lastErrors[environmentID] = nil
        FloeLogger(category: .tools).info(
            "Linux guest started environment=\(environmentID) image=\(image.id) ramMB=\(limits.clampedRAMMB(descriptor.ramMB))"
        )
        return true
    }

    public func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        do {
            return try await session.channel.run(
                argv: argv,
                workingDirectory: workingDirectory,
                standardInput: standardInput,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
                cancellation: cancellation
            )
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            if await session.channel.isPoisoned {
                // The guest may still be executing an interrupted command;
                // its state is unknown, so the session is torn down rather
                // than reused for the next caller.
                await stop(environmentID: environmentID)
            }
            throw error
        }
    }

    public func stop(environmentID: String) async {
        for (sessionID, terminal) in terminalSessions where terminal.environmentID == environmentID {
            terminalSessions.removeValue(forKey: sessionID)
            await terminal.handle.close()
        }
        guard let session = sessions.removeValue(forKey: environmentID) else { return }
        await session.channel.close()
        await session.handle.close()
        FloeLogger(category: .tools).info("Linux guest stopped environment=\(environmentID)")
    }

    /// Stops guests started by this task id (task ownership teardown).
    public func stop(taskID: String) async {
        let owned = sessions.filter { $0.value.taskID == taskID }.map(\.key)
        for id in owned {
            await stop(environmentID: id)
        }
    }

    /// Environment ids whose guest was started by this task.
    public func environments(taskID: String) async -> [String] {
        sessions.filter { $0.value.taskID == taskID }.map(\.key)
    }

    public func stopAll() async {
        for id in Array(sessions.keys) {
            await stop(environmentID: id)
        }
    }

    // MARK: interactive sessions

    public func openSession(
        environmentID: String,
        sessionID: String,
        argv: [String],
        workingDirectory: String?,
        columns: Int,
        rows: Int
    ) async throws {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard terminalSessions[sessionID] == nil else {
            throw LinuxGuestError.invalidConfiguration("session \(sessionID) already exists")
        }
        let handle = try await session.channel.openSession(
            sessionID: sessionID,
            argv: argv,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
        terminalSessions[sessionID] = TerminalSession(environmentID: environmentID, handle: handle)
    }

    /// Reads buffered terminal output. Returns nil when the session is
    /// unknown; the tuple's info carries aliveness/exit state.
    public func readSession(
        sessionID: String,
        maxBytes: Int,
        waitMs: Int
    ) async -> (output: Data, info: LinuxGuestSessionInfo)? {
        guard let terminal = terminalSessions[sessionID] else { return nil }
        var collected = Data()
        let deadline = Date().addingTimeInterval(Double(max(0, waitMs)) / 1000)
        var sawData = false
        while collected.count < maxBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 || !sawData else { break }
            let wait = sawData ? min(20, max(0, Int(remaining * 1000))) : max(0, Int(remaining * 1000))
            guard let chunk = await terminal.handle.nextOutput(timeoutMs: wait) else {
                if await terminal.handle.isFinished { break }
                if sawData { break }
                break
            }
            sawData = true
            collected.append(chunk)
        }
        let info = LinuxGuestSessionInfo(
            sessionID: sessionID,
            alive: await !terminal.handle.isFinished,
            exitCode: await terminal.handle.terminalExitCode
        )
        if await terminal.handle.isFinished {
            terminalSessions[sessionID] = nil
        }
        return (collected, info)
    }

    public func writeSession(sessionID: String, text: String) async throws {
        guard let terminal = terminalSessions[sessionID] else {
            throw LinuxGuestError.notRunning(environmentID: "session \(sessionID)")
        }
        try await terminal.handle.write(text)
    }

    public func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {
        guard let terminal = terminalSessions[sessionID] else { return }
        await terminal.handle.signal(signal)
    }

    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        guard let terminal = terminalSessions[sessionID] else { return }
        await terminal.handle.signal(.window, rows: rows, columns: columns)
    }

    public func closeSession(sessionID: String) async {
        guard let terminal = terminalSessions.removeValue(forKey: sessionID) else { return }
        await terminal.handle.close()
    }

    public func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? {
        guard let terminal = terminalSessions[sessionID] else { return nil }
        return LinuxGuestSessionInfo(
            sessionID: sessionID,
            alive: await !terminal.handle.isFinished,
            exitCode: await terminal.handle.terminalExitCode
        )
    }

    public func addForward(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        guard var session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        guard session.forwards.count < limits.maxServiceForwards else {
            throw LinuxGuestError.invalidConfiguration(
                "at most \(limits.maxServiceForwards) host forwards are supported per guest"
            )
        }
        try session.handle.addForward(forward)
        session.forwards.append(forward)
        sessions[environmentID] = session
    }

    public func removeForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        guard var session = sessions[environmentID] else { return }
        try? session.handle.removeForward(forward)
        session.forwards.removeAll { $0 == forward }
        sessions[environmentID] = session
    }

    // MARK: background services (exec.localService)

    /// Guest-side operations for the local-service supervisor. These keep the
    /// same single-session rule as commands and sessions: a SPAWN/KILL/ALIVE
    /// exchange owns the console only while it is in flight.
    public func guestDescriptor(environmentID: String) async -> LinuxGuestEnvironmentDescriptor? {
        await environments.linuxGuestEnvironment(id: environmentID)
    }

    /// Host↔guest path mapping for this environment's 9p shares.
    public func linuxGuestPathMap(environmentID: String) async -> LinuxGuestPathMap? {
        guard let descriptor = await environments.linuxGuestEnvironment(id: environmentID) else { return nil }
        return LinuxGuestPathMap(shares: descriptor.shares)
    }

    public func guestSpawn(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        logPath: String,
        timeout: TimeInterval,
        cancellation: CancellationToken?
    ) async throws -> Int32 {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        do {
            return try await session.channel.spawnService(
                argv: argv,
                workingDirectory: workingDirectory,
                logPath: logPath,
                timeout: timeout,
                cancellation: cancellation
            )
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            if await session.channel.isPoisoned {
                await stop(environmentID: environmentID)
            }
            throw error
        }
    }

    public func guestServiceAlive(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        return try await session.channel.serviceAlive(pid: pid, timeout: timeout)
    }

    public func guestKillService(environmentID: String, pid: Int32, timeout: TimeInterval) async throws -> Bool {
        guard let session = sessions[environmentID], await session.handle.isRunning() else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        return try await session.channel.killService(pid: pid, timeout: timeout)
    }

    public func guestEnsureForward(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        try await addForward(environmentID: environmentID, forward: forward)
    }

    public func guestRemoveForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        await removeForward(environmentID: environmentID, forward: forward)
    }
}

extension TinyEMULinuxGuestRegistry: LinuxGuestLocalServiceHosting {}

extension TinyEMULinuxCommandService: LinuxGuestPathMapping {
    public func linuxGuestPathMap(environmentID: String) async -> LinuxGuestPathMap? {
        await registry.linuxGuestPathMap(environmentID: environmentID)
    }
}

/// The injected `LinuxCommandRunning` implementation: one service per app,
/// one guest per environment, shared by shell, localPython and localService.
public struct TinyEMULinuxCommandService: LinuxCommandRunning, LinuxGuestControlling, LinuxGuestLocalServiceControlling {
    private let registry: TinyEMULinuxGuestRegistry
    private let localServices: LinuxGuestLocalServiceSupervisor

    public init(registry: TinyEMULinuxGuestRegistry, limits: LinuxGuestLimits = .standard) {
        self.registry = registry
        self.localServices = LinuxGuestLocalServiceSupervisor(host: registry, limits: limits)
    }

    // MARK: LinuxCommandRunning

    public func supports(environmentID: String) async -> Bool {
        await registry.supports(environmentID: environmentID)
    }

    public func ownsLinuxEnvironment(environmentID: String) async -> Bool {
        await registry.owns(environmentID: environmentID)
    }

    public func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        try await registry.run(
            environmentID: environmentID,
            argv: argv,
            workingDirectory: workingDirectory,
            standardInput: standardInput,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )
    }

    // MARK: LinuxGuestControlling

    public func startGuest(environmentID: String, taskID: String?) async throws -> Bool {
        try await registry.start(environmentID: environmentID, taskID: taskID)
    }

    public func stopGuest(environmentID: String) async {
        // Services die with their guest: kill them explicitly first so the
        // host forwarding table and the job log are closed out, not just
        // discarded with the VM. The shared interpreter caches are dropped as
        // well; a restart re-probes the (persistent) venv/Node environment
        // instead of trusting paths resolved before the layer was remounted.
        await localServices.stopLocalServices(environmentID: environmentID)
        await registry.stop(environmentID: environmentID)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)
        await LinuxGuestNodeProvisioner.shared.forget(environmentID: environmentID)
    }

    public func deleteGuest(environmentID: String) async {
        await localServices.stopLocalServices(environmentID: environmentID)
        await registry.stop(environmentID: environmentID)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)
        await LinuxGuestNodeProvisioner.shared.forget(environmentID: environmentID)
    }

    public func guestIsRunning(environmentID: String) async -> Bool {
        await registry.status(environmentID: environmentID).running
    }

    public func guestStatus(environmentID: String) async -> LinuxGuestStatus {
        await registry.status(environmentID: environmentID)
    }

    public func stopGuests(taskID: String) async {
        for environmentID in await registry.environments(taskID: taskID) {
            await localServices.stopLocalServices(environmentID: environmentID)
        }
        await registry.stop(taskID: taskID)
    }

    public func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        try await registry.addForward(environmentID: environmentID, forward: forward)
    }

    public func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        await registry.removeForward(environmentID: environmentID, forward: forward)
    }

    // MARK: interactive sessions

    public func openSession(
        environmentID: String,
        sessionID: String,
        argv: [String],
        workingDirectory: String?,
        columns: Int,
        rows: Int
    ) async throws {
        try await registry.openSession(
            environmentID: environmentID,
            sessionID: sessionID,
            argv: argv,
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        )
    }

    public func readSession(
        sessionID: String,
        maxBytes: Int,
        waitMs: Int
    ) async -> (output: Data, info: LinuxGuestSessionInfo)? {
        await registry.readSession(sessionID: sessionID, maxBytes: maxBytes, waitMs: waitMs)
    }

    public func writeSession(sessionID: String, text: String) async throws {
        try await registry.writeSession(sessionID: sessionID, text: text)
    }

    public func signalSession(sessionID: String, signal: LinuxGuestSessionSignal) async {
        await registry.signalSession(sessionID: sessionID, signal: signal)
    }

    public func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        await registry.resizeSession(sessionID: sessionID, columns: columns, rows: rows)
    }

    public func closeSession(sessionID: String) async {
        await registry.closeSession(sessionID: sessionID)
    }

    public func sessionInfo(sessionID: String) async -> LinuxGuestSessionInfo? {
        await registry.sessionInfo(sessionID: sessionID)
    }

    public func shutdown() async {
        await localServices.stopAllLocalServices()
        await registry.stopAll()
    }

    // MARK: LinuxGuestLocalServiceControlling

    public func startLocalService(
        environmentID: String,
        request: LinuxGuestLocalServiceRequest,
        cancellation: CancellationToken?
    ) async throws -> LinuxGuestLocalServiceHandle {
        try await localServices.startLocalService(
            environmentID: environmentID,
            request: request,
            cancellation: cancellation
        )
    }

    public func localServiceSnapshot(_ handle: LinuxGuestLocalServiceHandle) async -> LinuxGuestLocalServiceSnapshot {
        await localServices.localServiceSnapshot(handle)
    }

    public func stopLocalService(_ handle: LinuxGuestLocalServiceHandle) async {
        await localServices.stopLocalService(handle)
    }

    public func stopLocalServices(environmentID: String) async {
        await localServices.stopLocalServices(environmentID: environmentID)
    }
}
