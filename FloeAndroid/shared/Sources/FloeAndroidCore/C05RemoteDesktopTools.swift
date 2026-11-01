// SPDX-License-Identifier: MPL-2.0
//
// C05 ordinary remote-desktop model tools for the REAL VNC and RDP services.
//
// The donor tool contract (FloeAgent/Sources/FloeVNC/VNCTools.swift and
// RDPTool.swift @ a59b4d4005f616c611df67fab7620e9853c525b9) is preserved:
// status/connect/reconnect/disconnect/observe/clickElement/click/typeText/
// typeCredential/scroll/drag/keyPress, with the same names under `vnc.` and
// `rdp.`. Every coordinate action requires fresh screenshot evidence and
// returns a real post-action PNG artifact; dispatching input is never
// reported as task success. No host-only UI channel is registered here.
//
// Android differences are explicit:
//   * the framebuffer is RGBA from the real protocol sessions (RoyalVNCKit /
//     FreeRDP), screenshots are encoded to PNG in-process and written to the
//     App-owned artifact root supplied by composition;
//   * on-device OCR is absent, so `clickElement` is discoverable only when a
//     real text recognizer is wired by composition; it never invents
//     elements or synthesizes an accessibility tree;
//   * tool-managed sessions are fenced by the task conversation and the
//     current native epoch; a new run in the same task reuses the same
//     owner fence instead of leaking one session per message.

import Foundation
import FloeCore
import FloeModels
import FloeSecurity
import FloeSSH
import FloeTools
import FloeVNC
import FloeRDP
import CZlib

// MARK: - Screen contract

public struct C05RemoteScreenFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let revision: UInt64
    public let data: Data
    public let capturedAt: Date

    public init(width: Int, height: Int, revision: UInt64, data: Data, capturedAt: Date = Date()) {
        self.width = width
        self.height = height
        self.revision = revision
        self.data = data
        self.capturedAt = capturedAt
    }
}

public protocol C05RemoteScreenDriving: AnyObject, Sendable {
    var protocolName: String { get }
    var isConnected: Bool { get }
    var frameRevision: UInt64 { get }

    func captureFrame() throws -> C05RemoteScreenFrame
    func pointerMove(x: Int, y: Int) throws
    func pointerButton(button: String, down: Bool, x: Int, y: Int) throws
    func wheel(steps: Int, x: Int, y: Int) throws
    func key(named: String) throws
    func typeText(_ text: String, submit: Bool) throws
    func releaseAllInput()
}

public enum C05RemoteDesktopToolError: Error, LocalizedError, Sendable {
    case configurationMissing(String)
    case endpointSelectionRequired(String)
    case notConnected
    case noFrame
    case invalidCoordinate
    case invalidArgument(String)
    case artifactUnavailable
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .configurationMissing(let value): return value
        case .endpointSelectionRequired(let value): return value
        case .notConnected: return "The remote desktop is not connected"
        case .noFrame: return "The remote desktop has not produced a frame yet"
        case .invalidCoordinate: return "The remote desktop coordinate is outside the screenshot"
        case .invalidArgument(let value): return value
        case .artifactUnavailable: return "The App artifact root is unavailable; screenshots cannot be stored"
        case .unavailable(let value): return value
        }
    }
}

// MARK: - Protocol adapters

private final class C05VNCScreenSession: C05RemoteScreenDriving, @unchecked Sendable {
    let sessionID: UUID
    let session: any VNCFloeSessionDriving
    let protocolName = "vnc"

    init(sessionID: UUID, session: any VNCFloeSessionDriving) {
        self.sessionID = sessionID
        self.session = session
    }

    var isConnected: Bool { session.isConnected }
    var frameRevision: UInt64 { session.latestFrameRevision }

    func captureFrame() throws -> C05RemoteScreenFrame {
        guard let frame = session.currentFrame() else {
            throw C05RemoteDesktopToolError.noFrame
        }
        return C05RemoteScreenFrame(
            width: frame.width,
            height: frame.height,
            revision: frame.revision,
            data: frame.data,
            capturedAt: frame.capturedAt
        )
    }

    func pointerMove(x: Int, y: Int) throws {
        try send([.pointerMove(x: x, y: y)])
    }

    func pointerButton(button: String, down: Bool, x: Int, y: Int) throws {
        guard let value = VNCFloePointerButton(rawValue: button) else {
            throw C05RemoteDesktopToolError.invalidArgument("Unsupported VNC pointer button")
        }
        try send([.pointerButton(button: value, down: down, x: x, y: y)])
    }

    func wheel(steps: Int, x: Int, y: Int) throws {
        let axis: VNCFloeWheelAxis = steps > 0 ? .up : .down
        try send([.wheel(axis: axis, steps: abs(steps), x: x, y: y)])
    }

    func key(named: String) throws {
        guard let keysym = Self.keysym(named) else {
            throw C05RemoteDesktopToolError.invalidArgument("Unsupported VNC key: \(named)")
        }
        try send([
            .key(keysym: keysym, down: true),
            .key(keysym: keysym, down: false),
        ])
    }

    func typeText(_ text: String, submit: Bool) throws {
        guard text.utf8.count <= 4_096 else {
            throw C05RemoteDesktopToolError.invalidArgument("Text exceeds 4 KiB")
        }
        var events: [VNCFloeInputEvent] = [.text(text)]
        if submit { events.append(.key(keysym: 0xFF0D, down: true)); events.append(.key(keysym: 0xFF0D, down: false)) }
        try send(events)
    }

    func releaseAllInput() { session.releaseAllInput() }

    private func send(_ events: [VNCFloeInputEvent]) throws {
        do {
            try session.send(events)
        } catch {
            throw C05RemoteDesktopToolError.notConnected
        }
    }

    static func keysym(_ name: String) -> UInt32? {
        switch name.lowercased() {
        case "return", "enter": return 0xFF0D
        case "tab": return 0xFF09
        case "escape", "esc": return 0xFF1B
        case "space": return 0x0020
        case "backspace": return 0xFF08
        case "delete", "forwarddelete": return 0xFFFF
        case "left": return 0xFF51
        case "up": return 0xFF52
        case "right": return 0xFF53
        case "down": return 0xFF54
        case "pageup": return 0xFF55
        case "pagedown": return 0xFF56
        case "home": return 0xFF50
        case "end": return 0xFF57
        case "insert": return 0xFF63
        case "f1": return 0xFFBE
        case "f2": return 0xFFBF
        case "f3": return 0xFFC0
        case "f4": return 0xFFC1
        case "f5": return 0xFFC2
        case "f6": return 0xFFC3
        case "f7": return 0xFFC4
        case "f8": return 0xFFC5
        case "f9": return 0xFFC6
        case "f10": return 0xFFC7
        case "f11": return 0xFFC8
        case "f12": return 0xFFC9
        default: return nil
        }
    }
}

private final class C05RDPScreenSession: C05RemoteScreenDriving, @unchecked Sendable {
    let sessionID: UUID
    let session: any RDPFloeSessionDriving
    let protocolName = "rdp"

    init(sessionID: UUID, session: any RDPFloeSessionDriving) {
        self.sessionID = sessionID
        self.session = session
    }

    var isConnected: Bool { session.isConnected }
    var frameRevision: UInt64 { session.latestFrameRevision }

    func captureFrame() throws -> C05RemoteScreenFrame {
        guard let frame = session.currentFrame() else {
            throw C05RemoteDesktopToolError.noFrame
        }
        return C05RemoteScreenFrame(
            width: frame.width,
            height: frame.height,
            revision: frame.revision,
            data: frame.data,
            capturedAt: frame.capturedAt
        )
    }

    func pointerMove(x: Int, y: Int) throws {
        try send([.pointerMove(x: UInt16(x), y: UInt16(y))])
    }

    func pointerButton(button: String, down: Bool, x: Int, y: Int) throws {
        guard let value = RDPFloePointerButton(rawValue: button) else {
            throw C05RemoteDesktopToolError.invalidArgument("Unsupported RDP pointer button")
        }
        try send([.pointerButton(button: value, down: down, x: UInt16(x), y: UInt16(y))])
    }

    func wheel(steps: Int, x: Int, y: Int) throws {
        try send([.wheel(up: steps > 0, x: UInt16(x), y: UInt16(y), steps: UInt32(abs(steps)))])
    }

    func key(named: String) throws {
        guard let events = RDPFloeKey.namedKeyEvents(named) else {
            throw C05RemoteDesktopToolError.invalidArgument("Unsupported RDP key: \(named)")
        }
        try send(events)
    }

    func typeText(_ text: String, submit: Bool) throws {
        guard text.utf8.count <= 4_096 else {
            throw C05RemoteDesktopToolError.invalidArgument("Text exceeds 4 KiB")
        }
        var events: [RDPFloeInputEvent] = []
        if !text.isEmpty { events.append(.text(text)) }
        if submit, let returnEvents = RDPFloeKey.namedKeyEvents("return") {
            events.append(contentsOf: returnEvents)
        }
        try send(events)
    }

    func releaseAllInput() { session.releaseAllInput() }

    private func send(_ events: [RDPFloeInputEvent]) throws {
        do {
            try session.send(events)
        } catch {
            throw C05RemoteDesktopToolError.notConnected
        }
    }
}

// MARK: - Handle / coordinator

public final class C05RemoteDesktopHandle: @unchecked Sendable {
    public let protocolName: String
    public let profileID: UUID
    public let endpointID: UUID
    public let sessionID: UUID
    public let owner: C05RemoteOwner
    public let displayName: String
    public let host: String
    public let port: Int
    public let screen: any C05RemoteScreenDriving

    init(
        protocolName: String,
        profileID: UUID,
        endpointID: UUID,
        sessionID: UUID,
        owner: C05RemoteOwner,
        displayName: String,
        host: String,
        port: Int,
        screen: any C05RemoteScreenDriving
    ) {
        self.protocolName = protocolName
        self.profileID = profileID
        self.endpointID = endpointID
        self.sessionID = sessionID
        self.owner = owner
        self.displayName = displayName
        self.host = host
        self.port = port
        self.screen = screen
    }

    var target: String { "\(host):\(port)" }

    func close() async {
        screen.releaseAllInput()
    }
}

public struct C05RemoteToolConnectionStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case unconfigured, disconnected, connecting, connected, failed
    }

    public let state: State
    public let configuredEndpointCount: Int
    public let sessionID: UUID?
    public let target: String?
    public let toolManaged: Bool
    public let idleTimeoutSeconds: Int?
    public let reason: String?

    public init(
        state: State,
        configuredEndpointCount: Int,
        sessionID: UUID? = nil,
        target: String? = nil,
        toolManaged: Bool = false,
        idleTimeoutSeconds: Int? = nil,
        reason: String? = nil
    ) {
        self.state = state
        self.configuredEndpointCount = configuredEndpointCount
        self.sessionID = sessionID
        self.target = target
        self.toolManaged = toolManaged
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.reason = reason
    }
}

public struct C05RemoteToolEvidence: Sendable, Equatable {
    public let screenshotSHA256: String
    public let revision: UInt64
    public let capturedAt: Date
    public let width: Int
    public let height: Int
    /// Ownership stamped by the producing tool. A later coordinate/credential
    /// action compares every field against the live handle, so evidence from
    /// another task, session, endpoint or protocol cannot be replayed.
    public let taskID: UUID?
    public let sessionID: UUID?
    public let protocolName: String?
    public let profileID: UUID?
    public let endpointID: UUID?
    public let target: String?

    public init(
        screenshotSHA256: String,
        revision: UInt64,
        capturedAt: Date,
        width: Int,
        height: Int,
        taskID: UUID? = nil,
        sessionID: UUID? = nil,
        protocolName: String? = nil,
        profileID: UUID? = nil,
        endpointID: UUID? = nil,
        target: String? = nil
    ) {
        self.screenshotSHA256 = screenshotSHA256
        self.revision = revision
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.taskID = taskID
        self.sessionID = sessionID
        self.protocolName = protocolName
        self.profileID = profileID
        self.endpointID = endpointID
        self.target = target
    }
}

/// Honest state of the structured-text pass for the current evidence. A
/// recognizer failure is never flattened into an empty successful result.
public enum C05RemoteRecognitionState: Sendable, Equatable {
    case notConfigured
    case failed(String)
    case noText
    case current(elementCount: Int)

    public var status: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .failed: return "failed"
        case .noText: return "noText"
        case .current: return "current"
        }
    }

    public var elementsValid: Bool {
        if case .current = self { return true }
        return false
    }

    public var reason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

public struct C05RemoteToolTextElement: Sendable, Equatable {
    public let reference: String
    public let text: String
    public let confidence: Double
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public var centerX: Int { x + width / 2 }
    public var centerY: Int { y + height / 2 }
}

public protocol C05RemoteDesktopTextRecognizer: Sendable {
    func recognize(
        png: Data,
        width: Int,
        height: Int
    ) async throws -> [C05RemoteToolTextElement]
}

public struct C05RemoteDesktopToolEnvironment: Sendable {
    public let vncDomain: C05VNCDomain
    public let rdpDomain: C05RDPDomain
    public let profiles: any C05RDPProfileBridging
    public let coordinator: C05RemoteDesktopToolCoordinator
    public let currentEpoch: @Sendable () -> UInt64?
    public let artifactRoot: @Sendable () -> URL?
    public let credentialResolver: (@Sendable (UUID) async throws -> Data)?
    public let textRecognizer: (any C05RemoteDesktopTextRecognizer)?
    /// Real contextual OCR seam (Linux/Tesseract or a platform recognizer).
    /// Takes precedence over the legacy digest-only seam.
    public let contextualTextRecognizer: (any C05RemoteDesktopContextualTextRecognizing)?
    /// Bounded, best-effort engine preparation invoked ONLY from an approved
    /// connect/reconnect (never from the read-only observe).
    public let textRecognitionPreparer: (any C05RemoteDesktopTextRecognitionPreparing)?
    /// Approved secure credential-card resolver. Takes precedence over the
    /// legacy closure; production sets this and never the legacy seam.
    public let cardResolver: (any C05RemoteDesktopCredentialCardResolving)?

    public init(
        vncDomain: C05VNCDomain = .shared,
        rdpDomain: C05RDPDomain = .shared,
        profiles: any C05RDPProfileBridging = C05RemoteDomain.shared,
        currentEpoch: @escaping @Sendable () -> UInt64? = {
            G02RuntimeComposition.shared.installedComposition?.epoch
        },
        artifactRoot: @escaping @Sendable () -> URL? = { nil },
        credentialResolver: (@Sendable (UUID) async throws -> Data)? = nil,
        textRecognizer: (any C05RemoteDesktopTextRecognizer)? = nil,
        contextualTextRecognizer: (any C05RemoteDesktopContextualTextRecognizing)? = nil,
        textRecognitionPreparer: (any C05RemoteDesktopTextRecognitionPreparing)? = nil,
        cardResolver: (any C05RemoteDesktopCredentialCardResolving)? = nil,
        coordinator: C05RemoteDesktopToolCoordinator? = nil
    ) {
        self.vncDomain = vncDomain
        self.rdpDomain = rdpDomain
        self.profiles = profiles
        self.currentEpoch = currentEpoch
        self.artifactRoot = artifactRoot
        self.credentialResolver = credentialResolver
        self.textRecognizer = textRecognizer
        self.contextualTextRecognizer = contextualTextRecognizer
        self.textRecognitionPreparer = textRecognitionPreparer
        self.cardResolver = cardResolver
        self.coordinator = coordinator ?? C05RemoteDesktopToolCoordinator(
            vncDomain: vncDomain,
            rdpDomain: rdpDomain,
            profiles: profiles
        )
    }

    public static let production = C05RemoteDesktopToolEnvironment()

    public var isAvailable: Bool {
        guard let epoch = currentEpoch(), epoch > 0 else { return false }
        return true
    }

    public var hasArtifactRoot: Bool { artifactRoot() != nil }

    public var hasCredentialResolver: Bool {
        cardResolver != nil || credentialResolver != nil
    }

    public var hasTextRecognizer: Bool {
        contextualTextRecognizer != nil || textRecognizer != nil
    }
}

public actor C05RemoteDesktopToolCoordinator {
    private struct State {
        var handle: C05RemoteDesktopHandle?
        var evidence: C05RemoteToolEvidence?
        var elements: [C05RemoteToolTextElement]
        var recognition: C05RemoteRecognitionState
    }

    private let vncDomain: C05VNCDomain
    private let rdpDomain: C05RDPDomain
    private let profiles: any C05RDPProfileBridging
    private var states: [String: State] = [:]

    public init(
        vncDomain: C05VNCDomain,
        rdpDomain: C05RDPDomain,
        profiles: any C05RDPProfileBridging
    ) {
        self.vncDomain = vncDomain
        self.rdpDomain = rdpDomain
        self.profiles = profiles
    }

    private func key(_ protocolName: String, _ owner: C05RemoteOwner) -> String {
        "\(protocolName)|\(owner.taskID?.uuidString ?? owner.token)"
    }

    public func status(
        protocolName: String,
        owner: C05RemoteOwner
    ) async -> C05RemoteToolConnectionStatus {
        var count = 0
        do {
            if protocolName == "vnc" {
                let list = try await profiles.listProfiles(owner: owner)
                count = list.hosts.reduce(0) { $0 + $1.vncEndpointCount }
            } else {
                count = try await rdpDomain.modelToolEndpoints(owner: owner).count
            }
        } catch {
            return C05RemoteToolConnectionStatus(
                state: .failed,
                configuredEndpointCount: 0,
                reason: "The remote desktop service is unavailable"
            )
        }
        let storageKey = key(protocolName, owner)
        guard var state = states[storageKey], let handle = state.handle else {
            return C05RemoteToolConnectionStatus(
                state: count == 0 ? .unconfigured : .disconnected,
                configuredEndpointCount: count
            )
        }
        if handle.owner != owner {
            await closeHandle(handle)
        }
        guard handle.owner == owner, handle.screen.isConnected else {
            state.handle = nil
            state.evidence = nil
            state.elements = []
            states[storageKey] = state
            return C05RemoteToolConnectionStatus(
                state: count == 0 ? .unconfigured : .disconnected,
                configuredEndpointCount: count
            )
        }
        return C05RemoteToolConnectionStatus(
            state: .connected,
            configuredEndpointCount: count,
            sessionID: handle.sessionID,
            target: handle.target,
            toolManaged: true
        )
    }

    public func connect(
        protocolName: String,
        owner: C05RemoteOwner
    ) async throws -> C05RemoteDesktopHandle {
        let storageKey = key(protocolName, owner)
        if let existing = states[storageKey]?.handle,
           existing.owner == owner, existing.screen.isConnected {
            return existing
        }
        if let stale = states[storageKey]?.handle {
            await closeHandle(stale)
            states[storageKey] = nil
        }
        let handle = try await openHandle(protocolName: protocolName, owner: owner)
        states[storageKey] = State(handle: handle, evidence: nil, elements: [], recognition: .notConfigured)
        return handle
    }

    public func reconnect(
        protocolName: String,
        owner: C05RemoteOwner
    ) async throws -> C05RemoteDesktopHandle {
        let storageKey = key(protocolName, owner)
        if let existing = states[storageKey]?.handle {
            await closeHandle(existing)
            states[storageKey] = nil
        }
        let handle = try await openHandle(protocolName: protocolName, owner: owner)
        states[storageKey] = State(handle: handle, evidence: nil, elements: [], recognition: .notConfigured)
        return handle
    }

    public func disconnect(
        protocolName: String,
        owner: C05RemoteOwner
    ) async -> C05RemoteToolConnectionStatus {
        let storageKey = key(protocolName, owner)
        if let handle = states[storageKey]?.handle {
            await closeHandle(handle)
            states[storageKey] = nil
        }
        return await status(protocolName: protocolName, owner: owner)
    }

    public func requireHandle(
        protocolName: String,
        owner: C05RemoteOwner
    ) async throws -> C05RemoteDesktopHandle {
        let storageKey = key(protocolName, owner)
        guard let handle = states[storageKey]?.handle, handle.owner == owner else {
            throw C05RemoteDesktopToolError.configurationMissing(
                "Call \(protocolName).connect first; no tool-managed session is open."
            )
        }
        guard handle.screen.isConnected else {
            states[storageKey] = nil
            throw C05RemoteDesktopToolError.notConnected
        }
        return handle
    }

    public func remember(
        _ evidence: C05RemoteToolEvidence,
        elements: [C05RemoteToolTextElement],
        recognition: C05RemoteRecognitionState,
        handle: C05RemoteDesktopHandle
    ) {
        let storageKey = key(handle.protocolName, handle.owner)
        states[storageKey] = State(
            handle: handle,
            evidence: evidence,
            elements: elements,
            recognition: recognition
        )
    }

    public func evidence(
        handle: C05RemoteDesktopHandle
    ) -> (
        evidence: C05RemoteToolEvidence?,
        elements: [C05RemoteToolTextElement],
        recognition: C05RemoteRecognitionState
    ) {
        let storageKey = key(handle.protocolName, handle.owner)
        let state = states[storageKey]
        return (state?.evidence, state?.elements ?? [], state?.recognition ?? .notConfigured)
    }

    public func resetEvidence(handle: C05RemoteDesktopHandle) {
        let storageKey = key(handle.protocolName, handle.owner)
        states[storageKey]?.evidence = nil
        states[storageKey]?.elements = []
        states[storageKey]?.recognition = .notConfigured
    }

    /// Adopts an already-live, owner-fenced handle. Production uses
    /// `connect`; focused tests use this seam so they never fake a protocol
    /// handshake. It stores the same single handle state, not a second
    /// registry.
    func adopt(handle: C05RemoteDesktopHandle) {
        let storageKey = key(handle.protocolName, handle.owner)
        states[storageKey] = State(
            handle: handle,
            evidence: nil,
            elements: [],
            recognition: .notConfigured
        )
    }

    private func openHandle(
        protocolName: String,
        owner: C05RemoteOwner
    ) async throws -> C05RemoteDesktopHandle {
        switch protocolName {
        case "vnc":
            let list = try await profiles.listProfiles(owner: owner)
            let targets = list.hosts.filter { $0.vncEndpointCount > 0 }
            let total = targets.reduce(0) { $0 + $1.vncEndpointCount }
            guard total > 0 else {
                throw C05RemoteDesktopToolError.configurationMissing(
                    "No VNC endpoint is configured. Add one in Remote before using vnc.connect."
                )
            }
            guard total == 1, targets.count == 1 else {
                throw C05RemoteDesktopToolError.endpointSelectionRequired(
                    "Multiple VNC endpoints are configured. Open the intended host in Remote, then call vnc.connect again."
                )
            }
            let profile = targets[0]
            let detail = try await profiles.profileDetail(id: profile.id, owner: owner)
            guard detail.vncEndpoints.count == 1, let endpoint = detail.vncEndpoints.first else {
                throw C05RemoteDesktopToolError.endpointSelectionRequired(
                    "Multiple VNC endpoints are configured. Open the intended host in Remote, then call vnc.connect again."
                )
            }
            var openedSessionID: UUID?
            do {
                let snapshot = try await vncDomain.connect(
                    profileID: profile.id,
                    endpointID: endpoint.id,
                    sshSessionID: nil,
                    owner: owner
                )
                openedSessionID = snapshot.id
                let session = try await vncDomain.modelToolSession(sessionID: snapshot.id, owner: owner)
                return C05RemoteDesktopHandle(
                    protocolName: "vnc",
                    profileID: profile.id,
                    endpointID: endpoint.id,
                    sessionID: snapshot.id,
                    owner: owner,
                    displayName: snapshot.displayName,
                    host: snapshot.host,
                    port: snapshot.port,
                    screen: C05VNCScreenSession(sessionID: snapshot.id, session: session)
                )
            } catch {
                if let openedSessionID {
                    _ = try? await vncDomain.close(sessionID: openedSessionID, owner: owner)
                }
                throw mapError(error, protocolName: "vnc")
            }
        case "rdp":
            let endpoints = try await rdpDomain.modelToolEndpoints(owner: owner)
            guard !endpoints.isEmpty else {
                throw C05RemoteDesktopToolError.configurationMissing(
                    "No RDP endpoint is configured. Add one in the RDP screen before using rdp.connect."
                )
            }
            guard endpoints.count == 1 else {
                throw C05RemoteDesktopToolError.endpointSelectionRequired(
                    "Multiple RDP endpoints are configured. Open the intended host in RDP, then call rdp.connect again."
                )
            }
            let target = endpoints[0]
            var openedSessionID: UUID?
            do {
                let snapshot = try await rdpDomain.connect(
                    profileID: target.profileID,
                    endpointID: target.endpoint.id,
                    owner: owner
                )
                openedSessionID = snapshot.id
                let session = try await rdpDomain.modelToolSession(sessionID: snapshot.id, owner: owner)
                return C05RemoteDesktopHandle(
                    protocolName: "rdp",
                    profileID: target.profileID,
                    endpointID: target.endpoint.id,
                    sessionID: snapshot.id,
                    owner: owner,
                    displayName: snapshot.displayName,
                    host: snapshot.host,
                    port: snapshot.port,
                    screen: C05RDPScreenSession(sessionID: snapshot.id, session: session)
                )
            } catch {
                if let openedSessionID {
                    _ = try? await rdpDomain.close(sessionID: openedSessionID, owner: owner)
                }
                throw mapError(error, protocolName: "rdp")
            }
        default:
            throw C05RemoteDesktopToolError.invalidArgument("Unsupported remote desktop protocol")
        }
    }

    private func closeHandle(_ handle: C05RemoteDesktopHandle) async {
        handle.screen.releaseAllInput()
        switch handle.protocolName {
        case "vnc":
            _ = try? await vncDomain.close(sessionID: handle.sessionID, owner: handle.owner)
        case "rdp":
            _ = try? await rdpDomain.close(sessionID: handle.sessionID, owner: handle.owner)
        default:
            break
        }
    }

    private func mapError(_ error: Error, protocolName: String) -> C05RemoteDesktopToolError {
        if let error = error as? C05RDPError {
            if error.code == .certificateConfirmationRequired {
                let fingerprint = error.challenge?.fingerprintSHA256 ?? ""
                return .unavailable(
                    "RDP server certificate confirmation is required in the RDP screen (\(fingerprint)). The model cannot approve it."
                )
            }
            return .configurationMissing(
                "\(protocolName.uppercased()) connection failed: \(error.reason)"
            )
        }
        if let error = error as? C05RemoteError {
            return .configurationMissing(
                "\(protocolName.uppercased()) connection failed: \(error.reason)"
            )
        }
        return .configurationMissing(
            "\(protocolName.uppercased()) connection failed"
        )
    }
}

// MARK: - Artifact encoding

private enum C05PNGEncoder {
    static let maximumBytes = 64 * 1_024 * 1_024

    static func encodeRGBA(
        _ data: Data,
        width: Int,
        height: Int
    ) throws -> Data {
        guard RDPFloeFrameBounds.validate(width: width, height: height) == nil else {
            throw C05RemoteDesktopToolError.invalidArgument("Screenshot dimensions are invalid")
        }
        let rowBytes = width * 4
        guard data.count == rowBytes * height else {
            throw C05RemoteDesktopToolError.invalidArgument("Screenshot byte count does not match its dimensions")
        }
        var raw = Data(capacity: (rowBytes + 1) * height)
        for row in 0..<height {
            raw.append(0)
            raw.append(data.subdata(in: (row * rowBytes)..<((row + 1) * rowBytes)))
        }
        var compressedLength = uLongf(compressBound(uLong(raw.count)))
        var compressed = Data(count: Int(compressedLength))
        let status = compressed.withUnsafeMutableBytes { destination in
            raw.withUnsafeBytes { source in
                compress2(
                    destination.bindMemory(to: Bytef.self).baseAddress,
                    &compressedLength,
                    source.bindMemory(to: Bytef.self).baseAddress,
                    uLong(raw.count),
                    6
                )
            }
        }
        guard status == Z_OK else {
            throw C05RemoteDesktopToolError.unavailable("Screenshot compression failed")
        }
        compressed = compressed.prefix(Int(compressedLength))
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.append(contentsOf: bigEndian32(UInt32(width)))
        header.append(contentsOf: bigEndian32(UInt32(height)))
        header.append(contentsOf: [8, 6, 0, 0, 0])
        png.append(chunk("IHDR", header))
        png.append(chunk("IDAT", compressed))
        png.append(chunk("IEND", Data()))
        guard png.count <= maximumBytes else {
            throw C05RemoteDesktopToolError.invalidArgument("Screenshot exceeds the 64 MiB artifact limit")
        }
        return png
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var value = Data()
        value.append(contentsOf: bigEndian32(UInt32(payload.count)))
        let typeBytes = Data(type.utf8)
        value.append(typeBytes)
        value.append(payload)
        var crcInput = typeBytes
        crcInput.append(payload)
        value.append(contentsOf: bigEndian32(crc32(crcInput)))
        return value
    }

    private static func bigEndian32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private enum C05RemoteDesktopArtifacts {
    static func write(
        png: Data,
        protocolName: String,
        root: URL
    ) throws -> ToolArtifactReference {
        let namespace = protocolName == "rdp" ? "RDPArtifacts" : "VNCArtifacts"
        let directory = root.appendingPathComponent(namespace, isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw C05RemoteDesktopToolError.artifactUnavailable
        }
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try png.write(to: url, options: [.atomic])
        } catch {
            throw C05RemoteDesktopToolError.artifactUnavailable
        }
        cleanup(directory: directory)
        return ToolArtifactReference(
            id: id,
            relativePath: "\(namespace)/\(filename)",
            mimeType: "image/png",
            byteCount: png.count,
            sha256: FloeDigest.sha256Hex(png)
        )
    }

    private static func cleanup(directory: URL, now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(40) { try? FileManager.default.removeItem(at: file) }
        for file in sorted {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > 24 * 60 * 60 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Shared tool support

private enum C05DesktopToolSupport {
    static func owner(
        _ context: ToolContext,
        environment: C05RemoteDesktopToolEnvironment
    ) throws -> C05RemoteOwner {
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Remote desktop tools are unavailable in temporary chat; open a task to use them"
            )
        }
        guard let taskID = context.conversationID else {
            throw FloeError.validationFailed("Remote desktop tools require a task-owned run")
        }
        guard let epoch = environment.currentEpoch(), epoch > 0 else {
            throw FloeError.invalidConfiguration(
                "Remote desktop tools are unavailable for the current runtime generation"
            )
        }
        return C05RemoteOwner(
            token: "tool." + taskID.uuidString,
            nativeEpoch: epoch,
            taskID: taskID,
            temporary: false
        )
    }

    static func requireApproval(_ context: ToolContext) throws {
        guard context.approvalGrantID != nil else {
            throw FloeError.validationFailed("This remote desktop action requires approval")
        }
    }

    static func artifactRoot(
        environment: C05RemoteDesktopToolEnvironment
    ) throws -> URL {
        guard let root = environment.artifactRoot(), root.isFileURL else {
            throw C05RemoteDesktopToolError.artifactUnavailable
        }
        return root
    }

    static func statusOutput(
        _ status: C05RemoteToolConnectionStatus,
        extras: [String: Any] = [:]
    ) throws -> ToolExecutionOutput {
        var payload: [String: Any] = [
            "status": "ok",
            "connectionState": status.state.rawValue,
            "configuredEndpointCount": status.configuredEndpointCount,
            "sessionID": status.sessionID?.uuidString ?? NSNull(),
            "target": status.target ?? NSNull(),
            "toolManaged": status.toolManaged,
            "idleTimeoutSeconds": status.idleTimeoutSeconds ?? NSNull(),
            "failure": NSNull(),
        ]
        if let reason = status.reason {
            payload["failure"] = ["reason": reason]
        }
        for (key, value) in extras { payload[key] = value }
        return try output(payload)
    }

    static func readinessJSON(_ readiness: C05TextRecognitionReadiness) -> [String: Any] {
        var value: [String: Any] = [
            "state": readiness.state.rawValue,
            "engine": readiness.engine,
            "languages": readiness.languages,
            "version": readiness.version ?? NSNull(),
            "reason": readiness.reason ?? NSNull(),
        ]
        if let command = readiness.preparationCommand {
            value["preparationCommand"] = command
        }
        return value
    }

    static func preparedExtras(
        environment: C05RemoteDesktopToolEnvironment,
        context: ToolContext
    ) async -> [String: Any] {
        guard let preparer = environment.textRecognitionPreparer else { return [:] }
        let readiness = await preparer.prepare(context: context)
        return ["textRecognition": readinessJSON(readiness)]
    }

    static func output(
        _ fields: [String: Any],
        artifacts: [ToolArtifactReference] = []
    ) throws -> ToolExecutionOutput {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw FloeError.internalError("The remote desktop result could not be encoded")
        }
        return ToolExecutionOutput(
            summary: text,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: 0,
            artifacts: artifacts
        )
    }

    static func fail(_ error: Error) -> FloeError {
        if let error = error as? C05RemoteDesktopToolError {
            return FloeError.validationFailed(error.localizedDescription)
        }
        if let error = error as? FloeError {
            return error
        }
        return FloeError.validationFailed("The remote desktop operation could not be completed")
    }

    static func capture(
        handle: C05RemoteDesktopHandle,
        environment: C05RemoteDesktopToolEnvironment
    ) throws -> (
        artifact: ToolArtifactReference,
        capture: C05RemoteScreenFrame,
        png: Data
    ) {
        let frame = try handle.screen.captureFrame()
        let png = try C05PNGEncoder.encodeRGBA(frame.data, width: frame.width, height: frame.height)
        let artifact = try C05RemoteDesktopArtifacts.write(
            png: png,
            protocolName: handle.protocolName,
            root: try artifactRoot(environment: environment)
        )
        return (artifact, frame, png)
    }

    static func evidence(
        capture: C05RemoteScreenFrame,
        artifact: ToolArtifactReference,
        handle: C05RemoteDesktopHandle
    ) -> C05RemoteToolEvidence {
        C05RemoteToolEvidence(
            screenshotSHA256: artifact.sha256,
            revision: capture.revision,
            capturedAt: capture.capturedAt,
            width: capture.width,
            height: capture.height,
            taskID: handle.owner.taskID,
            sessionID: handle.sessionID,
            protocolName: handle.protocolName,
            profileID: handle.profileID,
            endpointID: handle.endpointID,
            target: handle.target
        )
    }

    /// Re-reads the exact live fence the evidence was stamped with. This is
    /// called again AFTER every await in a coordinate/credential action, so a
    /// disconnected/replaced session or a new native epoch can never receive
    /// input based on stale evidence.
    static func requireLiveHandle(
        _ handle: C05RemoteDesktopHandle,
        owner: C05RemoteOwner,
        environment: C05RemoteDesktopToolEnvironment
    ) throws {
        guard handle.owner == owner,
              handle.owner.taskID == owner.taskID,
              handle.owner.nativeEpoch == owner.nativeEpoch else {
            throw C05RemoteDesktopToolError.notConnected
        }
        guard let epoch = environment.currentEpoch(), epoch == owner.nativeEpoch else {
            throw C05RemoteDesktopToolError.notConnected
        }
        guard handle.screen.isConnected else {
            throw C05RemoteDesktopToolError.notConnected
        }
    }

    static func validateOwnership(
        _ evidence: C05RemoteToolEvidence,
        handle: C05RemoteDesktopHandle
    ) throws {
        guard evidence.taskID == handle.owner.taskID,
              evidence.sessionID == handle.sessionID,
              evidence.protocolName == handle.protocolName,
              evidence.profileID == handle.profileID,
              evidence.endpointID == handle.endpointID,
              evidence.target == handle.target else {
            throw C05RemoteDesktopToolError.invalidArgument(
                "The screenshot evidence belongs to a different remote session; call \(handle.protocolName).observe again"
            )
        }
    }

    static func validatePoint(
        x: Int,
        y: Int,
        screenshotSHA256: String,
        handle: C05RemoteDesktopHandle,
        coordinator: C05RemoteDesktopToolCoordinator
    ) async throws -> C05RemoteToolEvidence {
        let stored = await coordinator.evidence(handle: handle).evidence
        guard let stored,
              stored.screenshotSHA256.caseInsensitiveCompare(screenshotSHA256) == .orderedSame else {
            throw C05RemoteDesktopToolError.invalidArgument(
                "Call \(handle.protocolName).observe first and pass its fresh screenshotSHA256"
            )
        }
        try validateOwnership(stored, handle: handle)
        guard Date().timeIntervalSince(stored.capturedAt) <= 15 else {
            throw C05RemoteDesktopToolError.invalidArgument(
                "Screenshot evidence expired; call \(handle.protocolName).observe again"
            )
        }
        guard stored.revision == handle.screen.frameRevision else {
            throw C05RemoteDesktopToolError.invalidArgument(
                "The remote screen changed after the screenshot; call \(handle.protocolName).observe again"
            )
        }
        guard x >= 0, y >= 0, x < stored.width, y < stored.height else {
            throw C05RemoteDesktopToolError.invalidCoordinate
        }
        return stored
    }

    static func postActionCapture(
        handle: C05RemoteDesktopHandle,
        before: C05RemoteToolEvidence?,
        environment: C05RemoteDesktopToolEnvironment,
        timeoutMilliseconds: Int = 1_500
    ) async throws -> (artifact: ToolArtifactReference, capture: C05RemoteScreenFrame, changed: Bool) {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        var lastRevision = handle.screen.frameRevision
        var stableSince = Date()
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            let revision = handle.screen.frameRevision
            if revision != lastRevision {
                lastRevision = revision
                stableSince = Date()
            }
            if let before, revision != before.revision,
               Date().timeIntervalSince(stableSince) >= 0.25 {
                break
            }
        }
        let captured = try capture(handle: handle, environment: environment)
        let changed = before.map {
            $0.screenshotSHA256.caseInsensitiveCompare(captured.artifact.sha256) != .orderedSame
        } ?? true
        return (captured.artifact, captured.capture, changed)
    }

    static func postActionOutput(
        handle: C05RemoteDesktopHandle,
        before: C05RemoteToolEvidence?,
        environment: C05RemoteDesktopToolEnvironment,
        coordinator: C05RemoteDesktopToolCoordinator,
        details: [String: Any] = [:]
    ) async throws -> ToolExecutionOutput {
        var fields = details
        fields["sessionID"] = handle.sessionID.uuidString
        fields["inputDispatched"] = true
        fields["inputStatus"] = "queued"
        fields["serverAcknowledged"] = false
        fields["taskSuccessVerified"] = false
        do {
            let post = try await postActionCapture(
                handle: handle,
                before: before,
                environment: environment
            )
            let evidence = evidence(
                capture: post.capture,
                artifact: post.artifact,
                handle: handle
            )
            await coordinator.remember(
                evidence,
                elements: [],
                recognition: .notConfigured,
                handle: handle
            )
            fields["status"] = "ok"
            fields["frameChanged"] = post.changed
            fields["frameUpdateReceived"] = post.capture.revision != before?.revision
            fields["observationStatus"] = post.capture.revision == before?.revision
                ? "noNewFrame" : (post.changed ? "changed" : "unchanged")
            fields["pixelWidth"] = post.capture.width
            fields["pixelHeight"] = post.capture.height
            fields["revision"] = NSNumber(value: post.capture.revision)
            fields["screenshotSHA256"] = post.artifact.sha256
            fields["screenshotPath"] = post.artifact.relativePath
            fields["capturedAt"] = ISO8601DateFormatter().string(from: post.capture.capturedAt)
            fields["coordinateSpace"] = "framebufferPixels"
            fields["structureSource"] = "none"
            fields["evidenceStatus"] = "current"
            fields["recognizerStatus"] = "notRun"
            fields["recognizerEvidenceValid"] = false
            fields["structuredElementCount"] = 0
            fields["elements"] = []
            fields["nextAction"] = "Use this result's screenshotSHA256 for the next coordinate action; observe again only when evidence is stale."
            return try output(fields, artifacts: [post.artifact])
        } catch {
            fields["status"] = "partialSuccess"
            fields["observationStatus"] = error is CancellationError ? "cancelled" : "unavailable"
            fields["retryInput"] = false
            fields["nextAction"] = "Input may already have executed. Do not replay it; obtain fresh \(handle.protocolName).observe evidence when the session is available."
            return try output(fields)
        }
    }
}

// MARK: - Protocol kinds and tools

public protocol C05RemoteDesktopProtocolKind: Sendable {
    static var wireName: String { get }
    static var displayName: String { get }
}

public enum C05VNCProtocolKind: C05RemoteDesktopProtocolKind {
    public static let wireName = "vnc"
    public static let displayName = "VNC"
}

public enum C05RDPProtocolKind: C05RemoteDesktopProtocolKind {
    public static let wireName = "rdp"
    public static let displayName = "RDP"
}

public struct C05DesktopStatusTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static var name: String { "\(P.wireName).status" }
    public static var toolDescription: String {
        "Read the current \(P.displayName) connection state without opening a connection. Returns configured endpoint count, active tool-managed session and the latest failure when available."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{},"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [] }
    public static var isSideEffecting: Bool { false }
    public static var toolEffect: ToolEffect { .readOnly }
    public static var requiresHostScope: Bool { false }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        let status = await environment.coordinator.status(
            protocolName: P.wireName,
            owner: owner
        )
        return try C05DesktopToolSupport.statusOutput(status)
    }
}

public struct C05DesktopConnectTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static var name: String { "\(P.wireName).connect" }
    public static var toolDescription: String {
        "Connect the single configured or previously selected \(P.displayName) endpoint and keep the tool-managed session alive for this task. Use \(P.wireName).status first when the connection is ambiguous. The first connection may prepare the task's Linux text-recognition engine used by clickElement."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{},"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI, .accessesCredentials] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            _ = try await environment.coordinator.connect(protocolName: P.wireName, owner: owner)
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
        let status = await environment.coordinator.status(protocolName: P.wireName, owner: owner)
        let extras = await C05DesktopToolSupport.preparedExtras(
            environment: environment,
            context: context
        )
        return try C05DesktopToolSupport.statusOutput(status, extras: extras)
    }
}

public struct C05DesktopReconnectTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static var name: String { "\(P.wireName).reconnect" }
    public static var toolDescription: String {
        "Discard the tool-managed \(P.displayName) session and perform a fresh handshake. A non-retryable authentication or certificate failure remains blocked until the saved credential or trust decision is updated."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{},"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI, .accessesCredentials] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            _ = try await environment.coordinator.reconnect(protocolName: P.wireName, owner: owner)
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
        let status = await environment.coordinator.status(protocolName: P.wireName, owner: owner)
        let extras = await C05DesktopToolSupport.preparedExtras(
            environment: environment,
            context: context
        )
        return try C05DesktopToolSupport.statusOutput(status, extras: extras)
    }
}

public struct C05DesktopDisconnectTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static var name: String { "\(P.wireName).disconnect" }
    public static var toolDescription: String {
        "Close the tool-managed \(P.displayName) session. User-opened viewer sessions are left alone. Returns the resulting connection state."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{},"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        let status = await environment.coordinator.disconnect(
            protocolName: P.wireName,
            owner: owner
        )
        return try C05DesktopToolSupport.statusOutput(status)
    }
}

public struct C05DesktopObserveTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static var name: String { "\(P.wireName).observe" }
    public static var toolDescription: String {
        "Capture the connected \(P.displayName) framebuffer before actions. Returns exact pixel bounds, screenshotSHA256, a verified PNG image artifact and text regions produced by the real \(P.displayName) text recognizer. \(P.displayName) has no native DOM/accessibility tree, so never invent controls or roles. If recognizerStatus is not current, text anchors are unavailable and only pixel coordinates may be used."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{},"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.sendsDataToProvider] }
    public static var isSideEffecting: Bool { false }
    public static var toolEffect: ToolEffect { .readOnly }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] {
        [ToolPrerequisite(
            state: "\(P.wireName).connected",
            resolverToolName: "\(P.wireName).connect",
            mayResolveAutomatically: true
        )]
    }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            let captured = try C05DesktopToolSupport.capture(handle: handle, environment: environment)
            let evidence = C05DesktopToolSupport.evidence(
                capture: captured.capture,
                artifact: captured.artifact,
                handle: handle
            )
            let png = captured.png
            let ownership = C05DesktopFrameOwnership(
                taskID: owner.taskID ?? handle.sessionID,
                sessionID: handle.sessionID,
                protocolName: handle.protocolName,
                profileID: handle.profileID,
                endpointID: handle.endpointID,
                target: handle.target,
                frameRevision: captured.capture.revision,
                capturedAt: captured.capture.capturedAt,
                screenshotSHA256: captured.artifact.sha256,
                isCurrent: {
                    guard let epoch = environment.currentEpoch(),
                          epoch == owner.nativeEpoch else { return false }
                    return handle.owner == owner
                        && handle.screen.isConnected
                        && handle.screen.frameRevision == captured.capture.revision
                }
            )
            var elements: [C05RemoteToolTextElement] = []
            var recognition: C05RemoteRecognitionState = .notConfigured
            if let recognizer = environment.contextualTextRecognizer {
                do {
                    let raw = try await recognizer.recognize(C05DesktopTextRecognitionRequest(
                        png: png,
                        width: captured.capture.width,
                        height: captured.capture.height,
                        ownership: ownership,
                        context: context
                    ))
                    let sanitized = Self.sanitizedElements(
                        raw,
                        width: captured.capture.width,
                        height: captured.capture.height
                    )
                    if raw.isEmpty {
                        recognition = .noText
                    } else if sanitized.isEmpty {
                        recognition = .failed(
                            "The text recognizer returned no anchor inside the observed frame"
                        )
                    } else {
                        elements = sanitized
                        recognition = .current(elementCount: sanitized.count)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as C05DesktopAssistError {
                    recognition = .failed(error.localizedDescription)
                } catch {
                    recognition = .failed("Text recognition failed")
                }
            } else if let recognizer = environment.textRecognizer {
                do {
                    let raw = try await recognizer.recognize(
                        png: png,
                        width: captured.capture.width,
                        height: captured.capture.height
                    )
                    let sanitized = Self.sanitizedElements(
                        raw,
                        width: captured.capture.width,
                        height: captured.capture.height
                    )
                    if raw.isEmpty {
                        recognition = .noText
                    } else if sanitized.isEmpty {
                        recognition = .failed(
                            "The text recognizer returned no anchor inside the observed frame"
                        )
                    } else {
                        elements = sanitized
                        recognition = .current(elementCount: sanitized.count)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    recognition = .failed("Text recognition failed")
                }
            }
            await environment.coordinator.remember(
                evidence,
                elements: elements,
                recognition: recognition,
                handle: handle
            )
            let evidenceCurrent = handle.screen.frameRevision == captured.capture.revision
                && handle.screen.isConnected
                && handle.owner == owner
            var fields: [String: Any] = [
                "status": recognition.reason == nil ? "ok" : "partialSuccess",
                "sessionID": handle.sessionID.uuidString,
                "taskID": owner.taskID?.uuidString ?? NSNull(),
                "protocol": handle.protocolName,
                "profileID": handle.profileID.uuidString,
                "endpointID": handle.endpointID.uuidString,
                "target": handle.target,
                "pixelWidth": captured.capture.width,
                "pixelHeight": captured.capture.height,
                "revision": NSNumber(value: captured.capture.revision),
                "screenshotSHA256": captured.artifact.sha256,
                "screenshotPath": captured.artifact.relativePath,
                "capturedAt": ISO8601DateFormatter().string(from: captured.capture.capturedAt),
                "coordinateSpace": "framebufferPixels",
                "structureSource": recognition.elementsValid
                    ? (environment.contextualTextRecognizer != nil
                        ? "linuxTesseractTextRecognizer" : "onDeviceTextRecognizer")
                    : "none",
                "evidenceStatus": evidenceCurrent ? "current" : "stale",
                "recognizerStatus": recognition.status,
                "recognizerEvidenceValid": recognition.elementsValid,
                "structuredElementCount": elements.count,
                "elements": elements.map { element in
                    [
                        "reference": element.reference,
                        "kind": "recognizedText",
                        "text": element.text,
                        "confidence": element.confidence,
                        "x": element.x,
                        "y": element.y,
                        "width": element.width,
                        "height": element.height,
                        "centerX": element.centerX,
                        "centerY": element.centerY,
                    ] as [String: Any]
                },
            ]
            if let reason = recognition.reason {
                fields["recognizerFailure"] = reason
                fields["recognizerPreparationCommand"] =
                    C05LinuxTesseractConfiguration.preparationCommand
                fields["nextAction"] =
                    "Text anchors are unavailable. Use \(P.wireName).click with pixel coordinates, or prepare the Linux OCR engine and observe again."
            } else if !recognition.elementsValid {
                fields["nextAction"] =
                    "No text anchor is available. Use \(P.wireName).click with pixel coordinates."
            }
            if !evidenceCurrent {
                fields["nextAction"] =
                    "The screenshot is already stale; call \(P.wireName).observe again before acting."
            }
            return try C05DesktopToolSupport.output(fields, artifacts: [captured.artifact])
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }

    /// Re-stamps references so a recognizer cannot supply model-chosen IDs and
    /// drops anchors whose pixel bounds are not inside this exact frame.
    static func sanitizedElements(
        _ raw: [C05RemoteToolTextElement],
        width: Int,
        height: Int
    ) -> [C05RemoteToolTextElement] {
        var result: [C05RemoteToolTextElement] = []
        for element in raw.prefix(C05RemoteDesktopToolLimits.maximumTextElements) {
            let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 500,
                  element.width > 0, element.height > 0,
                  element.x >= 0, element.y >= 0,
                  element.x + element.width <= width,
                  element.y + element.height <= height,
                  element.confidence.isFinite,
                  (0...1).contains(element.confidence) else { continue }
            result.append(C05RemoteToolTextElement(
                reference: "text-\(result.count + 1)",
                text: String(text.prefix(500)),
                confidence: element.confidence,
                x: element.x,
                y: element.y,
                width: element.width,
                height: element.height
            ))
        }
        return result
    }
}

public struct C05DesktopClickTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var x: Int
        public var y: Int
        public var screenshotSHA256: String
        public var clickCount: Int?
    }
    public static var name: String { "\(P.wireName).click" }
    public static var toolDescription: String {
        "Click a framebuffer pixel from the latest \(P.wireName).observe or action result. Pass its exact screenshotSHA256. Returns a post-action PNG screenshot and reusable evidence; frameChanged alone is not proof of task success."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{"x":{"type":"integer","minimum":0},"y":{"type":"integer","minimum":0},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"clickCount":{"type":"integer","minimum":1,"maximum":2}},"required":["x","y","screenshotSHA256"],"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI, .executesRemoteCommand] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] { C05DesktopObserveTool<P>.prerequisites }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard args.x >= 0, args.y >= 0, (1...2).contains(args.clickCount ?? 1) else {
            throw FloeError.validationFailed("coordinates must be non-negative and clickCount must be 1 or 2")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            let evidence = try await C05DesktopToolSupport.validatePoint(
                x: args.x,
                y: args.y,
                screenshotSHA256: args.screenshotSHA256,
                handle: handle,
                coordinator: environment.coordinator
            )
            try context.cancellation.throwIfCancelled()
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            guard evidence.revision == handle.screen.frameRevision else {
                throw C05RemoteDesktopToolError.invalidArgument(
                    "The remote screen changed before the click; call \(P.wireName).observe again"
                )
            }
            var queued = 0
            let count = args.clickCount ?? 1
            do {
                for index in 0..<count {
                    try context.cancellation.throwIfCancelled()
                    try handle.screen.pointerMove(x: args.x, y: args.y)
                    try handle.screen.pointerButton(button: "left", down: true, x: args.x, y: args.y)
                    try handle.screen.pointerButton(button: "left", down: false, x: args.x, y: args.y)
                    queued += 1
                    if index + 1 < count { try await Task.sleep(nanoseconds: 100_000_000) }
                }
            } catch {
                try? handle.screen.pointerButton(button: "left", down: false, x: args.x, y: args.y)
                throw error
            }
            return try await C05DesktopToolSupport.postActionOutput(
                handle: handle,
                before: evidence,
                environment: environment,
                coordinator: environment.coordinator,
                details: ["x": args.x, "y": args.y, "clickCount": queued]
            )
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }
}

public struct C05DesktopClickElementTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var reference: String
        public var screenshotSHA256: String
        public var clickCount: Int?
    }
    public static var name: String { "\(P.wireName).clickElement" }
    public static var toolDescription: String {
        "Click the center of a recognized text reference from the latest \(P.wireName).observe result. This is a visual text anchor produced by a real text-recognition pass over the observed PNG, not a native accessibility control or a model-invented element. Requires a configured text recognizer and current evidence."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{"reference":{"type":"string","pattern":"^text-[1-9][0-9]*$"},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"clickCount":{"type":"integer","minimum":1,"maximum":2}},"required":["reference","screenshotSHA256"],"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI, .executesRemoteCommand] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] { C05DesktopObserveTool<P>.prerequisites }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard args.reference.range(of: #"^text-[1-9][0-9]*$"#, options: .regularExpression) != nil,
              (1...2).contains(args.clickCount ?? 1) else {
            throw FloeError.validationFailed("reference must be text-N and clickCount must be 1 or 2")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        guard environment.hasTextRecognizer else {
            throw FloeError.validationFailed(
                "Text recognition is not configured; use \(P.wireName).observe and \(P.wireName).click with pixel coordinates"
            )
        }
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            let stored = await environment.coordinator.evidence(handle: handle)
            guard let evidence = stored.evidence,
                  evidence.screenshotSHA256.caseInsensitiveCompare(args.screenshotSHA256) == .orderedSame,
                  stored.recognition.elementsValid,
                  Date().timeIntervalSince(evidence.capturedAt) <= 15,
                  evidence.revision == handle.screen.frameRevision,
                  let element = stored.elements.first(where: { $0.reference == args.reference }) else {
                throw C05RemoteDesktopToolError.invalidArgument(
                    "Structured \(P.displayName) evidence is missing, changed, expired, or the recognizer failed; call \(P.wireName).observe again"
                )
            }
            try C05DesktopToolSupport.validateOwnership(evidence, handle: handle)
            guard element.width > 0, element.height > 0,
                  element.x >= 0, element.y >= 0,
                  element.x + element.width <= evidence.width,
                  element.y + element.height <= evidence.height else {
                throw C05RemoteDesktopToolError.invalidArgument(
                    "The text anchor is outside the observed frame; call \(P.wireName).observe again"
                )
            }
            let point = try await C05DesktopToolSupport.validatePoint(
                x: element.centerX,
                y: element.centerY,
                screenshotSHA256: args.screenshotSHA256,
                handle: handle,
                coordinator: environment.coordinator
            )
            // Re-read the live fence after the actor hop: a disconnect,
            // epoch change or frame change must not receive this click.
            try context.cancellation.throwIfCancelled()
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            guard point.revision == handle.screen.frameRevision else {
                throw C05RemoteDesktopToolError.invalidArgument(
                    "The remote screen changed before the click; call \(P.wireName).observe again"
                )
            }
            let count = args.clickCount ?? 1
            for index in 0..<count {
                try context.cancellation.throwIfCancelled()
                try handle.screen.pointerMove(x: element.centerX, y: element.centerY)
                try handle.screen.pointerButton(
                    button: "left", down: true, x: element.centerX, y: element.centerY
                )
                try handle.screen.pointerButton(
                    button: "left", down: false, x: element.centerX, y: element.centerY
                )
                if index + 1 < count { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            return try await C05DesktopToolSupport.postActionOutput(
                handle: handle,
                before: point,
                environment: environment,
                coordinator: environment.coordinator,
                details: [
                    "reference": element.reference,
                    "recognizedText": element.text,
                    "recognizedTextConfidence": element.confidence,
                    "anchorKind": "recognizedText",
                    "x": element.centerX,
                    "y": element.centerY,
                    "clickCount": count,
                ]
            )
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }
}

public struct C05DesktopTypeTextTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var text: String
        public var submit: Bool?
    }
    public static var name: String { "\(P.wireName).typeText" }
    public static var toolDescription: String {
        "Type bounded text into the current \(P.displayName) focus and optionally press Return. Returns a post-action PNG screenshot; verify visually that the focused field accepted the text."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{"text":{"type":"string","maxLength":4096},"submit":{"type":"boolean"}},"required":["text"],"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI, .executesRemoteCommand, .sendsDataToProvider] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] { C05DesktopObserveTool<P>.prerequisites }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard !args.text.isEmpty, args.text.utf8.count <= 4_096 else {
            throw FloeError.validationFailed("text must be 1-4096 UTF-8 bytes")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            let before = await environment.coordinator.evidence(handle: handle).evidence
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            try handle.screen.typeText(args.text, submit: args.submit == true)
            return try await C05DesktopToolSupport.postActionOutput(
                handle: handle,
                before: before,
                environment: environment,
                coordinator: environment.coordinator,
                details: ["characterCount": args.text.count, "submitted": args.submit == true]
            )
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }
}

public struct C05DesktopTypeCredentialTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var credentialRef: String
        public var submit: Bool?
    }
    public static var name: String { "\(P.wireName).typeCredential" }
    public static var toolDescription: String {
        "Type a previously saved Floe secure credential card into the current \(P.displayName) focus. Pass credentialRef exactly as shown in context; plaintext is resolved only inside the approved executor and is never returned."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{"credentialRef":{"type":"string","pattern":"^⟨credential:[0-9A-Fa-f-]{36}⟩$"},"submit":{"type":"boolean"}},"required":["credentialRef"],"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [
        .controlsGUI, .executesRemoteCommand, .sendsDataToProvider, .accessesCredentials
    ] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] { C05DesktopObserveTool<P>.prerequisites }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard SecretIngressScanner.credentialID(from: args.credentialRef) != nil else {
            throw FloeError.validationFailed("credentialRef must reference a Floe secure credential card")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        guard let credentialID = SecretIngressScanner.credentialID(from: args.credentialRef) else {
            throw FloeError.validationFailed("credentialRef must reference a Floe secure credential card")
        }
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            if let resolver = environment.cardResolver {
                // Scoped card path. The real permission gate is the existing
                // approval grant plus the runtime-issued authority for this
                // exact approved call; the card scope/host/kind checks run in
                // the resolver over the ORIGINAL credential metadata.
                guard let authority = context.runtimeAuthority,
                      authority.toolName == Self.name,
                      authority.runID == context.runID,
                      authority.taskID == context.conversationID,
                      authority.approvalGrantID == context.approvalGrantID,
                      authority.issuedAt <= Date(),
                      Date() < authority.expiresAt else {
                    throw FloeError.validationFailed(
                        "This credential action has no current approved task authority"
                    )
                }
                guard let approvalGrantID = context.approvalGrantID,
                      let taskID = context.conversationID else {
                    throw FloeError.validationFailed(
                        "This credential action requires an approved task-owned run"
                    )
                }
                try C05DesktopToolSupport.requireLiveHandle(
                    handle,
                    owner: owner,
                    environment: environment
                )
                let request = C05DesktopCredentialCardRequest(
                    credentialID: credentialID,
                    taskID: taskID,
                    runID: context.runID,
                    protocolName: handle.protocolName,
                    profileID: handle.profileID,
                    endpointID: handle.endpointID,
                    sessionID: handle.sessionID,
                    target: handle.target,
                    owner: owner,
                    approvalGrantID: approvalGrantID,
                    runtimeAuthorityID: authority.id,
                    isCurrent: {
                        guard let epoch = environment.currentEpoch(),
                              epoch == owner.nativeEpoch else { return false }
                        return handle.owner == owner && handle.screen.isConnected
                    }
                )
                let resolution = try await resolver.resolveCredentialCard(request)
                var bytes = resolution.secret
                defer { bytes.resetBytes(in: bytes.indices) }
                try context.cancellation.throwIfCancelled()
                // Post-await fence: same task/owner/epoch/session/endpoint/
                // target must still be live before the protocol write.
                try C05DesktopToolSupport.requireLiveHandle(
                    handle,
                    owner: owner,
                    environment: environment
                )
                guard handle.sessionID == request.sessionID,
                      handle.endpointID == request.endpointID,
                      handle.profileID == request.profileID,
                      handle.protocolName == request.protocolName,
                      handle.target == request.target else {
                    throw C05DesktopAssistError.liveSessionChanged
                }
                guard authority.id == request.runtimeAuthorityID,
                      Date() < authority.expiresAt else {
                    throw FloeError.validationFailed(
                        "The approved task authority expired before the credential could be typed"
                    )
                }
                guard !bytes.isEmpty, bytes.count <= 4_096,
                      let text = String(data: bytes, encoding: .utf8) else {
                    throw FloeError.validationFailed(
                        "Saved credential is empty, too large, or not UTF-8 text"
                    )
                }
                try handle.screen.typeText(text, submit: args.submit == true)
                return try C05DesktopToolSupport.output([
                    "status": "ok",
                    "sessionID": handle.sessionID.uuidString,
                    "credentialCardID": resolution.credentialID.uuidString,
                    "credentialKind": resolution.kind.rawValue,
                    "credentialCardOwner": resolution.ownerKind,
                    "credentialScopeVerified": true,
                    "sessionRevalidated": true,
                    "credentialDispatched": true,
                    "inputStatus": "queued",
                    "serverAcknowledged": false,
                    "submitted": args.submit == true,
                    "observationStatus": "suppressedForCredentialPrivacy",
                    "nextAction": "Verify the remote focus safely before requesting new visual evidence. Do not replay credential input.",
                ])
            }
            guard let legacy = environment.credentialResolver else {
                throw FloeError.validationFailed("Saved credential resolution is unavailable")
            }
            var bytes = try await legacy(credentialID)
            defer { bytes.resetBytes(in: bytes.indices) }
            guard !bytes.isEmpty, bytes.count <= 4_096,
                  let text = String(data: bytes, encoding: .utf8) else {
                throw FloeError.validationFailed("Saved credential is empty, too large, or not UTF-8 text")
            }
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            try handle.screen.typeText(text, submit: args.submit == true)
            return try C05DesktopToolSupport.output([
                "status": "ok",
                "sessionID": handle.sessionID.uuidString,
                "credentialDispatched": true,
                "inputStatus": "queued",
                "serverAcknowledged": false,
                "submitted": args.submit == true,
                "observationStatus": "suppressedForCredentialPrivacy",
                "nextAction": "Verify the remote focus safely before requesting new visual evidence. Do not replay credential input.",
            ])
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }
}

public struct C05DesktopScrollTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var x: Int
        public var y: Int
        public var deltaY: Int
        public var screenshotSHA256: String
    }
    public static var name: String { "\(P.wireName).scroll" }
    public static var toolDescription: String {
        "Scroll at a point from the latest \(P.wireName).observe screenshot. Positive deltaY scrolls up; negative scrolls down. Returns a post-action PNG screenshot."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{"x":{"type":"integer","minimum":0},"y":{"type":"integer","minimum":0},"deltaY":{"type":"integer","minimum":-20,"maximum":20},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"}},"required":["x","y","deltaY","screenshotSHA256"],"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] { C05DesktopObserveTool<P>.prerequisites }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard args.deltaY != 0, (-20...20).contains(args.deltaY) else {
            throw FloeError.validationFailed("deltaY must be between -20 and 20 and non-zero")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            let evidence = try await C05DesktopToolSupport.validatePoint(
                x: args.x,
                y: args.y,
                screenshotSHA256: args.screenshotSHA256,
                handle: handle,
                coordinator: environment.coordinator
            )
            try context.cancellation.throwIfCancelled()
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            guard evidence.revision == handle.screen.frameRevision else {
                throw C05RemoteDesktopToolError.invalidArgument(
                    "The remote screen changed before the scroll; call \(P.wireName).observe again"
                )
            }
            try handle.screen.wheel(steps: args.deltaY, x: args.x, y: args.y)
            return try await C05DesktopToolSupport.postActionOutput(
                handle: handle,
                before: evidence,
                environment: environment,
                coordinator: environment.coordinator,
                details: ["deltaY": args.deltaY]
            )
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }
}

public struct C05DesktopDragTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var fromX: Int
        public var fromY: Int
        public var toX: Int
        public var toY: Int
        public var screenshotSHA256: String
        public var durationMilliseconds: Int?
    }
    public static var name: String { "\(P.wireName).drag" }
    public static var toolDescription: String {
        "Drag between two framebuffer pixels from the latest \(P.wireName).observe or action result. Returns a post-action PNG screenshot and reusable evidence; input dispatch is not proof that the intended item moved."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{"fromX":{"type":"integer","minimum":0},"fromY":{"type":"integer","minimum":0},"toX":{"type":"integer","minimum":0},"toY":{"type":"integer","minimum":0},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"durationMilliseconds":{"type":"integer","minimum":100,"maximum":3000}},"required":["fromX","fromY","toX","toY","screenshotSHA256"],"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI, .executesRemoteCommand] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] { C05DesktopObserveTool<P>.prerequisites }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard args.fromX >= 0, args.fromY >= 0, args.toX >= 0, args.toY >= 0 else {
            throw FloeError.validationFailed("drag coordinates must be non-negative")
        }
        guard (100...3_000).contains(args.durationMilliseconds ?? 500) else {
            throw FloeError.validationFailed("durationMilliseconds must be between 100 and 3000")
        }
        guard args.fromX != args.toX || args.fromY != args.toY else {
            throw FloeError.validationFailed("drag start and end must differ")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            let evidence = try await C05DesktopToolSupport.validatePoint(
                x: args.fromX,
                y: args.fromY,
                screenshotSHA256: args.screenshotSHA256,
                handle: handle,
                coordinator: environment.coordinator
            )
            _ = try await C05DesktopToolSupport.validatePoint(
                x: args.toX,
                y: args.toY,
                screenshotSHA256: args.screenshotSHA256,
                handle: handle,
                coordinator: environment.coordinator
            )
            try context.cancellation.throwIfCancelled()
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            guard evidence.revision == handle.screen.frameRevision else {
                throw C05RemoteDesktopToolError.invalidArgument(
                    "The remote screen changed before the drag; call \(P.wireName).observe again"
                )
            }
            let steps = 12
            let duration = args.durationMilliseconds ?? 500
            try handle.screen.pointerMove(x: args.fromX, y: args.fromY)
            try handle.screen.pointerButton(button: "left", down: true, x: args.fromX, y: args.fromY)
            var lastX = args.fromX
            var lastY = args.fromY
            do {
                for step in 1...steps {
                    try context.cancellation.throwIfCancelled()
                    let progress = Double(step) / Double(steps)
                    lastX = Int((Double(args.fromX) + Double(args.toX - args.fromX) * progress).rounded())
                    lastY = Int((Double(args.fromY) + Double(args.toY - args.fromY) * progress).rounded())
                    try handle.screen.pointerMove(x: lastX, y: lastY)
                    try await Task.sleep(nanoseconds: UInt64(max(1, duration / steps)) * 1_000_000)
                }
                try handle.screen.pointerButton(button: "left", down: false, x: lastX, y: lastY)
            } catch {
                try? handle.screen.pointerButton(button: "left", down: false, x: lastX, y: lastY)
                var fields = [
                    "status": "partialSuccess",
                    "sessionID": handle.sessionID.uuidString,
                    "inputDispatched": true,
                    "inputStatus": "partiallyQueued",
                    "retryInput": false,
                ] as [String: Any]
                fields["nextAction"] = "Input may already have executed. Do not replay it; obtain fresh \(P.wireName).observe evidence when the session is available."
                return try C05DesktopToolSupport.output(fields)
            }
            return try await C05DesktopToolSupport.postActionOutput(
                handle: handle,
                before: evidence,
                environment: environment,
                coordinator: environment.coordinator,
                details: [
                    "fromX": args.fromX, "fromY": args.fromY,
                    "toX": args.toX, "toY": args.toY,
                ]
            )
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }
}

public struct C05DesktopKeyPressTool<P: C05RemoteDesktopProtocolKind>: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var key: String
    }
    public static var name: String { "\(P.wireName).keyPress" }
    public static var toolDescription: String {
        "Press one named remote key such as Return, Tab, Escape, arrows, PageUp/PageDown, Home/End, Backspace, Delete, or F1-F12. Returns a post-action PNG screenshot for verification."
    }
    public static var parametersJSON: String { #"{"type":"object","properties":{"key":{"type":"string","enum":["Return","Tab","Escape","Space","Backspace","Delete","Left","Right","Up","Down","PageUp","PageDown","Home","End","Insert","F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"]}},"required":["key"],"additionalProperties":false}"# }
    public static var riskLabels: Set<RiskLabel> { [.controlsGUI, .executesRemoteCommand] }
    public static var isSideEffecting: Bool { true }
    public static var toolEffect: ToolEffect { .mutating }
    public static var requiresHostScope: Bool { false }
    public static var prerequisites: [ToolPrerequisite] { C05DesktopObserveTool<P>.prerequisites }

    private let environment: C05RemoteDesktopToolEnvironment
    public init(environment: C05RemoteDesktopToolEnvironment) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard Self.supportedKeys.contains(args.key.lowercased()) else {
            throw FloeError.validationFailed("Unsupported \(P.displayName) key: \(args.key)")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try C05DesktopToolSupport.requireApproval(context)
        let owner = try C05DesktopToolSupport.owner(context, environment: environment)
        do {
            let handle = try await environment.coordinator.requireHandle(
                protocolName: P.wireName,
                owner: owner
            )
            let before = await environment.coordinator.evidence(handle: handle).evidence
            try C05DesktopToolSupport.requireLiveHandle(
                handle,
                owner: owner,
                environment: environment
            )
            try handle.screen.key(named: args.key)
            return try await C05DesktopToolSupport.postActionOutput(
                handle: handle,
                before: before,
                environment: environment,
                coordinator: environment.coordinator,
                details: ["key": args.key]
            )
        } catch {
            throw C05DesktopToolSupport.fail(error)
        }
    }

    private static var supportedKeys: Set<String> {
        [
            "return", "tab", "escape", "space", "backspace", "delete", "left", "right", "up", "down",
            "pageup", "pagedown", "home", "end", "insert", "f1", "f2", "f3", "f4", "f5", "f6", "f7",
            "f8", "f9", "f10", "f11", "f12",
        ]
    }
}

// MARK: - Registration

public enum C05RemoteDesktopToolNames {
    public static let vnc: [String] = [
        "vnc.status", "vnc.connect", "vnc.reconnect", "vnc.disconnect", "vnc.observe",
        "vnc.clickElement", "vnc.click", "vnc.typeText", "vnc.typeCredential",
        "vnc.scroll", "vnc.drag", "vnc.keyPress",
    ]
    public static let rdp: [String] = [
        "rdp.status", "rdp.connect", "rdp.reconnect", "rdp.disconnect", "rdp.observe",
        "rdp.clickElement", "rdp.click", "rdp.typeText", "rdp.typeCredential",
        "rdp.scroll", "rdp.drag", "rdp.keyPress",
    ]
    public static var all: [String] { vnc + rdp }
}

public func registerC05RemoteDesktopTools(
    environment: C05RemoteDesktopToolEnvironment = .production,
    registry: ToolRunnerRegistry = .shared
) {
    func add<T: AgentTool>(
        _ type: T.Type,
        _ tool: T,
        requiresArtifacts: Bool = false,
        requiresRecognizer: Bool = false,
        requiresCredentialResolver: Bool = false
    ) {
        ToolCatalog.register(type)
        registry.register(AnyAgentTool(tool).withAvailability {
            guard environment.isAvailable else { return false }
            if requiresArtifacts, !environment.hasArtifactRoot { return false }
            if requiresRecognizer, !environment.hasTextRecognizer { return false }
            if requiresCredentialResolver, !environment.hasCredentialResolver { return false }
            return true
        })
    }

    add(C05DesktopStatusTool<C05VNCProtocolKind>.self,
        C05DesktopStatusTool<C05VNCProtocolKind>(environment: environment))
    add(C05DesktopConnectTool<C05VNCProtocolKind>.self,
        C05DesktopConnectTool<C05VNCProtocolKind>(environment: environment))
    add(C05DesktopReconnectTool<C05VNCProtocolKind>.self,
        C05DesktopReconnectTool<C05VNCProtocolKind>(environment: environment))
    add(C05DesktopDisconnectTool<C05VNCProtocolKind>.self,
        C05DesktopDisconnectTool<C05VNCProtocolKind>(environment: environment))
    add(C05DesktopObserveTool<C05VNCProtocolKind>.self,
        C05DesktopObserveTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopClickElementTool<C05VNCProtocolKind>.self,
        C05DesktopClickElementTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true, requiresRecognizer: true)
    add(C05DesktopClickTool<C05VNCProtocolKind>.self,
        C05DesktopClickTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopTypeTextTool<C05VNCProtocolKind>.self,
        C05DesktopTypeTextTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopTypeCredentialTool<C05VNCProtocolKind>.self,
        C05DesktopTypeCredentialTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true, requiresCredentialResolver: true)
    add(C05DesktopScrollTool<C05VNCProtocolKind>.self,
        C05DesktopScrollTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopDragTool<C05VNCProtocolKind>.self,
        C05DesktopDragTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopKeyPressTool<C05VNCProtocolKind>.self,
        C05DesktopKeyPressTool<C05VNCProtocolKind>(environment: environment),
        requiresArtifacts: true)

    add(C05DesktopStatusTool<C05RDPProtocolKind>.self,
        C05DesktopStatusTool<C05RDPProtocolKind>(environment: environment))
    add(C05DesktopConnectTool<C05RDPProtocolKind>.self,
        C05DesktopConnectTool<C05RDPProtocolKind>(environment: environment))
    add(C05DesktopReconnectTool<C05RDPProtocolKind>.self,
        C05DesktopReconnectTool<C05RDPProtocolKind>(environment: environment))
    add(C05DesktopDisconnectTool<C05RDPProtocolKind>.self,
        C05DesktopDisconnectTool<C05RDPProtocolKind>(environment: environment))
    add(C05DesktopObserveTool<C05RDPProtocolKind>.self,
        C05DesktopObserveTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopClickElementTool<C05RDPProtocolKind>.self,
        C05DesktopClickElementTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true, requiresRecognizer: true)
    add(C05DesktopClickTool<C05RDPProtocolKind>.self,
        C05DesktopClickTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopTypeTextTool<C05RDPProtocolKind>.self,
        C05DesktopTypeTextTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopTypeCredentialTool<C05RDPProtocolKind>.self,
        C05DesktopTypeCredentialTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true, requiresCredentialResolver: true)
    add(C05DesktopScrollTool<C05RDPProtocolKind>.self,
        C05DesktopScrollTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopDragTool<C05RDPProtocolKind>.self,
        C05DesktopDragTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true)
    add(C05DesktopKeyPressTool<C05RDPProtocolKind>.self,
        C05DesktopKeyPressTool<C05RDPProtocolKind>(environment: environment),
        requiresArtifacts: true)
}

public func unregisterC05RemoteDesktopTools(registry: ToolRunnerRegistry = .shared) {
    registry.unregister { C05RemoteDesktopToolNames.all.contains($0) }
}
