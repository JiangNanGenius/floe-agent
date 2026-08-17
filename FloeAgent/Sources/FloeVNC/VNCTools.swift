// FloeVNC — VNC agent tools.
//
// The agent can drive the user's open VNC session: click at screen
// coordinates and type text. Actions are exercised against the live
// VNCSession via an injected provider; the tools are side-effecting and
// require a connected session.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Supplies the live VNC session the agent should drive (nil = none open).
public typealias VNCSessionProvider = @Sendable () async -> VNCSession?

/// Clicks at screen coordinates (left button).
public struct VNCClickTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public static let name = "vnc.click"
    public static let toolDescription =
        "Click at screen coordinates (left button) in the open VNC remote-desktop session. Coordinates are absolute pixels."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "x": {"type": "integer", "description": "X pixel coordinate"},
        "y": {"type": "integer", "description": "Y pixel coordinate"}
      },
      "required": ["x", "y"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    /// The target is the already user-selected live session; there is no
    /// model-provided host UUID to bind into ToolScope.
    public static let requiresHostScope = false

    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) {
        self.sessionProvider = sessionProvider
    }

    public func validate(_ args: Arguments) throws {
        guard args.x >= 0, args.y >= 0 else {
            throw FloeError.validationFailed("coordinates must be non-negative")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let session = await sessionProvider() else {
            return Self.output("status=error error=No active VNC session", exitStatus: 2)
        }
        let x = UInt16(clamping: args.x)
        let y = UInt16(clamping: args.y)
        session.mouseMove(x: x, y: y)
        session.mouseDown(x: x, y: y)
        session.mouseUp(x: x, y: y)
        return Self.output("clicked=\(x),\(y)", exitStatus: 0)
    }

    static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

/// Types text into the open VNC session.
public struct VNCTypeTextTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var text: String

        public init(text: String) {
            self.text = text
        }
    }

    public static let name = "vnc.typeText"
    public static let toolDescription =
        "Type text into the open VNC remote-desktop session at the current focus."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "text": {"type": "string", "description": "Text to type"}
      },
      "required": ["text"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.controlsGUI, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let sessionProvider: VNCSessionProvider

    public init(sessionProvider: @escaping VNCSessionProvider) {
        self.sessionProvider = sessionProvider
    }

    public func validate(_ args: Arguments) throws {
        if args.text.isEmpty {
            throw FloeError.validationFailed("text must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let session = await sessionProvider() else {
            return VNCClickTool.output("status=error error=No active VNC session", exitStatus: 2)
        }
        session.send(text: args.text)
        return VNCClickTool.output("typed=\(args.text.count) chars", exitStatus: 0)
    }
}

/// Registers the VNC tools against a live-session provider.
@discardableResult
public func registerVNCTools(
    registry: ToolRunnerRegistry = .shared,
    sessionProvider: @escaping VNCSessionProvider
) -> VNCSessionProvider {
    ToolCatalog.register(VNCClickTool.self)
    ToolCatalog.register(VNCTypeTextTool.self)
    registry.register(VNCClickTool(sessionProvider: sessionProvider))
    registry.register(VNCTypeTextTool(sessionProvider: sessionProvider))
    return sessionProvider
}
