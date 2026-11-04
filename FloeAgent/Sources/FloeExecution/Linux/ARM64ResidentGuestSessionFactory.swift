import Foundation
import FloeCore

/// Production session seam: eight independently owned project runners on one
/// physical ARM64 Linux. The existing registry retains command/PTY/job policy.
public final class ARM64ResidentGuestSessionFactory: LinuxGuestSessionCreating, Sendable {
    private let root: URL
    private let resident: ARM64ResidentGuestOwner
    public var usesResidentMachine: Bool { true }
    public var preferredSharedConfiguration: LinuxGuestLifecycleConfig? {
        LinuxGuestLifecycleConfig.load(from: root) ?? .init(vcpus: 2, memoryMB: 512)
    }

    public init(root: URL) {
        self.root = root
        self.resident = ARM64ResidentGuestOwner(root: root)
    }

    public func makeSession(descriptor: LinuxGuestEnvironmentDescriptor,
                            image: LinuxGuestImage, limits: LinuxGuestLimits) throws -> LinuxGuestSessionHandle {
        throw LinuxGuestError.invalidConfiguration("The resident runtime requires its verified image directory")
    }

    public func makeSession(descriptor: LinuxGuestEnvironmentDescriptor, image: LinuxGuestImage,
                            imageDirectory: URL?, limits: LinuxGuestLimits) throws -> LinuxGuestSessionHandle {
        guard let imageDirectory else {
            throw LinuxGuestError.invalidConfiguration("The runtime image is not installed")
        }
        let state = ARM64ResidentProjectLease(environmentID: descriptor.id)
        let owner = resident
        return LinuxGuestSessionHandle(
            transport: state,
            start: { try await owner.open(state, descriptor: descriptor, image: image,
                                          imageDirectory: imageDirectory, limits: limits) },
            stop: { await Task { await owner.close(state) }.value },
            close: { await Task { await owner.close(state) }.value },
            isRunning: { await owner.isRunning(state) },
            addForward: { try await owner.addForward($0, lease: state) },
            removeForward: { try await owner.removeForward($0, lease: state) },
            requiresGuestSyncBeforeStop: true
        )
    }

    public func shutdown() async { await resident.shutdown() }
}

/// A handle never owns the physical machine or a sibling's stream. Closing
/// its byte transport stops delivery; only the supervisor ack releases its
/// actual running identity and share leases.
private final class ARM64ResidentProjectLease: LinuxGuestConsoleTransport, @unchecked Sendable {
    let id = UUID()
    let environmentID: String
    private let lock = NSLock()
    private var transport: ARM64ConsoleTransport?
    init(environmentID: String) { self.environmentID = environmentID }
    func install(_ transport: ARM64ConsoleTransport) { lock.withLock { self.transport = transport } }
    func write(_ bytes: [UInt8]) async throws {
        guard let current = lock.withLock({ transport }) else {
            throw LinuxGuestError.notRunning(environmentID: environmentID)
        }
        try await current.write(bytes)
    }
    func output() async -> AsyncStream<Data> {
        guard let current = lock.withLock({ transport }) else { return AsyncStream { $0.finish() } }
        return await current.output()
    }
    func close() async {
        let current = lock.withLock { transport }
        await current?.close()
    }
}

private actor ARM64ResidentGuestOwner {
    private struct Project {
        let lease: ARM64ResidentProjectLease
        let projectID: LinuxGuestProjectID
        let generation: LinuxGuestProjectGeneration
        let slot: Int
        let hasEnvironment: Bool
        var mayBeRunning: Bool = false
        var forwards = Set<LinuxGuestServiceForward>()
    }
    private let root: URL
    private var machine: ARM64GuestMachine?
    private var supervisor: LinuxGuestProjectSupervisor?
    private var projects: [String: Project] = [:]
    private var imageID: String?
    private var shape: LinuxGuestLifecycleConfig?
    private var cacheRoot: URL?
    private var nextGeneration: UInt64 = 0
    private var capacity = 0
    private var lifecycleLocked = false
    private var lifecycleWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(root: URL) { self.root = root }

    private func acquireLifecycle(cancellable: Bool = true) async throws {
        if cancellable { try Task.checkCancellation() }
        if !lifecycleLocked { lifecycleLocked = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancellable && Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { lifecycleWaiters.append((id, continuation)) }
            }
        } onCancel: {
            if cancellable { Task { await self.cancelWaiter(id) } }
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = lifecycleWaiters.firstIndex(where: { $0.0 == id }) else { return }
        lifecycleWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func releaseLifecycle() {
        if lifecycleWaiters.isEmpty { lifecycleLocked = false }
        else { lifecycleWaiters.removeFirst().1.resume(returning: ()) }
    }

    func open(_ lease: ARM64ResidentProjectLease, descriptor: LinuxGuestEnvironmentDescriptor,
              image: LinuxGuestImage, imageDirectory: URL, limits: LinuxGuestLimits) async throws {
        try await acquireLifecycle()
        defer { releaseLifecycle() }
        try Task.checkCancellation()
        if let existing = projects[descriptor.id] {
            guard existing.lease.id == lease.id, existing.mayBeRunning else {
                throw LinuxGuestError.guestBusy(environmentID: descriptor.id)
            }
            return
        }
        try await ensureMachine(descriptor: descriptor, image: image, directory: imageDirectory, limits: limits)
        guard let machine, let supervisor else { throw ARM64MachineError.notRunning }
        guard let slot = (0..<capacity).first(where: { index in !projects.values.contains { $0.slot == index } }) else {
            throw LinuxGuestError.capacityReached(detail: "All project sessions are in use")
        }
        guard let workspace = descriptor.shares.first(where: { $0.tag == LinuxGuestShare.workspaceTag }) else {
            throw LinuxGuestError.invalidConfiguration("The project folder is unavailable")
        }
        let environment = descriptor.shares.first(where: { $0.tag == LinuxGuestShare.environmentTag })
        let requestedCache = descriptor.shares.first(where: { $0.tag == LinuxGuestShare.cacheTag })?.hostDirectory.standardizedFileURL
        if let cacheRoot, let requestedCache, cacheRoot != requestedCache {
            throw LinuxGuestError.invalidConfiguration("A different shared resource cache is already mounted")
        }
        nextGeneration &+= 1
        let project = Project(lease: lease,
            projectID: try LinuxGuestProjectID("e" + FloeDigest.sha256Hex(Data(descriptor.id.utf8)).prefix(63)),
            generation: try LinuxGuestProjectGeneration(String(nextGeneration)), slot: slot,
            hasEnvironment: environment != nil)
        projects[descriptor.id] = project
        do {
            try await machine.attachShare(slot: UInt32(slot), hostPath: workspace.hostDirectory.path,
                mountTag: "floe-ws-\(slot)", readOnly: false)
            if let environment {
                try await machine.attachShare(slot: UInt32(8 + slot), hostPath: environment.hostDirectory.path,
                    mountTag: "floe-ws-\(8 + slot)", readOnly: false)
            }
            if let requestedCache, cacheRoot == nil {
                try await machine.attachShare(slot: 16, hostPath: requestedCache.path,
                    mountTag: "floe-ws-16", readOnly: true)
                cacheRoot = requestedCache
            }
            let transport = try await machine.renewProjectConsole(channel: ARM64GuestMachine.projectChannel(slot))
            lease.install(transport)
            projects[descriptor.id]?.mayBeRunning = true
            let mount = try LinuxGuestProjectWorkspaceMount(directory: LinuxGuestMountPoint.workspace,
                shareSlot: slot, environmentShare: environment != nil, cacheShare: requestedCache != nil)
            _ = try await supervisor.open(projectID: project.projectID, generation: project.generation,
                baseRootfs: "/mnt/base", workspace: mount)
            try Task.checkCancellation()
        } catch {
            // An interrupted open may already have mounted the project. Keep
            // the reservation until the control owner proves it closed.
            await Task { await self.closeUnlocked(lease) }.value
            throw error
        }
    }

    private func ensureMachine(descriptor: LinuxGuestEnvironmentDescriptor, image: LinuxGuestImage,
                               directory: URL, limits: LinuxGuestLimits) async throws {
        let requested = LinuxGuestLifecycleConfig(vcpus: descriptor.vcpus ?? 2,
            memoryMB: descriptor.ramMB ?? 512)
        if let machine, machine.state == .running {
            guard imageID == image.id, shape == requested else {
                throw LinuxGuestError.invalidConfiguration("Stop active projects before changing the shared runtime")
            }
            return
        }
        guard projects.isEmpty else { throw LinuxGuestError.guestBusy(environmentID: descriptor.id) }
        if let machine {
            guard case .stopped = await machine.stop() else { throw ARM64MachineError.stopTimeout }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Reuse the existing verified, sparse/COW disk preparer. All overlays
        // live on this one private disk, never one physical disk per task.
        let prepared = try LinuxGuestRuntimeImagePreparer().prepare(image: image, imageDirectory: directory,
            environmentID: "resident-arm64", writableDirectory: root)
        func asset(_ role: LinuxGuestImageArtifact.Role, _ path: String?) throws -> ARM64VerifiedBootAsset? {
            guard let path else { return nil }
            guard let declared = image.artifactDigest(role: role) else {
                throw LinuxGuestError.invalidConfiguration("The runtime is missing a boot artifact digest")
            }
            let bytes = try LinuxGuestRuntimeImagePreparer.loadVerifiedArtifact(declared,
                imageDirectory: directory, role: role.rawValue)
            return ARM64VerifiedBootAsset(path: path, sha256: FloeDigest.sha256Hex(bytes))
        }
        guard let firmware = try asset(.bios, prepared.biosPath), let disk = prepared.diskPath else {
            throw LinuxGuestError.invalidConfiguration("The runtime image is incomplete")
        }
        let config = ARM64MachineConfig(firmware: firmware,
            kernel: try asset(.kernel, prepared.kernelPath), initrd: try asset(.initrd, prepared.initrdPath),
            commandLine: prepared.cmdline, privateWritableDiskPath: disk,
            ramMiB: requested.memoryMB ?? 512, possibleVCPUs: requested.vcpus ?? 2,
            virtioConsoles: 9, networkEnabled: true)
        let created = try ARM64GuestMachine(ownership: .init(label: "resident"), config: config)
        machine = created; imageID = image.id; shape = requested
        ResidentMemoryReservations.set(id: "linux-resident-arm64", bytes: Int64(config.ramMiB) * 1_048_576)
        do {
            try created.start()
            let deadline = Date().addingTimeInterval(15)
            while created.state == .starting, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard created.state == .running else {
                if case .failed(let detail) = created.state { throw LinuxGuestError.startFailed(detail) }
                throw ARM64MachineError.notRunning
            }
            let client = LinuxGuestProjectSupervisor(transport: try created.consoleTransport(channel: 1), limits: limits)
            supervisor = client
            // This timeout covers a real cold Linux boot. The first probe is
            // sent once; it is not a timer that kills a long user command.
            let caps = try await client.capabilities(timeout: 180)
            capacity = min(8, caps.maximumProjects)
            guard capacity > 0, caps.baseRootfs == "/mnt/base" else {
                throw LinuxGuestError.invalidConfiguration("The runtime supervisor reported an incompatible layout")
            }
            try requested.save(to: root)
        } catch {
            await supervisor?.close()
            if case .stopped = await created.stop() {
                machine = nil; supervisor = nil; imageID = nil; shape = nil
                ResidentMemoryReservations.set(id: "linux-resident-arm64", bytes: 0)
            }
            throw error
        }
    }

    func isRunning(_ lease: ARM64ResidentProjectLease) -> Bool {
        projects[lease.environmentID]?.lease.id == lease.id
            && projects[lease.environmentID]?.mayBeRunning == true && machine?.state == .running
    }

    func close(_ lease: ARM64ResidentProjectLease) async {
        do { try await acquireLifecycle(cancellable: false) }
        catch { return }
        defer { releaseLifecycle() }
        await closeUnlocked(lease)
    }

    private func closeUnlocked(_ lease: ARM64ResidentProjectLease) async {
        guard let project = projects[lease.environmentID], project.lease.id == lease.id else { return }
        guard let machine, let supervisor else { return }
        do {
            if project.mayBeRunning {
                do { try await supervisor.close(projectID: project.projectID, generation: project.generation) }
                catch LinuxGuestProjectSupervisorError.unknownProject { /* already closed */ }
            }
            // A successful close ack includes the runner/process-tree join.
            // Only then may an attached host root be replaced.
            try await machine.detachShare(slot: UInt32(project.slot), force: true)
            if project.hasEnvironment { try await machine.detachShare(slot: UInt32(8 + project.slot), force: true) }
            for forward in project.forwards {
                try await machine.removeForward(isUDP: forward.isUDP, hostPort: UInt32(forward.hostPort))
            }
            await lease.close()
            projects.removeValue(forKey: lease.environmentID)
            if projects.isEmpty { try await stopPhysicalMachine() }
        } catch {
            FloeLogger(category: .tools).warning("ARM64 project close incomplete; ownership retained")
        }
    }

    func addForward(_ forward: LinuxGuestServiceForward, lease: ARM64ResidentProjectLease) async throws {
        try await acquireLifecycle(); defer { releaseLifecycle() }
        guard isRunning(lease), let machine else { throw ARM64MachineError.notRunning }
        guard forward.hostAddress == "127.0.0.1" || forward.hostAddress == "localhost" else {
            throw LinuxGuestError.serviceForwardingUnavailable("Only local service listeners are supported")
        }
        if projects[lease.environmentID]?.forwards.contains(forward) == true { return }
        try await machine.addForward(.init(isUDP: forward.isUDP, hostPort: UInt32(forward.hostPort), guestPort: UInt32(forward.guestPort)))
        projects[lease.environmentID]?.forwards.insert(forward)
    }

    func removeForward(_ forward: LinuxGuestServiceForward, lease: ARM64ResidentProjectLease) async throws {
        try await acquireLifecycle(cancellable: false); defer { releaseLifecycle() }
        guard projects[lease.environmentID]?.lease.id == lease.id,
              projects[lease.environmentID]?.forwards.contains(forward) == true, let machine else { return }
        try await machine.removeForward(isUDP: forward.isUDP, hostPort: UInt32(forward.hostPort))
        projects[lease.environmentID]?.forwards.remove(forward)
    }

    private func stopPhysicalMachine() async throws {
        guard projects.isEmpty, let machine else { return }
        await supervisor?.close()
        guard case .stopped = await machine.stop() else { throw ARM64MachineError.stopTimeout }
        self.machine = nil; supervisor = nil; imageID = nil; shape = nil; cacheRoot = nil
        capacity = 0
        ResidentMemoryReservations.set(id: "linux-resident-arm64", bytes: 0)
    }

    func shutdown() async {
        do { try await acquireLifecycle(cancellable: false) }
        catch { return }
        defer { releaseLifecycle() }
        for project in Array(projects.values) { await closeUnlocked(project.lease) }
        do { try await stopPhysicalMachine() }
        catch { FloeLogger(category: .tools).warning("ARM64 machine stop incomplete; disk retained") }
    }
}
