// SPDX-License-Identifier: MPL-2.0
// App-target integration source. Copy into FloeAgent/FloeApp (or an App-owned
// feature folder); it is NOT part of the FloeGameRGSSHost package because it
// consumes App-internal display/environment services.
import Foundation
import FloeCore
import FloeExecution
import FloeGameCore
import FloeGameIDEBridge
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeGameRGSSHostLinux
import FloeGameRunKit
import FloeVNC

/// App display adapter over the existing `LocalLinuxDisplayCenter`. It reuses
/// one owner keyed by conversation/workspace and the SAME environment the
/// project context carries. It never starts a second display service.
@MainActor
final class RGSSAppDisplayWiring {
    private let center: LocalLinuxDisplayCenter
    private var inputPorts: [UUID: (owner: LocalLinuxDisplayOwner, port: RGSSVNCSessionInputPort)] = [:]

    init(center: LocalLinuxDisplayCenter) {
        self.center = center
    }

    func currentDisplayServiceID(context: GameProjectContext) -> String {
        let owner = center.owner(conversationID: conversationID(for: context.owner),
                                 workspaceRoot: context.rootURL)
        return owner.displaySessionID.uuidString
    }

    func attach(_ request: RGSSGuestDisplayRequest) async throws -> RGSSGuestDisplayAttachment {
        let owner = center.owner(conversationID: request.conversationID,
                                 workspaceRoot: request.workspaceRoot)
        await owner.beginViewerDemand()
        do {
            guard owner.environmentID == request.environmentID else {
                throw RGSSGuestRunError.displayUnavailable(
                    "the local screen belongs to a different environment")
            }
            _ = try owner.acquireToolClient()
            let port: RGSSVNCSessionInputPort
            if let cached = inputPorts[request.context.projectID], cached.owner === owner {
                port = cached.port
            } else {
                port = RGSSVNCSessionInputPort(sessionProvider: { @Sendable in
                    await MainActor.run {
                        ((try? owner.acquireToolClient())?.session) as? VNCSession
                    }
                })
                inputPorts[request.context.projectID] = (owner, port)
            }
            let session = owner.clientSession
            let demand = RGSSAppViewerDemand(owner: owner)
            return try RGSSGuestDisplayAttachment(
                environmentID: request.environmentID,
                displayServiceID: owner.displaySessionID.uuidString,
                guestDisplay: LocalLinuxDisplayOwner.guestDisplay,
                inputPort: port,
                captureScreenshot: { @Sendable in
                    await MainActor.run {
                        guard let session, let capture = try? session.captureJPEG() else { return nil }
                        return capture.data
                    }
                },
                detachViewer: { @Sendable in
                    await MainActor.run {
                        demand.end()
                    }
                })
        } catch {
            owner.endViewerDemand()
            throw error
        }
    }

    func detach(_ attachment: RGSSGuestDisplayAttachment) async {
        await attachment.detachViewer()
    }

    private func conversationID(for owner: GameProjectOwner) -> UUID? {
        if case .conversation(let conversationID, _) = owner { return conversationID }
        return nil
    }
}

/// A covered/detached view and final Stop may both release the same attachment.
/// Balance the one beginViewerDemand exactly once, preserving other viewers.
@MainActor
private final class RGSSAppViewerDemand {
    private let owner: LocalLinuxDisplayOwner
    private var ended = false
    init(owner: LocalLinuxDisplayOwner) { self.owner = owner }
    func end() {
        guard !ended else { return }
        ended = true
        owner.endViewerDemand()
    }
}

struct RGSSAppDisplayProvider: RGSSGuestDisplayProviding, @unchecked Sendable {
    private let wiring: RGSSAppDisplayWiring

    init(wiring: RGSSAppDisplayWiring) {
        self.wiring = wiring
    }

    func attach(_ request: RGSSGuestDisplayRequest) async throws -> RGSSGuestDisplayAttachment {
        try await wiring.attach(request)
    }

    func detach(_ attachment: RGSSGuestDisplayAttachment) async {
        await wiring.detach(attachment)
    }
}

/// App composition root for the three legacy RPG engines. Root creates this
/// once with the existing environment/display services and the existing
/// live-workspace contexts; it owns no editor, Git layer or second job service.
@MainActor
final class RGSSAppHost {
    let baseDirectory: URL
    let displays: RGSSAppDisplayProvider
    private let displayCenter: LocalLinuxDisplayCenter
    let environment: RGSSGuestLinuxEnvironmentPort
    let contexts: any GameRunContextHost
    let developerOverlayScript: Data?
    private let stager: RGSSGuestRunStager
    private let jobs: any RGSSGuestJobService

    /// `baseDirectory` must be the environment writable layer (mapped as
    /// `/floe/env`) or a workspace directory outside the project source; the
    /// run/save copy is read by the guest through LinuxGuestPathMap.
    init(
        baseDirectory: URL,
        displayCenter: LocalLinuxDisplayCenter,
        environment: RGSSGuestLinuxEnvironmentPort,
        jobService: any RGSSGuestJobService,
        contexts: any GameRunContextHost,
        developerOverlayScript: Data? = nil
    ) throws {
        self.baseDirectory = baseDirectory
        self.displays = RGSSAppDisplayProvider(wiring: RGSSAppDisplayWiring(center: displayCenter))
        self.displayCenter = displayCenter
        self.environment = environment
        self.contexts = contexts
        self.developerOverlayScript = developerOverlayScript
        self.stager = RGSSGuestRunStager(
            layout: try RGSSGuestRunLayout(baseDirectory: baseDirectory))
        self.jobs = jobService
    }

    /// Creates the exact run request/session for one existing IDE/Space run
    /// dispatch. The caller owns the returned session and must call `start()`,
    /// `detachView()` on background/navigation and `stop()` on explicit stop.
    func makeSession(
        for request: GameIDEProjectRunRequest,
        engineOverride: Bool = false
    ) throws -> RGSSGuestPlaySession {
        guard let environmentID = request.context.environmentID else {
            throw RGSSGuestRunError.missingEnvironment
        }
        let owner = centerOwner(for: request.context)
        let runRequest = try RGSSGuestRunRequest(
            ideRequest: request,
            displayServiceID: owner.displaySessionID.uuidString,
            engineOverride: engineOverride)
        let targets = RGSSLinuxGuestTargetProvider(
            environment: environment,
            environmentID: environmentID,
            ownerToken: request.id,
            audioDriver: nil)
        return RGSSGuestPlaySession(
            request: runRequest,
            stager: stager,
            displays: displays,
            targets: targets,
            jobs: jobs,
            contexts: contexts)
    }

    /// Unified route for Root's selection/flow service. The preparer is the
    /// existing one already used by the Web jobs; this method only adds the
    /// guest decision.
    func makeRouter(preparer: GameUnifiedRunPreparer) -> RGSSUnifiedRunRouter {
        RGSSUnifiedRunRouter(preparer: preparer, stager: stager)
    }

    func currentDisplayServiceID(for context: GameProjectContext) -> String {
        let owner = centerOwner(for: context)
        return owner.displaySessionID.uuidString
    }

    /// The existing display client for the App's `VNCViewer`. Call after
    /// `RGSSGuestPlaySession.start()` (or reattach) because the display owner
    /// connects the retained service asynchronously.
    func vncSession(for context: GameProjectContext) throws -> VNCSession {
        let owner = centerOwner(for: context)
        guard let session = try owner.acquireToolClient().session as? VNCSession else {
            throw RGSSGuestRunError.displayUnavailable("the local screen client is unavailable")
        }
        return session
    }

    private func centerOwner(for context: GameProjectContext) -> LocalLinuxDisplayOwner {
        let conversation: UUID?
        if case .conversation(let id, _) = context.owner { conversation = id } else { conversation = nil }
        return displayCenter.owner(conversationID: conversation, workspaceRoot: context.rootURL)
    }
}
