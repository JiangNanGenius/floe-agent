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

private struct VNCCapturedArtifact {
    let capture: VNCFrameCapture
    let reference: ToolArtifactReference
}

private enum VNCToolSupport {
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

    static func capture(_ handle: VNCSessionHandle) throws -> VNCCapturedArtifact {
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

    static func postActionCapture(
        _ handle: VNCSessionHandle,
        before: VNCVisualEvidence?,
        timeout: Duration = .milliseconds(1_500)
    ) async throws -> (artifact: VNCCapturedArtifact, changed: Bool) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline,
              handle.session.currentFrameRevision == before?.revision {
            try await Task.sleep(for: .milliseconds(100))
        }
        let artifact = try capture(handle)
        return (artifact, artifact.capture.sha256 != before?.sha256)
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
    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) { self.sessionProvider = sessionProvider }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let handle = try await VNCToolSupport.connectedSession(from: sessionProvider)
        let artifact = try VNCToolSupport.capture(handle)
        let elements = try VNCToolSupport.recognizeText(in: artifact.capture)
        handle.session.rememberStructuredEvidence(VNCStructuredEvidence(
            screenshotSHA256: artifact.capture.sha256,
            revision: artifact.capture.revision,
            capturedAt: artifact.capture.capturedAt,
            elements: elements
        ))
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "pixelWidth": artifact.capture.pixelWidth,
            "pixelHeight": artifact.capture.pixelHeight,
            "revision": artifact.capture.revision,
            "screenshotSHA256": artifact.capture.sha256,
            "screenshotPath": artifact.reference.relativePath,
            "coordinateSpace": "framebufferPixels",
            "structureSource": "onDeviceOCR",
            "structuredElementCount": elements.count,
            "elements": VNCToolSupport.structuredJSON(elements)
        ], artifacts: [artifact.reference])
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
        "Click the center of an OCR-backed recognizedText reference returned by the latest vnc.observe. This is a visual text anchor, not a claimed native accessibility control. Returns a post-action screenshot for verification."
    public static let parametersJSON = #"{"type":"object","properties":{"reference":{"type":"string","pattern":"^text-[1-9][0-9]*$"},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"clickCount":{"type":"integer","minimum":1,"maximum":2}},"required":["reference","screenshotSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
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
        for index in 0..<(args.clickCount ?? 1) {
            let x = UInt16(element.centerX)
            let y = UInt16(element.centerY)
            handle.session.mouseMove(x: x, y: y)
            handle.session.mouseDown(x: x, y: y)
            handle.session.mouseUp(x: x, y: y)
            if index == 0, args.clickCount == 2 { try await Task.sleep(for: .milliseconds(100)) }
        }
        let post = try await VNCToolSupport.postActionCapture(handle, before: evidence)
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "inputDispatched": true,
            "reference": element.reference,
            "recognizedText": element.text,
            "x": element.centerX,
            "y": element.centerY,
            "clickCount": args.clickCount ?? 1,
            "frameChanged": post.changed,
            "postScreenshotSHA256": post.artifact.capture.sha256,
            "postScreenshotPath": post.artifact.reference.relativePath
        ], artifacts: [post.artifact.reference])
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
        "Click a framebuffer pixel from the latest vnc.observe screenshot. Pass its exact screenshotSHA256. Returns a post-action screenshot and separate inputDispatched/frameChanged fields; frameChanged alone is not proof of task success."
    public static let parametersJSON = #"{"type":"object","properties":{"x":{"type":"integer","minimum":0},"y":{"type":"integer","minimum":0},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"clickCount":{"type":"integer","minimum":1,"maximum":2}},"required":["x","y","screenshotSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
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
        let x = UInt16(args.x)
        let y = UInt16(args.y)
        for index in 0..<(args.clickCount ?? 1) {
            handle.session.mouseMove(x: x, y: y)
            handle.session.mouseDown(x: x, y: y)
            handle.session.mouseUp(x: x, y: y)
            if index == 0, args.clickCount == 2 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let post = try await VNCToolSupport.postActionCapture(handle, before: evidence)
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "inputDispatched": true,
            "x": args.x,
            "y": args.y,
            "clickCount": args.clickCount ?? 1,
            "frameChanged": post.changed,
            "postScreenshotSHA256": post.artifact.capture.sha256,
            "postScreenshotPath": post.artifact.reference.relativePath,
            "postRevision": post.artifact.capture.revision
        ], artifacts: [post.artifact.reference])
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
        let post = try await VNCToolSupport.postActionCapture(handle, before: before)
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "inputDispatched": true,
            "characterCount": args.text.count,
            "submitted": args.submit == true,
            "frameChanged": post.changed,
            "postScreenshotSHA256": post.artifact.capture.sha256,
            "postScreenshotPath": post.artifact.reference.relativePath,
            "postRevision": post.artifact.capture.revision
        ], artifacts: [post.artifact.reference])
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
        let before = handle.session.currentVisualEvidence
        handle.session.send(text: text)
        if args.submit == true { handle.session.send(.return) }
        let post = try await VNCToolSupport.postActionCapture(handle, before: before)
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "credentialDispatched": true,
            "submitted": args.submit == true,
            "frameChanged": post.changed,
            "postScreenshotSHA256": post.artifact.capture.sha256,
            "postScreenshotPath": post.artifact.reference.relativePath,
            "postRevision": post.artifact.capture.revision
        ], artifacts: [post.artifact.reference])
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
        let post = try await VNCToolSupport.postActionCapture(handle, before: evidence)
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "inputDispatched": true,
            "deltaY": args.deltaY,
            "frameChanged": post.changed,
            "postScreenshotSHA256": post.artifact.capture.sha256,
            "postScreenshotPath": post.artifact.reference.relativePath
        ], artifacts: [post.artifact.reference])
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
        "Drag between two framebuffer pixels from the latest vnc.observe screenshot. Returns a post-action screenshot; input dispatch is not proof that the intended item moved."
    public static let parametersJSON = #"{"type":"object","properties":{"fromX":{"type":"integer","minimum":0},"fromY":{"type":"integer","minimum":0},"toX":{"type":"integer","minimum":0},"toY":{"type":"integer","minimum":0},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"durationMilliseconds":{"type":"integer","minimum":100,"maximum":3000}},"required":["fromX","fromY","toX","toY","screenshotSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
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
        for step in 1...steps {
            try context.cancellation.throwIfCancelled()
            let progress = Double(step) / Double(steps)
            let x = Int((Double(args.fromX) + Double(args.toX - args.fromX) * progress).rounded())
            let y = Int((Double(args.fromY) + Double(args.toY - args.fromY) * progress).rounded())
            handle.session.mouseMove(x: UInt16(x), y: UInt16(y))
            try await Task.sleep(for: .milliseconds(duration / steps))
        }
        handle.session.mouseUp(x: UInt16(args.toX), y: UInt16(args.toY))
        let post = try await VNCToolSupport.postActionCapture(handle, before: evidence)
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "inputDispatched": true,
            "fromX": args.fromX,
            "fromY": args.fromY,
            "toX": args.toX,
            "toY": args.toY,
            "frameChanged": post.changed,
            "postScreenshotSHA256": post.artifact.capture.sha256,
            "postScreenshotPath": post.artifact.reference.relativePath
        ], artifacts: [post.artifact.reference])
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
        let post = try await VNCToolSupport.postActionCapture(handle, before: before)
        return try VNCToolSupport.output([
            "status": "ok",
            "sessionID": handle.id.uuidString,
            "inputDispatched": true,
            "key": args.key,
            "frameChanged": post.changed,
            "postScreenshotSHA256": post.artifact.capture.sha256,
            "postScreenshotPath": post.artifact.reference.relativePath
        ], artifacts: [post.artifact.reference])
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
    sessionProvider: @escaping VNCSessionProvider
) -> VNCSessionProvider {
    ToolCatalog.register(VNCObserveTool.self)
    ToolCatalog.register(VNCClickElementTool.self)
    ToolCatalog.register(VNCClickTool.self)
    ToolCatalog.register(VNCTypeTextTool.self)
    ToolCatalog.register(VNCTypeCredentialTool.self)
    ToolCatalog.register(VNCScrollTool.self)
    ToolCatalog.register(VNCDragTool.self)
    ToolCatalog.register(VNCKeyPressTool.self)
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
