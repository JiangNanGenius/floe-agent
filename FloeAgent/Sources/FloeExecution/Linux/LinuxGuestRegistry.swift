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
        if let session = sessions[environmentID] {
            return LinuxGuestStatus(
                environmentID: environmentID,
                running: await session.handle.isRunning(),
                imageID: session.image.id,
                ramMB: limits.clampedRAMMB(session.descriptor.ramMB),
                startedAt: session.startedAt,
                lastError: lastErrors[environmentID]
            )
        }
        return LinuxGuestStatus(
            environmentID: environmentID,
            running: false,
            imageID: descriptor?.imageID,
            ramMB: descriptor?.ramMB,
            lastError: lastErrors[environmentID]
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
        if let failure = image.qualificationFailure() {
            lastErrors[environmentID] = failure
            throw LinuxGuestError.imageNotQualified(environmentID: environmentID, reason: failure)
        }

        let handle = try factory.makeSession(descriptor: descriptor, image: image, limits: limits)
        do {
            try await handle.start()
        } catch {
            lastErrors[environmentID] = error.localizedDescription
            await handle.close()
            throw error
        }

        var session = Session(
            descriptor: descriptor,
            image: image,
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

    public func stopAll() async {
        for id in Array(sessions.keys) {
            await stop(environmentID: id)
        }
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
}

/// The injected `LinuxCommandRunning` implementation: one service per app,
/// one guest per environment, shared by shell, localPython and localService.
public struct TinyEMULinuxCommandService: LinuxCommandRunning, LinuxGuestControlling {
    private let registry: TinyEMULinuxGuestRegistry

    public init(registry: TinyEMULinuxGuestRegistry) {
        self.registry = registry
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
        await registry.stop(environmentID: environmentID)
    }

    public func deleteGuest(environmentID: String) async {
        await registry.stop(environmentID: environmentID)
    }

    public func guestIsRunning(environmentID: String) async -> Bool {
        await registry.status(environmentID: environmentID).running
    }

    public func stopGuests(taskID: String) async {
        await registry.stop(taskID: taskID)
    }

    public func forwardService(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        try await registry.addForward(environmentID: environmentID, forward: forward)
    }

    public func removeServiceForward(environmentID: String, forward: LinuxGuestServiceForward) async {
        await registry.removeForward(environmentID: environmentID, forward: forward)
    }

    public func shutdown() async {
        await registry.stopAll()
    }
}
