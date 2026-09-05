// FloeVNC — evidence-backed visual automation tools.
//
// RFB exposes pixels and input events, not an accessibility/DOM tree. Every
// coordinate action binds to a fresh screenshot digest and returns a
// post-action screenshot. Dispatching input is never called visual success.

import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools

public struct VNCSessionHandle: @unchecked Sendable {
    public let id: UUID
    public let session: VNCSession

    public init(id: UUID, session: VNCSession) {
        self.id = id
        self.session = session
    }
}

public typealias VNCSessionProvider = @Sendable () async throws -> VNCSessionHandle?
public typealias VNCCredentialResolver = @Sendable (UUID) async throws -> Data
public typealias VNCStatusProvider = @Sendable () async -> VNCToolConnectionStatus
public typealias VNCConnectAction = @Sendable () async throws -> VNCSessionHandle?
public typealias VNCReconnectAction = @Sendable () async throws -> VNCSessionHandle?
public typealias VNCDisconnectAction = @Sendable () async -> VNCToolConnectionStatus

/// Secret-free connection state shared by the model tools and the UI session
/// coordinator. A status read never opens a socket; connect/reconnect are
/// separate explicit operations so the model can reason about failures.
public struct VNCToolConnectionStatus: Sendable, Codable, Hashable {
    public enum State: String, Sendable, Codable, Hashable {
        case unconfigured, disconnected, connecting, connected, failed
    }

    public var state: State
    public var configuredEndpointCount: Int
    public var sessionID: UUID?
    public var target: String?
    public var toolManaged: Bool
    public var idleTimeoutSeconds: Int?
    public var failure: VNCConnectionFailure?

    public init(
        state: State,
        configuredEndpointCount: Int,
        sessionID: UUID? = nil,
        target: String? = nil,
        toolManaged: Bool = false,
        idleTimeoutSeconds: Int? = nil,
        failure: VNCConnectionFailure? = nil
    ) {
        self.state = state
        self.configuredEndpointCount = configuredEndpointCount
        self.sessionID = sessionID
        self.target = target
        self.toolManaged = toolManaged
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.failure = failure
    }
}

private struct VNCCapturedArtifact {
    let capture: VNCFrameCapture
    let reference: ToolArtifactReference
}

enum VNCToolSupport {
    static func statusOutput(_ status: VNCToolConnectionStatus) throws -> ToolExecutionOutput {
        var payload: [String: Any] = [
            "status": "ok",
            "connectionState": status.state.rawValue,
            "configuredEndpointCount": status.configuredEndpointCount,
            "sessionID": status.sessionID?.uuidString ?? NSNull(),
            "target": status.target ?? NSNull(),
            "toolManaged": status.toolManaged,
            "idleTimeoutSeconds": status.idleTimeoutSeconds ?? NSNull(),
            "failure": NSNull()
        ]
        if let failure = status.failure {
            payload["failure"] = [
                "category": failure.category.rawValue,
                "stage": failure.stage.rawValue,
                "retryable": failure.retryable,
                "reason": failure.message,
                "underlyingCode": failure.underlyingCode ?? NSNull()
            ] as [String: Any]
        }
        return try output(payload)
    }

    static func connectedSession(from provider: VNCSessionProvider) async throws -> VNCSessionHandle {
        let handle: VNCSessionHandle?
        do {
            handle = try await provider()
        } catch let failure as VNCConnectionFailure {
            throw FloeError.validationFailed(failure.toolSummary)
        }
        guard let handle else {
            throw FloeError.validationFailed(
                #"{"category":"configurationMissing","reason":"No VNC endpoint is available to the agent.","retryable":false,"stage":"configuration","status":"connectionFailed"}"#
            )
        }
        guard handle.session.isConnected else {
            if case .failed(let failure) = handle.session.currentState {
                throw FloeError.validationFailed(failure.toolSummary)
            }
            throw FloeError.validationFailed(
                #"{"category":"handshakeFailed","reason":"The VNC session exists but is not connected.","retryable":true,"stage":"handshake","status":"connectionFailed"}"#
            )
        }
        return handle
    }

    private static func capture(_ handle: VNCSessionHandle) throws -> VNCCapturedArtifact {
        let capture = try handle.session.captureJPEG()
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("VNCArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanup(directory: directory)
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        try capture.data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        let reference = ToolArtifactReference(
            id: id,
            relativePath: "VNCArtifacts/\(filename)",
            mimeType: "image/jpeg",
            byteCount: capture.data.count,
            sha256: capture.sha256
        )
        handle.session.rememberVisualEvidence(VNCVisualEvidence(capture: capture))
        return VNCCapturedArtifact(capture: capture, reference: reference)
    }

    static func recognizeText(in capture: VNCFrameCapture) throws -> [VisualTextRegion] {
        try VisualTextRecognizer.recognize(
            imageData: capture.data,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight
        )
    }

    static func structuredJSON(_ elements: [VisualTextRegion]) -> [[String: Any]] {
        elements.map { element in
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
                "centerY": element.centerY
            ]
        }
    }

    static func validatePoint(
        x: Int,
        y: Int,
        screenshotSHA256: String,
        session: VNCSession
    ) throws -> VNCVisualEvidence {
        guard screenshotSHA256.count == 64,
              screenshotSHA256.allSatisfy(\.isHexDigit),
              let evidence = session.currentVisualEvidence,
              evidence.sha256.caseInsensitiveCompare(screenshotSHA256) == .orderedSame else {
            throw FloeError.validationFailed(
                "Call vnc.observe first and pass its fresh screenshotSHA256"
            )
        }
        guard Date().timeIntervalSince(evidence.capturedAt) <= 15 else {
            throw FloeError.validationFailed("VNC screenshot evidence expired; call vnc.observe again")
        }
        guard evidence.revision == session.currentFrameRevision else {
            throw FloeError.validationFailed(
                "The remote screen changed after the screenshot; call vnc.observe again"
            )
        }
        guard x >= 0, y >= 0, x < evidence.pixelWidth, y < evidence.pixelHeight else {
            throw FloeError.validationFailed(
                "Point (\(x),\(y)) is outside screenshot bounds \(evidence.pixelWidth)x\(evidence.pixelHeight)"
            )
        }
        return evidence
    }

    private static func postActionCapture(
        _ handle: VNCSessionHandle,
        before: VNCVisualEvidence?,
        timeout: Duration = .milliseconds(1_500)
    ) async throws -> (artifact: VNCCapturedArtifact, changed: Bool) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastRevision = handle.session.currentFrameRevision
        var stableSince = clock.now
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let revision = handle.session.currentFrameRevision
            if revision != lastRevision {
                lastRevision = revision
                stableSince = clock.now
            }
            if revision != before?.revision,
               stableSince.duration(to: clock.now) >= .milliseconds(250) { break }
        }
        let artifact = try capture(handle)
        return (artifact, artifact.capture.sha256 != before?.sha256)
    }

    /// Once input has been queued, observation failure must not turn the
    /// mutation into a retryable failure. RFB provides no input acknowledgement.
    static func postActionOutput(
        _ handle: VNCSessionHandle,
        before: VNCVisualEvidence?,
        details: [String: Any] = [:]
    ) async throws -> ToolExecutionOutput {
        var fields = details
        fields["sessionID"] = handle.id.uuidString
        fields["inputDispatched"] = true
        fields["inputStatus"] = "queued"
        fields["serverAcknowledged"] = false
        fields["taskSuccessVerified"] = false
        do {
            let post = try await postActionCapture(handle, before: before)
            let observation = await observationFields(handle, artifact: post.artifact)
            fields.merge(observation) { _, new in new }
            fields["status"] = "ok"
            fields["frameChanged"] = post.changed
            fields["frameUpdateReceived"] = post.artifact.capture.revision != before?.revision
            fields["observationStatus"] = post.artifact.capture.revision == before?.revision
                ? "noNewFrame" : (post.changed ? "changed" : "unchanged")
            fields["postScreenshotSHA256"] = post.artifact.capture.sha256
            fields["postScreenshotPath"] = post.artifact.reference.relativePath
            fields["postRevision"] = post.artifact.capture.revision
            fields["nextAction"] = observation["evidenceStatus"] as? String == "current"
                ? "Use this result's screenshotSHA256 and elements directly; observe again only if evidence is stale or no new frame arrived."
                : "The screen changed during observation. Do not replay the input; obtain fresh vnc.observe evidence before another coordinate action."
            return try output(fields, artifacts: [post.artifact.reference])
        } catch {
            fields.merge(partialObservationFields(cancelled: error is CancellationError)) { _, new in new }
            return try output(fields)
        }
    }

    static func partialObservationFields(cancelled: Bool) -> [String: Any] {
        ["status": "partialSuccess", "observationStatus": cancelled ? "cancelled" : "unavailable",
         "retryInput": false,
         "nextAction": "Input may already have executed. Do not replay it; obtain fresh vnc.observe evidence when the session is available."]
    }

    static func clickOutput(
        _ handle: VNCSessionHandle, before: VNCVisualEvidence,
        x: Int, y: Int, count: Int, context: ToolContext,
        details: [String: Any] = [:]
    ) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        var queued = 0
        do {
            for index in 0..<count {
                try context.cancellation.throwIfCancelled()
                handle.session.mouseMove(x: UInt16(x), y: UInt16(y))
                handle.session.mouseDown(x: UInt16(x), y: UInt16(y))
                handle.session.mouseUp(x: UInt16(x), y: UInt16(y))
                queued += 1
                if index + 1 < count { try await Task.sleep(for: .milliseconds(100)) }
            }
        } catch {
            guard queued > 0 else { throw error }
            var fields = partialObservationFields(cancelled: true)
            fields["sessionID"] = handle.id.uuidString
            fields["inputDispatched"] = true
            fields["inputStatus"] = "partiallyQueued"
            fields["clicksQueued"] = queued
            fields["serverAcknowledged"] = false
            return try output(fields)
        }
        var fields = details
        fields["x"] = x; fields["y"] = y; fields["clickCount"] = count
        return try await postActionOutput(handle, before: before, details: fields)
    }

    private static func observationFields(
        _ handle: VNCSessionHandle, artifact: VNCCapturedArtifact
    ) async -> [String: Any] {
        let capture = artifact.capture
        let recognition = await BoundedVisualTextRecognizer.shared.recognize {
            try recognizeText(in: capture)
        }
        let elements = recognition.elements
        let isCurrent = handle.session.currentFrameRevision == capture.revision
            && handle.session.currentVisualEvidence?.sha256 == capture.sha256
        if isCurrent {
            handle.session.rememberStructuredEvidence(VNCStructuredEvidence(
                screenshotSHA256: artifact.capture.sha256, revision: artifact.capture.revision,
                capturedAt: artifact.capture.capturedAt, elements: elements
            ))
        }
        return [
            "pixelWidth": artifact.capture.pixelWidth, "pixelHeight": artifact.capture.pixelHeight,
            "revision": artifact.capture.revision, "screenshotSHA256": artifact.capture.sha256,
            "screenshotPath": artifact.reference.relativePath,
            "capturedAt": artifact.capture.capturedAt.ISO8601Format(),
            "coordinateSpace": "framebufferPixels", "structureSource": "onDeviceOCR",
            "evidenceStatus": isCurrent ? "current" : "stale",
            "structureStatus": recognition.status.rawValue,
            "structuredElementCount": elements.count,
            "elements": structuredJSON(elements)
        ]
    }

    static func observeOutput(_ handle: VNCSessionHandle) async throws -> ToolExecutionOutput {
        let artifact = try capture(handle)
        var fields = await observationFields(handle, artifact: artifact)
        fields["status"] = "ok"
        fields["sessionID"] = handle.id.uuidString
        return try output(fields, artifacts: [artifact.reference])
    }

    static func output(
        _ fields: [String: Any],
        artifacts: [ToolArtifactReference] = []
    ) throws -> ToolExecutionOutput {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: digest,
            exitStatus: 0,
            artifacts: artifacts
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

public struct VNCStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "vnc.status"
    public static let toolDescription =
        "Read the current VNC connection state without opening a connection. Returns configured endpoint count, active session, idle policy, and the latest structured failure when available."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    private let statusProvider: VNCStatusProvider

    public init(statusProvider: @escaping VNCStatusProvider) { self.statusProvider = statusProvider }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return try VNCToolSupport.statusOutput(await statusProvider())
    }
}

public struct VNCConnectTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "vnc.connect"
    public static let toolDescription =
        "Connect the single configured or previously selected VNC endpoint and keep the tool-managed session alive for the idle grace period. Use vnc.status first when the connection is ambiguous."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .accessesCredentials]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let connection: VNCConnectAction
    private let statusProvider: VNCStatusProvider

    public init(connection: @escaping VNCConnectAction, statusProvider: @escaping VNCStatusProvider) {
        self.connection = connection
        self.statusProvider = statusProvider
    }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        _ = try await connection()
        return try VNCToolSupport.statusOutput(await statusProvider())
    }
}

public struct VNCReconnectTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "vnc.reconnect"
    public static let toolDescription =
        "Discard a stale tool-managed VNC session and perform a fresh handshake. A non-retryable authentication failure remains blocked until the saved credential or endpoint is updated."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .accessesCredentials]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let reconnect: VNCReconnectAction
    private let statusProvider: VNCStatusProvider

    public init(reconnect: @escaping VNCReconnectAction, statusProvider: @escaping VNCStatusProvider) {
        self.reconnect = reconnect
        self.statusProvider = statusProvider
    }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        _ = try await reconnect()
        return try VNCToolSupport.statusOutput(await statusProvider())
    }
}

public struct VNCDisconnectTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "vnc.disconnect"
    public static let toolDescription =
        "Close tool-managed VNC sessions. User-opened viewer sessions are left alone. Returns the resulting connection state."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let disconnect: VNCDisconnectAction

    public init(disconnect: @escaping VNCDisconnectAction) { self.disconnect = disconnect }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return try VNCToolSupport.statusOutput(await disconnect())
    }
}

public struct VNCObserveTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "vnc.observe"
    public static let toolDescription =
        "Capture the connected VNC framebuffer before actions. Returns exact pixel bounds, screenshotSHA256, a verified image artifact, and OCR-backed recognizedText elements with references and bounds. Prefer references when present. RFB has no native DOM/accessibility tree, so never invent controls or roles."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false
    public static let prerequisites = [ToolPrerequisite(
        state: "vnc.connected",
        resolverToolName: VNCConnectTool.name,
        mayResolveAutomatically: true
    )]
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        return try await VNCToolSupport.observeOutput(handle)
    }
}

public struct VNCClickElementTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var reference: String
        public var screenshotSHA256: String
        public var clickCount: Int?

        public init(reference: String, screenshotSHA256: String, clickCount: Int? = nil) {
            self.reference = reference
            self.screenshotSHA256 = screenshotSHA256
            self.clickCount = clickCount
        }
    }
    public static let name = "vnc.clickElement"
    public static let toolDescription =
        "Click the center of an OCR-backed recognizedText reference from the latest VNC observation or action result. This is a visual text anchor, not a native accessibility control. Returns a post-action screenshot, OCR elements and reusable screenshotSHA256; do not routinely observe again."
    public static let parametersJSON = #"{"type":"object","properties":{"reference":{"type":"string","pattern":"^text-[1-9][0-9]*$"},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"clickCount":{"type":"integer","minimum":1,"maximum":2}},"required":["reference","screenshotSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    public static let prerequisites = VNCObserveTool.prerequisites
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
    public func validate(_ args: Arguments) throws {
        guard args.reference.range(of: #"^text-[1-9][0-9]*$"#, options: .regularExpression) != nil,
              (1...2).contains(args.clickCount ?? 1) else {
            throw FloeError.validationFailed("reference must be text-N and clickCount must be 1 or 2")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        guard let structure = handle.session.currentStructuredEvidence,
              structure.screenshotSHA256.caseInsensitiveCompare(args.screenshotSHA256) == .orderedSame,
              structure.revision == handle.session.currentFrameRevision,
              Date().timeIntervalSince(structure.capturedAt) <= 15,
              let element = structure.elements.first(where: { $0.reference == args.reference }) else {
            throw FloeError.validationFailed(
                "Structured VNC evidence is missing, changed, or expired; call vnc.observe again"
            )
        }
        let evidence = try VNCToolSupport.validatePoint(
            x: element.centerX,
            y: element.centerY,
            screenshotSHA256: args.screenshotSHA256,
            session: handle.session
        )
        return try await VNCToolSupport.clickOutput(handle, before: evidence,
            x: element.centerX, y: element.centerY, count: args.clickCount ?? 1, context: context, details: [
            "reference": element.reference,
            "recognizedText": element.text,
            "x": element.centerX,
            "y": element.centerY,
            "clickCount": args.clickCount ?? 1
        ])
    }
}

public struct VNCClickTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var x: Int
        public var y: Int
        public var screenshotSHA256: String
        public var clickCount: Int?

        public init(x: Int, y: Int, screenshotSHA256: String, clickCount: Int? = nil) {
            self.x = x
            self.y = y
            self.screenshotSHA256 = screenshotSHA256
            self.clickCount = clickCount
        }
    }
    public static let name = "vnc.click"
    public static let toolDescription =
        "Click a framebuffer pixel from the latest VNC observation or action result. Pass its exact screenshotSHA256. Returns a post-action screenshot, OCR elements and reusable screenshotSHA256, plus separate inputDispatched/frameChanged fields; frameChanged alone is not proof of task success. Do not routinely observe again."
    public static let parametersJSON = #"{"type":"object","properties":{"x":{"type":"integer","minimum":0},"y":{"type":"integer","minimum":0},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"clickCount":{"type":"integer","minimum":1,"maximum":2}},"required":["x","y","screenshotSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    public static let prerequisites = VNCObserveTool.prerequisites
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
    public func validate(_ args: Arguments) throws {
        guard args.x >= 0, args.y >= 0, (1...2).contains(args.clickCount ?? 1) else {
            throw FloeError.validationFailed(
                "coordinates must be non-negative and clickCount must be 1 or 2"
            )
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        let evidence = try VNCToolSupport.validatePoint(
            x: args.x,
            y: args.y,
            screenshotSHA256: args.screenshotSHA256,
            session: handle.session
        )
        return try await VNCToolSupport.clickOutput(handle, before: evidence,
            x: args.x, y: args.y, count: args.clickCount ?? 1, context: context)
    }
}

public struct VNCTypeTextTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var text: String
        public var submit: Bool?
        public init(text: String, submit: Bool? = nil) { self.text = text; self.submit = submit }
    }
    public static let name = "vnc.typeText"
    public static let toolDescription =
        "Type bounded text into the current VNC focus and optionally press Return. Returns a post-action screenshot; verify visually that the focused field accepted the text."
    public static let parametersJSON = #"{"type":"object","properties":{"text":{"type":"string","maxLength":4096},"submit":{"type":"boolean"}},"required":["text"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand, .sendsDataToProvider]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    public static let prerequisites = VNCObserveTool.prerequisites
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
    public func validate(_ args: Arguments) throws {
        guard !args.text.isEmpty, args.text.utf8.count <= VNCAction.typeTextMaxBytes else {
            throw FloeError.validationFailed("text must be 1-4096 UTF-8 bytes")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        let before = handle.session.currentVisualEvidence
        handle.session.send(text: args.text)
        if args.submit == true { handle.session.send(.return) }
        return try await VNCToolSupport.postActionOutput(handle, before: before, details: [
            "characterCount": args.text.count,
            "submitted": args.submit == true
        ])
    }
}

/// Types a saved credential without ever placing its plaintext in provider
/// arguments, approvals, audit events, checkpoints, or tool output.
public struct VNCTypeCredentialTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var credentialRef: String
        public var submit: Bool?
        public init(credentialRef: String, submit: Bool? = nil) {
            self.credentialRef = credentialRef
            self.submit = submit
        }
    }

    public static let name = "vnc.typeCredential"
    public static let toolDescription =
        "Type a previously saved Floe secure credential card into the current VNC focus. Pass credentialRef exactly as shown in context; plaintext is resolved only inside the approved executor and is never returned."
    public static let parametersJSON = #"{"type":"object","properties":{"credentialRef":{"type":"string","pattern":"^⟨credential:[0-9A-Fa-f-]{36}⟩$"},"submit":{"type":"boolean"}},"required":["credentialRef"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [
        .controlsGUI, .executesRemoteCommand, .sendsDataToProvider, .accessesCredentials
    ]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    public static let prerequisites = VNCObserveTool.prerequisites

    private let sessionProvider: VNCSessionProvider
    private let credentialResolver: VNCCredentialResolver

    public init(
        sessionProvider: @escaping VNCSessionProvider,
        credentialResolver: @escaping VNCCredentialResolver
    ) {
        self.sessionProvider = sessionProvider
        self.credentialResolver = credentialResolver
    }

    public func validate(_ args: Arguments) throws {
        guard SecretIngressScanner.credentialID(from: args.credentialRef) != nil else {
            throw FloeError.validationFailed("credentialRef must reference a Floe secure credential card")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let credentialID = SecretIngressScanner.credentialID(from: args.credentialRef) else {
            throw FloeError.validationFailed("credentialRef must reference a Floe secure credential card")
        }
        var bytes = try await credentialResolver(credentialID)
        defer { bytes.resetBytes(in: bytes.indices) }
        guard !bytes.isEmpty, bytes.count <= 4_096,
              let text = String(data: bytes, encoding: .utf8) else {
            throw FloeError.validationFailed("Saved credential is empty, too large, or not UTF-8 text")
        }
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        handle.session.send(text: text)
        if args.submit == true { handle.session.send(.return) }
        // Credential text may be visible in an arbitrary focus target. Do not
        // automatically persist or expose an unredacted post-input screenshot.
        return try VNCToolSupport.output([
            "status": "ok", "sessionID": handle.id.uuidString,
            "credentialDispatched": true, "inputStatus": "queued",
            "serverAcknowledged": false, "submitted": args.submit == true,
            "observationStatus": "suppressedForCredentialPrivacy",
            "nextAction": "Verify the remote focus safely before requesting new visual evidence. Do not replay credential input."
        ])
    }
}

public struct VNCScrollTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var x: Int
        public var y: Int
        public var deltaY: Int
        public var screenshotSHA256: String
    }
    public static let name = "vnc.scroll"
    public static let toolDescription =
        "Scroll at a point from the latest vnc.observe screenshot. Positive deltaY scrolls up; negative scrolls down. Returns a post-action screenshot."
    public static let parametersJSON = #"{"type":"object","properties":{"x":{"type":"integer","minimum":0},"y":{"type":"integer","minimum":0},"deltaY":{"type":"integer","minimum":-20,"maximum":20},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"}},"required":["x","y","deltaY","screenshotSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    public static let prerequisites = VNCObserveTool.prerequisites
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
    public func validate(_ args: Arguments) throws {
        guard args.deltaY != 0, (-20...20).contains(args.deltaY) else {
            throw FloeError.validationFailed("deltaY must be between -20 and 20 and non-zero")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        let evidence = try VNCToolSupport.validatePoint(
            x: args.x,
            y: args.y,
            screenshotSHA256: args.screenshotSHA256,
            session: handle.session
        )
        handle.session.scroll(
            up: args.deltaY > 0,
            x: UInt16(args.x),
            y: UInt16(args.y),
            steps: UInt32(abs(args.deltaY))
        )
        return try await VNCToolSupport.postActionOutput(handle, before: evidence, details: [
            "deltaY": args.deltaY
        ])
    }
}

public struct VNCDragTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var fromX: Int
        public var fromY: Int
        public var toX: Int
        public var toY: Int
        public var screenshotSHA256: String
        public var durationMilliseconds: Int?

        public init(
            fromX: Int,
            fromY: Int,
            toX: Int,
            toY: Int,
            screenshotSHA256: String,
            durationMilliseconds: Int? = nil
        ) {
            self.fromX = fromX
            self.fromY = fromY
            self.toX = toX
            self.toY = toY
            self.screenshotSHA256 = screenshotSHA256
            self.durationMilliseconds = durationMilliseconds
        }
    }
    public static let name = "vnc.drag"
    public static let toolDescription =
        "Drag between two framebuffer pixels from the latest VNC observation or action result. Returns a post-action screenshot, OCR elements and reusable screenshotSHA256; do not routinely observe again. Input dispatch is not proof that the intended item moved."
    public static let parametersJSON = #"{"type":"object","properties":{"fromX":{"type":"integer","minimum":0},"fromY":{"type":"integer","minimum":0},"toX":{"type":"integer","minimum":0},"toY":{"type":"integer","minimum":0},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"durationMilliseconds":{"type":"integer","minimum":100,"maximum":3000}},"required":["fromX","fromY","toX","toY","screenshotSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    public static let prerequisites = VNCObserveTool.prerequisites
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
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
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        let evidence = try VNCToolSupport.validatePoint(
            x: args.fromX,
            y: args.fromY,
            screenshotSHA256: args.screenshotSHA256,
            session: handle.session
        )
        _ = try VNCToolSupport.validatePoint(
            x: args.toX,
            y: args.toY,
            screenshotSHA256: args.screenshotSHA256,
            session: handle.session
        )
        let steps = 12
        let duration = args.durationMilliseconds ?? 500
        handle.session.mouseMove(x: UInt16(args.fromX), y: UInt16(args.fromY))
        handle.session.mouseDown(x: UInt16(args.fromX), y: UInt16(args.fromY))
        var lastX = UInt16(args.fromX)
        var lastY = UInt16(args.fromY)
        do {
            defer { handle.session.mouseUp(x: lastX, y: lastY) }
            for step in 1...steps {
                try context.cancellation.throwIfCancelled()
                let progress = Double(step) / Double(steps)
                lastX = UInt16((Double(args.fromX) + Double(args.toX - args.fromX) * progress).rounded())
                lastY = UInt16((Double(args.fromY) + Double(args.toY - args.fromY) * progress).rounded())
                handle.session.mouseMove(x: lastX, y: lastY)
                try await Task.sleep(for: .milliseconds(duration / steps))
            }
        } catch {
            var fields = VNCToolSupport.partialObservationFields(cancelled: true)
            fields["sessionID"] = handle.id.uuidString
            fields["inputDispatched"] = true
            fields["inputStatus"] = "partiallyQueued"
            fields["releaseQueued"] = true
            return try VNCToolSupport.output(fields)
        }
        return try await VNCToolSupport.postActionOutput(handle, before: evidence, details: [
            "fromX": args.fromX,
            "fromY": args.fromY,
            "toX": args.toX,
            "toY": args.toY
        ])
    }
}

public struct VNCKeyPressTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var key: String
        public init(key: String) { self.key = key }
    }
    public static let name = "vnc.keyPress"
    public static let toolDescription =
        "Press one named remote key such as Return, Tab, Escape, arrows, PageUp/PageDown, Home/End, Backspace, Delete, or F1-F12. Returns a post-action screenshot for verification."
    public static let parametersJSON = #"{"type":"object","properties":{"key":{"type":"string","enum":["Return","Tab","Escape","Space","Backspace","Delete","Left","Right","Up","Down","PageUp","PageDown","Home","End","Insert","F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"]}},"required":["key"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    public static let prerequisites = VNCObserveTool.prerequisites
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
    public func validate(_ args: Arguments) throws {
        guard Self.supportedKeys.contains(args.key.lowercased()) else {
            throw FloeError.validationFailed("Unsupported VNC key: \(args.key)")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        let before = handle.session.currentVisualEvidence
        try handle.session.send(namedKey: args.key)
        return try await VNCToolSupport.postActionOutput(handle, before: before, details: [
            "key": args.key
        ])
    }

    private static let supportedKeys: Set<String> = [
        "return", "tab", "escape", "space", "backspace", "delete", "left", "right", "up", "down",
        "pageup", "pagedown", "home", "end", "insert", "f1", "f2", "f3", "f4", "f5", "f6", "f7",
        "f8", "f9", "f10", "f11", "f12"
    ]
}

@discardableResult
public func registerVNCTools(
    registry: ToolRunnerRegistry = .shared,
    credentialResolver: @escaping VNCCredentialResolver = { _ in
        throw FloeError.invalidConfiguration("Credential resolver is unavailable")
    },
    statusProvider: @escaping VNCStatusProvider = {
        VNCToolConnectionStatus(state: .unconfigured, configuredEndpointCount: 0)
    },
    connect: @escaping VNCConnectAction,
    reconnect: VNCReconnectAction? = nil,
    disconnect: VNCDisconnectAction? = nil,
    sessionProvider: @escaping VNCSessionProvider
) -> VNCSessionProvider {
    ToolCatalog.register(VNCStatusTool.self)
    ToolCatalog.register(VNCConnectTool.self)
    ToolCatalog.register(VNCReconnectTool.self)
    ToolCatalog.register(VNCDisconnectTool.self)
    ToolCatalog.register(VNCObserveTool.self)
    ToolCatalog.register(VNCClickElementTool.self)
    ToolCatalog.register(VNCClickTool.self)
    ToolCatalog.register(VNCTypeTextTool.self)
    ToolCatalog.register(VNCTypeCredentialTool.self)
    ToolCatalog.register(VNCScrollTool.self)
    ToolCatalog.register(VNCDragTool.self)
    ToolCatalog.register(VNCKeyPressTool.self)
    registry.register(VNCStatusTool(statusProvider: statusProvider))
    registry.register(VNCConnectTool(connection: connect, statusProvider: statusProvider))
    registry.register(VNCReconnectTool(
        reconnect: reconnect ?? sessionProvider,
        statusProvider: statusProvider
    ))
    registry.register(VNCDisconnectTool(disconnect: disconnect ?? { await statusProvider() }))
    registry.register(VNCObserveTool(sessionProvider: sessionProvider))
    registry.register(VNCClickElementTool(sessionProvider: sessionProvider))
    registry.register(VNCClickTool(sessionProvider: sessionProvider))
    registry.register(VNCTypeTextTool(sessionProvider: sessionProvider))
    registry.register(VNCTypeCredentialTool(
        sessionProvider: sessionProvider,
        credentialResolver: credentialResolver
    ))
    registry.register(VNCScrollTool(sessionProvider: sessionProvider))
    registry.register(VNCDragTool(sessionProvider: sessionProvider))
    registry.register(VNCKeyPressTool(sessionProvider: sessionProvider))
    return sessionProvider
}
