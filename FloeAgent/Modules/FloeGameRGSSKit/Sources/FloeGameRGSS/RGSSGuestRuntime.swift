// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A separately built native Linux engine. No binary is bundled here; the host
/// runs it in its existing resolved Linux guest and owns the job/display lifecycle.
public struct RGSSLinuxEnginePin: Codable, Equatable, Sendable {
    public let id: String
    public let repository: URL
    public let sourceCommit: String
    public let license: String
    public let supportedVersions: [RGSSVersion]
    public let notes: [String]

    public init(id: String, repository: URL, sourceCommit: String, license: String,
                supportedVersions: [RGSSVersion], notes: [String]) {
        self.id = id; self.repository = repository; self.sourceCommit = sourceCommit
        self.license = license; self.supportedVersions = supportedVersions; self.notes = notes
    }
}

public enum RGSSLinuxRuntimePins {
    /// The private predevelopment route: Tapir's Apache-2.0 OR MIT engine with
    /// embedded Ruby 1.8.1/1.9.2 under the Ruby license. It is a separate Linux
    /// executable; no binary is bundled in this package and no runtime result is
    /// claimed here.
    public static let tapir = RGSSLinuxEnginePin(
        id: "tapir-a56b1946-linux-aarch64",
        repository: URL(string: "https://github.com/qnighy/tapir")!,
        sourceCommit: "a56b1946b69a408db2ff5f79b48a6682cd7dd957",
        license: "Apache-2.0 OR MIT (Tapir); embedded Ruby 1.8.1/1.9.2 under the Ruby license with per-file LEGAL exceptions (Ruby 1.8.1 regex.[ch] is LGPL-2.0-or-later)",
        supportedVersions: [.rgss1, .rgss2, .rgss3],
        notes: [
            "Separate aarch64 Linux executable; not linked into the App or this SDK.",
            "Ruby 1.8.1 for XP/VX; Ruby 1.9.2p0 for VX Ace.",
            "No RTP, Enterbrain script/font/DLL or third-party game is bundled.",
            "Build/runtime evidence and final host acceptance are separate from this typed adapter."
        ])

    public static let mkxpZ = RGSSLinuxEnginePin(
        id: "mkxp-z-f02d586-native-linux",
        repository: URL(string: "https://github.com/mkxp-z/mkxp-z")!,
        sourceCommit: "f02d586624dc53de373889cc16d9b1516da0a3a5",
        license: "GPL-2.0-or-later (default OpenSSL option can make resulting binaries GPL-3.0; upstream README)",
        supportedVersions: [.rgss1, .rgss2, .rgss3],
        notes: [
            "Advertised upstream target: Linux x86/ARM/POWER with MRI/RGSS1..3 compatibility; some games require porting.",
            "This lane did not build, launch or qualify mkxp-z; the typed adapter is integration source only.",
            "No binary, RTP, DLL, font or game content is bundled.",
            "The host must use its existing environment/job/display services; this package creates no VM or shell."
        ])
}

public struct RGSSGuestLaunchRequest: Equatable, Sendable {
    public let context: GameProjectContext
    public let engine: GameEngineID
    public let environmentID: String
    public let projectRoot: URL
    public let revision: String
    public let sourceDigest: String
    public let displayServiceID: String
    public let jobID: UUID

    public init(context: GameProjectContext, engine: GameEngineID, environmentID: String,
                projectRoot: URL, revision: String, sourceDigest: String,
                displayServiceID: String, jobID: UUID) throws {
        guard RGSSEngineProfiles.isRGSS(engine), let contextEnvironment = context.environmentID,
              contextEnvironment == environmentID, projectRoot.isFileURL, projectRoot.standardizedFileURL.resolvingSymlinksInPath() == context.rootURL,
              revision == context.savedRevision,
              sourceDigest.count == 64,
              sourceDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !displayServiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RGSSRuntimeError.guestEnvironmentMissing
        }
        self.context = context; self.engine = engine; self.environmentID = environmentID
        self.projectRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.revision = revision; self.sourceDigest = sourceDigest
        self.displayServiceID = displayServiceID; self.jobID = jobID
    }
}

public struct RGSSGuestJobHandle: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let ownerToken: UUID
    public init(jobID: UUID, ownerToken: UUID) { self.jobID = jobID; self.ownerToken = ownerToken }
}

public enum RGSSGuestJobState: Equatable, Sendable {
    case starting
    case running(frameRevision: UInt64)
    case stopped
    case failed(String)
}

public struct RGSSGuestJobStatus: Equatable, Sendable {
    public let handle: RGSSGuestJobHandle
    public let state: RGSSGuestJobState
    public let elapsedMilliseconds: UInt64?
    public init(handle: RGSSGuestJobHandle, state: RGSSGuestJobState, elapsedMilliseconds: UInt64? = nil) {
        self.handle = handle; self.state = state; self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// Existing host service boundary. Implementations map these typed values onto
/// the already-resolved Linux guest, jobs and display services. This package
/// never spawns a process, downloads a module or handles VNC credentials.
public protocol RGSSGuestRuntimePort: Sendable {
    func launch(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestJobHandle
    func status(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus
    func stop(_ handle: RGSSGuestJobHandle) async throws
}

/// The host re-resolves the authoritative project/owner/root/environment after
/// every awaited operation. It is the same contract used by the Web run host.
public protocol RGSSGuestContextHost: Sendable {
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext
}

public struct RGSSGuestSession: Equatable, Sendable {
    public let jobID: UUID
    public let ownerToken: UUID
    public let context: GameProjectContext
    public let engine: GameEngineID
    public let environmentID: String
    public let sourceDigest: String
    public let displayServiceID: String
    public init(jobID: UUID, ownerToken: UUID, context: GameProjectContext, engine: GameEngineID,
                environmentID: String, sourceDigest: String, displayServiceID: String) {
        self.jobID = jobID; self.ownerToken = ownerToken; self.context = context; self.engine = engine
        self.environmentID = environmentID; self.sourceDigest = sourceDigest
        self.displayServiceID = displayServiceID
    }
}

/// A real launch failed before publication and its exact owned process did
/// not acknowledge cleanup. The host must retain this handle for Stop/retry.
public struct RGSSGuestStartupCleanupError: Error, Sendable, LocalizedError {
    public let session: RGSSGuestSession
    public let startupReason: String
    public let cleanupReason: String
    public var errorDescription: String? {
        "Game startup failed: \(startupReason). Its owned process has not confirmed stopping: \(cleanupReason)"
    }
}

public actor RGSSGuestRuntimeAdapter {
    private let port: any RGSSGuestRuntimePort
    private let contexts: any RGSSGuestContextHost
    private var active: [UUID: RGSSGuestSession] = [:]

    public init(port: any RGSSGuestRuntimePort, contexts: any RGSSGuestContextHost) {
        self.port = port; self.contexts = contexts
    }

    public func run(context: GameProjectContext, engine: GameEngineID,
                    displayServiceID: String, sourceDigest: String) async throws -> RGSSGuestSession {
        let support = try RGSSRuntimeMatrix.support(for: engine)
        guard case .typedAdapterAvailable = support.guest else {
            throw RGSSRuntimeError.guestEngineUnavailable(engine)
        }
        guard let environmentID = context.environmentID, !environmentID.isEmpty else {
            throw RGSSRuntimeError.guestEnvironmentMissing
        }
        let request = try RGSSGuestLaunchRequest(
            context: context, engine: engine, environmentID: environmentID,
            projectRoot: context.rootURL, revision: context.savedRevision,
            sourceDigest: sourceDigest, displayServiceID: displayServiceID, jobID: UUID())
        try await check(context)
        let handle = try await port.launch(request)
        guard handle.jobID == request.jobID else {
            // A mismatched transport identity is never published as a session.
            try await port.stop(handle)
            throw RGSSRuntimeError.guestLaunchRejected("job identity changed")
        }
        let session = RGSSGuestSession(
            jobID: handle.jobID, ownerToken: handle.ownerToken, context: context,
            engine: engine, environmentID: environmentID, sourceDigest: sourceDigest,
            displayServiceID: displayServiceID)
        active[handle.jobID] = session
        do {
            try Task.checkCancellation()
            try await check(context)
            let status = try await port.status(handle)
            guard status.handle == handle else { throw RGSSRuntimeError.guestJobNotOwned }
            try Task.checkCancellation()
            try await check(context)
            switch status.state {
            case .starting, .running: return session
            case .failed(let reason): throw RGSSRuntimeError.guestLaunchRejected(reason)
            case .stopped:
                active.removeValue(forKey: handle.jobID)
                throw RGSSRuntimeError.guestLaunchRejected("job stopped before the session was established")
            }
        } catch {
            let startupError = error
            if active[handle.jobID]?.ownerToken == handle.ownerToken {
                do {
                    try await port.stop(handle)
                    active.removeValue(forKey: handle.jobID)
                } catch {
                    throw RGSSGuestStartupCleanupError(session: session,
                        startupReason: String(describing: startupError), cleanupReason: String(describing: error))
                }
            }
            throw startupError
        }
    }

    public func status(_ session: RGSSGuestSession) async throws -> RGSSGuestJobStatus {
        guard active[session.jobID]?.ownerToken == session.ownerToken else {
            throw RGSSRuntimeError.guestJobNotOwned
        }
        try await check(session.context)
        let handle = RGSSGuestJobHandle(jobID: session.jobID, ownerToken: session.ownerToken)
        let status = try await port.status(handle)
        try await check(session.context)
        return status
    }

    @discardableResult
    public func stop(_ session: RGSSGuestSession) async throws -> Bool {
        guard active[session.jobID]?.ownerToken == session.ownerToken else {
            throw RGSSRuntimeError.guestJobNotOwned
        }
        let handle = RGSSGuestJobHandle(jobID: session.jobID, ownerToken: session.ownerToken)
        var contextError: RGSSRuntimeError?
        do { try await check(session.context) }
        catch { contextError = .guestContextMismatch }
        // Stop the owned job even if the context changed; never leave an owned
        // process group running. The caller still receives the context error.
        try await port.stop(handle)
        active.removeValue(forKey: session.jobID)
        if let contextError { throw contextError }
        return true
    }

    public func activeSession(_ jobID: UUID) -> RGSSGuestSession? { active[jobID] }

    private func check(_ captured: GameProjectContext) async throws {
        let current = try await contexts.currentContext(for: captured)
        do { try captured.validate(current: current) }
        catch { throw RGSSRuntimeError.guestContextMismatch }
    }

}
