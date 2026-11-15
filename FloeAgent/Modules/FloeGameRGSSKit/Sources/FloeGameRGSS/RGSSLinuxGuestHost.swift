// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Private host binding for the separately built Tapir Linux engine.
///
/// This file defines the concrete seam between the existing typed
/// `RGSSGuestRuntimePort` contract and the App's already-resolved Linux
/// environment/jobs/display services. It never starts a VM, resolves an
/// environment, chooses a project, or executes Ruby on the host.
public enum RGSSGuestHostError: Error, Equatable, Sendable {
    case invalidTarget(String)
    case targetEnvironmentMismatch
    case targetEngineMismatch
    case jobIdentityMismatch
    case jobOwnerMismatch
    case jobNotOwned
    case sessionNotActive
    case staleSession
    case inputUnavailable
    case sourceLayerViolation(String)
}

/// The exact engine artifact identity. The binary is distributed separately
/// from the MPL-2.0 App/SDK; see LICENSE-ROUTE.md.
public enum RGSSGuestEnginePins {
    /// Same pin as `RGSSLinuxRuntimePins.tapir`; kept here for host-binding
    /// callers that do not import the runtime matrix.
    public static let tapir = RGSSLinuxRuntimePins.tapir
}

/// Host-resolved paths and ownership for one run. These are supplied by the
/// host's existing environment resolver; this package never guesses them.
public struct RGSSGuestExecutionTarget: Equatable, Sendable {
    public let environmentID: String
    public let ownerToken: UUID
    public let guestProjectDirectory: String
    public let guestRunDirectory: String
    public let guestHomeDirectory: String
    public let guestEngineBinary: String
    public let guestLibraryPath: String?
    public let guestDisplay: String
    public let hostLogFile: URL
    public let environment: [String: String]

    public init(
        environmentID: String,
        ownerToken: UUID,
        guestProjectDirectory: String,
        guestRunDirectory: String,
        guestHomeDirectory: String,
        guestEngineBinary: String,
        guestLibraryPath: String? = nil,
        guestDisplay: String,
        hostLogFile: URL,
        environment: [String: String] = [:]
    ) throws {
        guard !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isAbsoluteGuestPath(guestProjectDirectory),
              Self.isAbsoluteGuestPath(guestRunDirectory),
              Self.isAbsoluteGuestPath(guestHomeDirectory),
              Self.isAbsoluteGuestPath(guestEngineBinary),
              Self.isValidDisplay(guestDisplay),
              hostLogFile.isFileURL,
              !hostLogFile.path.isEmpty else {
            throw RGSSGuestHostError.invalidTarget("absolute guest paths, a guest DISPLAY and a file log URL are required")
        }
        if let guestLibraryPath {
            guard !guestLibraryPath.isEmpty,
                  guestLibraryPath.split(separator: ":", omittingEmptySubsequences: false)
                    .allSatisfy({ Self.isAbsoluteGuestPath(String($0)) }) else {
                throw RGSSGuestHostError.invalidTarget("LD_LIBRARY_PATH must contain absolute paths")
            }
        }
        let allowed = Set(["DISPLAY", "HOME", "LANG", "LC_ALL", "SDL_AUDIODRIVER", "SDL_VIDEODRIVER", "LIBGL_ALWAYS_SOFTWARE"])
        guard environment.keys.allSatisfy({ allowed.contains($0) }) else {
            throw RGSSGuestHostError.invalidTarget("only fixed non-secret run environment keys are accepted")
        }
        self.environmentID = environmentID
        self.ownerToken = ownerToken
        self.guestProjectDirectory = guestProjectDirectory
        self.guestRunDirectory = guestRunDirectory
        self.guestHomeDirectory = guestHomeDirectory
        self.guestEngineBinary = guestEngineBinary
        self.guestLibraryPath = guestLibraryPath
        self.guestDisplay = guestDisplay
        self.hostLogFile = hostLogFile
        self.environment = environment
    }

    static func isValidDisplay(_ value: String) -> Bool {
        value.range(of: #"^:[0-9]{1,2}(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func isAbsoluteGuestPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096,
              !path.contains("\0"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { $0 != "." && $0 != ".." }
    }
}

/// One host-owned process request. `argv` is an array; it is never joined into
/// a shell command. The host's existing job/display service owns the process
/// group and must stop only this job on cancel/close/environment teardown.
public struct RGSSGuestJobLaunch: Equatable, Sendable {
    public let environmentID: String
    public let ownerToken: UUID
    public let jobID: UUID
    public let argv: [String]
    public let workingDirectory: String
    public let logFile: URL
    public let environment: [String: String]

    public init(environmentID: String, ownerToken: UUID, jobID: UUID, argv: [String],
                workingDirectory: String, logFile: URL, environment: [String: String]) {
        self.environmentID = environmentID
        self.ownerToken = ownerToken
        self.jobID = jobID
        self.argv = argv
        self.workingDirectory = workingDirectory
        self.logFile = logFile
        self.environment = environment
    }
}

/// Implemented by the host over the existing jobs/guest-service lifecycle.
/// The implementation must keep explicit environmentID and owner identity.
public protocol RGSSGuestJobService: Sendable {
    func startOwnedJob(_ launch: RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle
    func jobStatus(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus
    func stopOwnedJob(_ handle: RGSSGuestJobHandle) async throws
}

/// Implemented by the host's existing environment/project resolver. It must
/// re-resolve the same environment/root/owner that the typed context carries.
public protocol RGSSGuestTargetResolver: Sendable {
    func resolve(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget
}

public enum RGSSGuestLaunchPlanner {
    public static func plan(
        request: RGSSGuestLaunchRequest,
        target: RGSSGuestExecutionTarget
    ) throws -> RGSSGuestJobLaunch {
        guard target.environmentID == request.environmentID else {
            throw RGSSGuestHostError.targetEnvironmentMismatch
        }
        let expectedBinary: String
        switch request.engine {
        case .rpgMakerXP: expectedBinary = "tapir-x"
        case .rpgMakerVX: expectedBinary = "tapir-v"
        case .rpgMakerVXAce: expectedBinary = "tapir-a"
        default: throw RGSSGuestHostError.targetEngineMismatch
        }
        guard URL(fileURLWithPath: target.guestEngineBinary).lastPathComponent == expectedBinary else {
            throw RGSSGuestHostError.targetEngineMismatch
        }
        guard target.guestRunDirectory != request.projectRoot.path else {
            throw RGSSGuestHostError.sourceLayerViolation("run directory must not be the immutable source root")
        }
        var environment = target.environment
        environment["HOME"] = target.guestHomeDirectory
        environment["PWD"] = target.guestRunDirectory
        environment["DISPLAY"] = target.guestDisplay
        if let guestLibraryPath = target.guestLibraryPath {
            environment["LD_LIBRARY_PATH"] = guestLibraryPath
        }
        return RGSSGuestJobLaunch(
            environmentID: request.environmentID,
            ownerToken: target.ownerToken,
            jobID: request.jobID,
            argv: [target.guestEngineBinary, "-d", target.guestRunDirectory],
            workingDirectory: target.guestRunDirectory,
            logFile: target.hostLogFile,
            environment: environment)
    }
}

/// Concrete `RGSSGuestRuntimePort` over an injected jobs service. It records
/// the expected environment per job and refuses to status/stop an unowned job.
public actor RGSSLinuxGuestRuntimePort: RGSSGuestRuntimePort {
    private let targets: any RGSSGuestTargetResolver
    private let jobs: any RGSSGuestJobService
    private struct OwnedJob {
        let generation: UUID
        let handle: RGSSGuestJobHandle
        let environmentID: String
    }
    private struct PendingStop {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var owned: [UUID: OwnedJob] = [:]
    private var launching: Set<UUID> = []
    private var stops: [UUID: PendingStop] = [:]

    public init(targets: any RGSSGuestTargetResolver, jobs: any RGSSGuestJobService) {
        self.targets = targets
        self.jobs = jobs
    }

    public func launch(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestJobHandle {
        guard owned[request.jobID] == nil, launching.insert(request.jobID).inserted else {
            throw RGSSGuestHostError.jobIdentityMismatch
        }
        defer { launching.remove(request.jobID) }
        let target = try await targets.resolve(request)
        let plan = try RGSSGuestLaunchPlanner.plan(request: request, target: target)
        let handle = try await jobs.startOwnedJob(plan)
        guard handle.jobID == request.jobID else {
            try? await jobs.stopOwnedJob(handle)
            throw RGSSGuestHostError.jobIdentityMismatch
        }
        guard handle.ownerToken == target.ownerToken else {
            try? await jobs.stopOwnedJob(handle)
            throw RGSSGuestHostError.jobOwnerMismatch
        }
        owned[handle.jobID] = OwnedJob(generation: UUID(), handle: handle,
                                     environmentID: request.environmentID)
        return handle
    }

    public func status(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        guard let record = owned[handle.jobID], record.handle == handle else {
            throw RGSSGuestHostError.jobNotOwned
        }
        let result = try await jobs.jobStatus(handle)
        guard owned[handle.jobID]?.generation == record.generation else {
            throw RGSSGuestHostError.jobNotOwned
        }
        guard result.handle == handle else { throw RGSSGuestHostError.jobIdentityMismatch }
        return result
    }

    public func stop(_ handle: RGSSGuestJobHandle) async throws {
        guard let record = owned[handle.jobID], record.handle == handle else {
            throw RGSSGuestHostError.jobNotOwned
        }
        let operation: PendingStop
        if let pending = stops[handle.jobID] {
            operation = pending
        } else {
            let jobs = self.jobs
            operation = PendingStop(id: UUID(), task: Task {
                try await jobs.stopOwnedJob(handle)
            })
            stops[handle.jobID] = operation
        }
        do {
            try await operation.task.value
            if owned[handle.jobID]?.generation == record.generation {
                owned.removeValue(forKey: handle.jobID)
            }
        } catch {
            // A failed or cancelled transport does not prove process exit.
            // Keep the exact owner so status and a fresh stop can be retried.
            if stops[handle.jobID]?.id == operation.id {
                stops.removeValue(forKey: handle.jobID)
            }
            throw error
        }
        if stops[handle.jobID]?.id == operation.id {
            stops.removeValue(forKey: handle.jobID)
        }
    }
}

// MARK: - Input

public enum RGSSGuestInputKey: String, CaseIterable, Codable, Hashable, Sendable {
    case left, right, up, down
    case enter, escape, space, tab, backspace
    case a, b, c, d, q, s, w, x, y, z
    case shift, rightShift, control, alt

    public var isModifier: Bool {
        switch self {
        case .shift, .rightShift, .control, .alt: true
        default: false
        }
    }

    /// Reverse lookup for the host's existing `GameKeyboardKey`/X11 keysym
    /// declarations. Ambiguous keysyms are not accepted.
    public init?(x11KeySym: UInt32) {
        let matches = Self.allCases.filter { $0.x11KeySym == x11KeySym }
        guard matches.count == 1, let key = matches.first else { return nil }
        self = key
    }

    /// X11 keysym for the existing Linux display/keyboard route. The mapping
    /// matches FloeGameWebKit.GameKeyboardKey for the same physical keys.
    public var x11KeySym: UInt32 {
        switch self {
        case .left: 0xFF51
        case .up: 0xFF52
        case .right: 0xFF53
        case .down: 0xFF54
        case .enter: 0xFF0D
        case .escape: 0xFF1B
        case .space: 0x20
        case .tab: 0xFF09
        case .backspace: 0xFF08
        case .shift: 0xFFE1
        case .rightShift: 0xFFE2
        case .control: 0xFFE3
        case .alt: 0xFFE9
        default:
            rawValue.unicodeScalars.first?.value ?? 0
        }
    }
}

public enum RGSSGuestInputAction: String, Codable, Hashable, Sendable {
    case down, left, right, up
    case a, b, c, x, y, z, l, r
    case shift, control, alt
}

/// Physical-key to RGSS-action mapping verified against Tapir's built-in key
/// configuration. The profile is a simultaneous set of physical keys; it is
/// never an "alternate key list".
public struct RGSSGuestInputProfile: Equatable, Sendable {
    public let version: RGSSVersion
    public let bindings: [RGSSGuestInputKey: RGSSGuestInputAction]
    public let label: String

    public init(version: RGSSVersion, bindings: [RGSSGuestInputKey: RGSSGuestInputAction], label: String) {
        self.version = version
        self.bindings = bindings
        self.label = label
    }

    public static func standard(for version: RGSSVersion) -> RGSSGuestInputProfile {
        var bindings: [RGSSGuestInputKey: RGSSGuestInputAction] = [
            .left: .left, .right: .right, .up: .up, .down: .down,
            .enter: .c, .space: .c, .escape: .b,
            .a: .x, .s: .y, .d: .z, .q: .l, .w: .r,
            .shift: .a, .rightShift: .a, .control: .control, .alt: .alt
        ]
        switch version {
        case .rgss1:
            bindings[.z] = .a
            bindings[.x] = .b
            bindings[.c] = .c
            return .init(version: version, bindings: bindings,
                         label: "XP: C/Enter/Space=confirm; Z/Shift=action; X/Esc=cancel")
        case .rgss2, .rgss3:
            bindings[.z] = .c
            bindings[.x] = .b
            bindings[.c] = nil
            return .init(version: version, bindings: bindings,
                         label: "VX/Ace: Z/Enter/Space=confirm; Shift=action; X/Esc=cancel")
        }
    }

    public func action(for key: RGSSGuestInputKey) -> RGSSGuestInputAction? {
        bindings[key]
    }

    /// Physical alternatives for the confirm action. They are separate
    /// selectable keys for UI labels, never a chord to send together.
    public var confirmKeys: [RGSSGuestInputKey] {
        bindings.filter { $0.value == .c }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    /// Physical alternatives for cancel; not a chord.
    public var cancelKeys: [RGSSGuestInputKey] {
        bindings.filter { $0.value == .b }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    /// One physical chord. Modifiers are pressed first and released last.
    public func orderedChord(_ keys: [RGSSGuestInputKey]) -> [RGSSGuestInputKey] {
        var seen = Set<RGSSGuestInputKey>()
        let unique = keys.filter { seen.insert($0).inserted }
        return unique.enumerated().sorted { lhs, rhs in
            if lhs.element.isModifier != rhs.element.isModifier { return lhs.element.isModifier }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

public protocol RGSSGuestInputSession: Sendable {
    func sendChord(_ keys: [RGSSGuestInputKey]) async throws
    func releaseAll() async
    func invalidate() async
}

public protocol RGSSGuestInputPort: Sendable {
    func keyDown(_ key: RGSSGuestInputKey) async throws
    func keyUp(_ key: RGSSGuestInputKey) async throws
    func releaseAll() async
}

/// Per-session input state. It never sends a key after invalidation and it
/// never releases a different session's keys.
public actor RGSSGuestInputController: RGSSGuestInputSession {
    private let port: any RGSSGuestInputPort
    private let profile: RGSSGuestInputProfile
    private var pressed: [RGSSGuestInputKey] = []
    private(set) var invalidated = false
    private(set) var generation: UInt64 = 0
    private var tail: Task<Void, Never>?

    public init(port: any RGSSGuestInputPort, profile: RGSSGuestInputProfile) {
        self.port = port
        self.profile = profile
    }

    public func sendChord(_ keys: [RGSSGuestInputKey]) async throws {
        guard !invalidated else { throw RGSSGuestHostError.sessionNotActive }
        try Task.checkCancellation()
        let previous = tail
        let captured = generation
        let operation = Task { [self] in
            await previous?.value
            try await performChord(keys, generation: captured)
        }
        tail = Task { _ = try? await operation.value }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func performChord(_ keys: [RGSSGuestInputKey], generation captured: UInt64) async throws {
        guard !invalidated, generation == captured else { throw RGSSGuestHostError.sessionNotActive }
        for key in profile.orderedChord(keys) where !pressed.contains(key) {
            try Task.checkCancellation()
            // A transport may deliver a key and then throw. Track the attempted
            // down before awaiting so every failure can compensate it.
            pressed.append(key)
            do {
                try await port.keyDown(key)
                try Task.checkCancellation()
                guard !invalidated, generation == captured else {
                    throw RGSSGuestHostError.sessionNotActive
                }
            } catch {
                await performRelease()
                throw error
            }
        }
    }

    public func releaseAll() async {
        generation &+= 1
        let previous = tail
        let operation = Task { [self] in
            await previous?.value
            await performRelease()
        }
        tail = operation
        await operation.value
    }

    private func performRelease() async {
        let release = pressed.reversed()
        pressed.removeAll()
        for key in release { try? await port.keyUp(key) }
    }

    public func invalidate() async {
        invalidated = true
        await releaseAll()
    }

    public func currentPressedKeys() -> [RGSSGuestInputKey] { pressed }
}

public protocol RGSSGuestInputPortProviding: Sendable {
    func makeInputSession(for session: RGSSGuestSession) async throws -> any RGSSGuestInputSession
}

/// Closure form of the host seam. Root can wire the existing environment,
/// jobs and display services without adding a parallel service type.
public struct RGSSGuestHostBindings: Sendable {
    public var resolveTarget: @Sendable (RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget
    public var startJob: @Sendable (RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle
    public var jobStatus: @Sendable (RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus
    public var stopJob: @Sendable (RGSSGuestJobHandle) async throws -> Void
    public var makeInput: @Sendable (RGSSGuestSession) async throws -> any RGSSGuestInputSession

    public init(
        resolveTarget: @escaping @Sendable (RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget,
        startJob: @escaping @Sendable (RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle,
        jobStatus: @escaping @Sendable (RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus,
        stopJob: @escaping @Sendable (RGSSGuestJobHandle) async throws -> Void,
        makeInput: @escaping @Sendable (RGSSGuestSession) async throws -> any RGSSGuestInputSession
    ) {
        self.resolveTarget = resolveTarget
        self.startJob = startJob
        self.jobStatus = jobStatus
        self.stopJob = stopJob
        self.makeInput = makeInput
    }
}

private struct RGSSGuestClosureTargets: RGSSGuestTargetResolver {
    let resolveTarget: @Sendable (RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget
    func resolve(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget {
        try await resolveTarget(request)
    }
}

private struct RGSSGuestClosureJobs: RGSSGuestJobService {
    let start: @Sendable (RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle
    let status: @Sendable (RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus
    let stop: @Sendable (RGSSGuestJobHandle) async throws -> Void
    func startOwnedJob(_ launch: RGSSGuestJobLaunch) async throws -> RGSSGuestJobHandle { try await start(launch) }
    func jobStatus(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus { try await status(handle) }
    func stopOwnedJob(_ handle: RGSSGuestJobHandle) async throws { try await stop(handle) }
}

private struct RGSSGuestClosureInputs: RGSSGuestInputPortProviding {
    let make: @Sendable (RGSSGuestSession) async throws -> any RGSSGuestInputSession
    func makeInputSession(for session: RGSSGuestSession) async throws -> any RGSSGuestInputSession {
        try await make(session)
    }
}

// MARK: - Run layout

/// Host-side staging plan. The source root is immutable; the run/save layer is
/// an explicitly owned copy, never an in-place rewrite of the imported source.
public struct RGSSGuestRunLayout: Equatable, Sendable {
    public let sourceRoot: URL
    public let hostRunRoot: URL
    public let hostSaveDirectory: URL

    public init(sourceRoot: URL, hostRunRoot: URL, hostSaveDirectory: URL) throws {
        guard sourceRoot.isFileURL, hostRunRoot.isFileURL, hostSaveDirectory.isFileURL else {
            throw RGSSGuestHostError.sourceLayerViolation("file URLs are required")
        }
        let source = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let run = hostRunRoot.standardizedFileURL.resolvingSymlinksInPath()
        let save = hostSaveDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard !Self.isDescendant(run, of: source), !Self.isDescendant(source, of: run),
              !Self.isDescendant(save, of: source) else {
            throw RGSSGuestHostError.sourceLayerViolation("run/save layers must be outside the source root")
        }
        self.sourceRoot = source
        self.hostRunRoot = run
        self.hostSaveDirectory = save
    }

    static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }
}

/// Session wrapper over the existing context-revalidating runtime adapter. A
/// new run fences the old session; a late close of the old session cannot stop
/// or mutate the new one. Detach releases input only and leaves the owned job
/// running (the existing viewer-close contract).
public actor RGSSGuestHostController {
    private let adapter: RGSSGuestRuntimeAdapter
    private let inputProvider: any RGSSGuestInputPortProviding
    private var active: (session: RGSSGuestSession, input: (any RGSSGuestInputSession)?)?
    private var starting = false
    private var generation: UInt64 = 0

    public init(
        targets: any RGSSGuestTargetResolver,
        jobs: any RGSSGuestJobService,
        inputs: any RGSSGuestInputPortProviding,
        contexts: any RGSSGuestContextHost
    ) {
        let port = RGSSLinuxGuestRuntimePort(targets: targets, jobs: jobs)
        self.adapter = RGSSGuestRuntimeAdapter(port: port, contexts: contexts)
        self.inputProvider = inputs
    }

    public init(
        port: any RGSSGuestRuntimePort,
        inputs: any RGSSGuestInputPortProviding,
        contexts: any RGSSGuestContextHost
    ) {
        self.adapter = RGSSGuestRuntimeAdapter(port: port, contexts: contexts)
        self.inputProvider = inputs
    }

    public init(bindings: RGSSGuestHostBindings, contexts: any RGSSGuestContextHost) {
        let port = RGSSLinuxGuestRuntimePort(
            targets: RGSSGuestClosureTargets(resolveTarget: bindings.resolveTarget),
            jobs: RGSSGuestClosureJobs(start: bindings.startJob,
                                       status: bindings.jobStatus,
                                       stop: bindings.stopJob))
        self.adapter = RGSSGuestRuntimeAdapter(port: port, contexts: contexts)
        self.inputProvider = RGSSGuestClosureInputs(make: bindings.makeInput)
    }

    @discardableResult
    public func start(
        context: GameProjectContext,
        engine: GameEngineID,
        displayServiceID: String,
        sourceDigest: String
    ) async throws -> RGSSGuestSession {
        guard !starting else { throw RGSSGuestHostError.staleSession }
        starting = true
        defer { starting = false }
        generation &+= 1
        let captured = generation
        if let old = active {
            await old.input?.invalidate()
            // Do not replace an owned process whose stop was not confirmed.
            // Keeping the session also lets an explicit Stop retry it.
            do { try await adapter.stop(old.session) }
            catch {
                if (error as? RGSSRuntimeError) == .guestContextMismatch {
                    removeActiveIfMatching(old.session)
                }
                throw error
            }
            removeActiveIfMatching(old.session)
        }
        guard generation == captured else { throw RGSSGuestHostError.staleSession }
        let session: RGSSGuestSession
        do {
            session = try await adapter.run(context: context, engine: engine,
                displayServiceID: displayServiceID, sourceDigest: sourceDigest)
        } catch let error as RGSSGuestStartupCleanupError {
            active = (error.session, nil)
            throw error
        }
        // Publish ownership internally before input attachment can suspend.
        active = (session, nil)
        do {
            let input = try await inputProvider.makeInputSession(for: session)
            guard generation == captured, !Task.isCancelled else {
                await input.invalidate()
                throw RGSSGuestHostError.staleSession
            }
            active = (session, input)
            return session
        } catch {
            let startupError = error
            do {
                try await adapter.stop(session)
                removeActiveIfMatching(session)
            } catch {
                // A concurrent, acknowledged Stop may already have retired the
                // same adapter session. Every other failure retains ownership.
                if await adapter.activeSession(session.jobID) == nil {
                    removeActiveIfMatching(session)
                } else {
                    throw RGSSGuestStartupCleanupError(session: session,
                        startupReason: String(describing: startupError), cleanupReason: String(describing: error))
                }
            }
            if startupError is CancellationError || (startupError as? RGSSGuestHostError) == .staleSession { throw startupError }
            throw RGSSGuestHostError.inputUnavailable
        }
    }

    public func status(_ session: RGSSGuestSession) async throws -> RGSSGuestJobStatus {
        try requireActive(session)
        return try await adapter.status(session)
    }

    public func sendChord(_ keys: [RGSSGuestInputKey], for session: RGSSGuestSession) async throws {
        let current = try requireActive(session)
        guard let input = current.input else { throw RGSSGuestHostError.inputUnavailable }
        try await input.sendChord(keys)
    }

    public func detachInput(_ session: RGSSGuestSession) async throws {
        let current = try requireActive(session)
        await current.input?.releaseAll()
    }

    public func stop(_ session: RGSSGuestSession) async throws {
        let current = try requireActive(session)
        generation &+= 1
        await current.input?.invalidate()
        // Keep the active session until the owned stop succeeds so a transient
        // host failure can be retried; the input is already released.
        do { try await adapter.stop(session) }
        catch {
            // The adapter reports a changed context only after confirmed stop.
            if (error as? RGSSRuntimeError) == .guestContextMismatch {
                removeActiveIfMatching(session)
            }
            throw error
        }
        removeActiveIfMatching(session)
    }

    /// Late close from a detached/old view: a no-op for a stale session.
    public func closeIfActive(_ session: RGSSGuestSession) async {
        guard let current = active,
              current.session.jobID == session.jobID,
              current.session.ownerToken == session.ownerToken else { return }
        // Best effort close must still retain ownership on a failed stop.
        try? await stop(current.session)
    }

    /// Includes failed startup cleanup; input may be deliberately unavailable.
    public func retainedSession() -> RGSSGuestSession? { active?.session }

    private func removeActiveIfMatching(_ session: RGSSGuestSession) {
        if active?.session.jobID == session.jobID,
           active?.session.ownerToken == session.ownerToken {
            active = nil
        }
    }

    private func requireActive(_ session: RGSSGuestSession) throws -> (session: RGSSGuestSession, input: (any RGSSGuestInputSession)?) {
        guard let current = active,
              current.session.jobID == session.jobID,
              current.session.ownerToken == session.ownerToken else {
            throw RGSSGuestHostError.staleSession
        }
        return current
    }
}
