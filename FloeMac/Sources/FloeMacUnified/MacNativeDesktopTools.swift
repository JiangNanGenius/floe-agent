// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import FloeAgentRuntime
import FloeCore
import FloeModels
import FloeTools

public enum MacComputerUseBackend: String, Sendable { case kimi, floe }

struct MacDesktopReply: Sendable {
    var text: String
    var image: Data?
    var mime: String?
}

protocol MacDesktopClient: Sendable {
    func perform(_ action: MacDesktopControl.Arguments, pid: Int32, context: ToolContext) async throws -> MacDesktopReply
}

enum MacDesktopError: LocalizedError {
    case invalidTarget, permission

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "Choose a target app, then inspect its window again before acting."
        case .permission: "This action requires approval to access another application."
        }
    }
}

enum MacNativeDesktopTools {
    static func available(rootURL: URL, backend: MacComputerUseBackend = .kimi) -> [any MacAgentWorkspaceExecutable] {
        let root = MacAgentWorkspaceRoot(rootURL)
        var tools: [any MacAgentWorkspaceExecutable] = [MacDesktopStatus(backend: backend)]
        switch backend {
        case .kimi:
            if MacKimiComputerUse.isInstalled() {
                tools.append(MacDesktopControl(root: root, backend: .kimi, client: MacKimiComputerUse(), actions: MacDesktopControl.Action.allCases))
            }
        case .floe:
            let actions = MacFloeComputerUse.availableActions
            if !actions.isEmpty {
                tools.append(MacDesktopControl(root: root, backend: .floe, client: MacFloeComputerUse(), actions: actions))
            }
        }
        return tools
    }
}

private struct MacDesktopStatus: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Codable, Sendable {}
    static let name = "mac.desktop.status"
    static let toolDescription = "Check the selected backend for background Mac window control and its availability."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let backend: MacComputerUseBackend

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        switch backend {
        case .kimi:
            return .init(digesting: MacKimiComputerUse.isInstalled()
                ? "Kimi CU is selected and installed. Window actions use its local agent connection and macOS permissions."
                : "Kimi CU is selected. Install it or select Floe Native in Settings > Permissions > Computer Use.")
        case .floe:
            return .init(digesting: MacFloeComputerUse.status)
        }
    }
}

struct MacDesktopControl: AgentTool, MacAgentWorkspaceExecutable {
    enum Action: String, CaseIterable, Codable, Sendable {
        case windows, inspect, screenshot, click, setValue, keys, drag

        var sendsInput: Bool {
            switch self {
            case .click, .setValue, .keys, .drag: true
            case .windows, .inspect, .screenshot: false
            }
        }
    }
    struct Arguments: Codable, Sendable {
        let action: Action
        let app: String
        let pid: Int32?
        let windowID: Int?
        let snapshotID: String?
        let index: Int?
        let value: String?
        let keys: String?
        let fromX: Double?
        let fromY: Double?
        let toX: Double?
        let toY: Double?
        let steps: Int?
        let stepMs: Int?
        let holdMs: Int?
    }

    static let name = "mac.desktop.control"
    static let toolDescription = "Control one running Mac app by bundle ID in the background using Kimi CU. List its windows, inspect a specific window for a snapshot and node indices, then click or set a value. Send one key or shortcut to the focused control in that window, or drag between two points on its current screenshot. Verify the window state after each action. Captures only the selected window and keeps it in the background."
    static let parametersJSON = schema(actions: Action.allCases)

    private static func schema(actions: [Action]) -> String {
        let entries = actions.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return #"""
        {"type":"object","properties":{"action":{"type":"string","enum":[\#(entries)]},"app":{"type":"string","description":"Target application's bundle identifier"},"pid":{"type":"integer","description":"Process ID when the app has several running instances"},"windowID":{"type":"integer","description":"Window ID from windows"},"snapshotID":{"type":"string","description":"AX snapshot_id from inspect or screenshot of this window"},"index":{"type":"integer","description":"Node index from that snapshot (click, setValue)"},"value":{"type":"string","description":"Text for setValue"},"keys":{"type":"string","description":"Single xdotool-style key or chord for keys, e.g. \"cmd+a\" or \"return\""},"fromX":{"type":"number","description":"Drag start x in screenshot pixels of the current screenshot action"},"fromY":{"type":"number","description":"Drag start y in screenshot pixels of the current screenshot action"},"toX":{"type":"number","description":"Drag end x in screenshot pixels of the current screenshot action"},"toY":{"type":"number","description":"Drag end y in screenshot pixels of the current screenshot action"},"steps":{"type":"integer","description":"Drag interpolation points 1...500 (optional)"},"stepMs":{"type":"integer","description":"Gap between drag move events 0...100 ms (optional)"},"holdMs":{"type":"integer","description":"Press-and-hold before the drag move 0...1000 ms (optional)"}},"required":["action","app"],"additionalProperties":false}
        """#
    }
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    /// Screenshot-pixel drag stays inside one observation and one transport deadline.
    static let maxDragCoordinate = 16_384.0
    static let maxDragDurationMilliseconds = 15_000
    let root: MacAgentWorkspaceRoot
    let backend: MacComputerUseBackend
    let client: any MacDesktopClient
    let actions: [Action]

    var executionDescriptor: ToolCatalog.Descriptor {
        guard backend == .floe else { return Self.descriptor }
        return .init(name: Self.name, toolDescription: MacFloeComputerUse.toolDescription,
                     parametersJSON: Self.schema(actions: actions), riskLabels: Self.riskLabels,
                     isSideEffecting: Self.isSideEffecting, executionBoundary: Self.executionBoundary)
    }

    func validate(_ args: Arguments) throws {
        guard !args.app.isEmpty, args.app.utf8.count <= 255, args.pid.map({ $0 > 0 }) != false,
              actions.contains(args.action),
              args.action == .windows || args.windowID.map({ $0 > 0 }) == true else { throw MacDesktopError.invalidTarget }
        if args.action == .click || args.action == .setValue {
            guard let id = args.snapshotID, UUID(uuidString: id) != nil, args.index.map({ $0 >= 0 }) == true else {
                throw MacDesktopError.invalidTarget
            }
        }
        if args.action == .setValue {
            guard let value = args.value, value.utf8.count <= 4096 else { throw MacDesktopError.invalidTarget }
        }
        if args.action == .keys {
            guard let id = args.snapshotID, UUID(uuidString: id) != nil,
                  let keys = args.keys, !keys.isEmpty, keys.utf8.count <= 48,
                  keys.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
                throw MacDesktopError.invalidTarget
            }
        }
        if args.action == .drag {
            guard let id = args.snapshotID, UUID(uuidString: id) != nil else { throw MacDesktopError.invalidTarget }
            guard let fromX = args.fromX, let fromY = args.fromY, let toX = args.toX, let toY = args.toY,
                  fromX.isFinite, fromY.isFinite, toX.isFinite, toY.isFinite,
                  (0...Self.maxDragCoordinate).contains(fromX), (0...Self.maxDragCoordinate).contains(fromY),
                  (0...Self.maxDragCoordinate).contains(toX), (0...Self.maxDragCoordinate).contains(toY) else {
                throw MacDesktopError.invalidTarget
            }
            guard max(abs(toX - fromX), abs(toY - fromY)) >= 1 else { throw MacDesktopError.invalidTarget }
            if let steps = args.steps, !(1...500).contains(steps) { throw MacDesktopError.invalidTarget }
            if let stepMs = args.stepMs, !(0...100).contains(stepMs) { throw MacDesktopError.invalidTarget }
            if let holdMs = args.holdMs, !(0...1000).contains(holdMs) { throw MacDesktopError.invalidTarget }
            let duration = (args.steps ?? 24) * (args.stepMs ?? 12) + (args.holdMs ?? 0)
            guard duration <= Self.maxDragDurationMilliseconds else { throw MacDesktopError.invalidTarget }
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard case .local = context.scope, context.approvalGrantID != nil else { throw MacDesktopError.permission }
        switch context.approvalOrigin {
        case .humanCard, .policy("full-access"): break
        default: throw MacDesktopError.permission
        }
        let pid: Int32 = try await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: args.app)
                .filter { !($0.isTerminated) && (args.pid == nil || $0.processIdentifier == args.pid) }
            guard apps.count == 1, let app = apps.first else { throw MacDesktopError.invalidTarget }
            return app.processIdentifier
        }
        let reply: MacDesktopReply
        do {
            reply = try await client.perform(args, pid: pid, context: context)
        } catch where args.action.sendsInput {
            return .init(digesting: error.localizedDescription + " Inspect the target before trying again.",
                         exitStatus: 1, outcomeUnknown: true)
        }
        if let bytes = reply.image, let mime = reply.mime {
            let artifact = try save(bytes, mime: mime, context: context)
            let text = reply.text.isEmpty ? "" : "\nWindow observation:\n" + reply.text
            return .init(digesting: "Window capture saved to " + artifact.relativePath + text, artifacts: [artifact])
        }
        return .init(digesting: reply.text, maximumSummaryCharacters: 24_000)
    }

    private func save(_ bytes: Data, mime: String, context: ToolContext) throws -> ToolArtifactReference {
        let id = UUID()
        let name = "Window-" + id.uuidString + (mime == "image/png" ? ".png" : ".jpg")
        try context.authorizeWorkspacePath(name)
        guard let physical = root.physicalPath else { throw MacDesktopError.invalidTarget }
        try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: name, root: root) { pin in
            let parent = pin.parentFileDescriptor
            let stage = ".floe-window-" + id.uuidString
            let fd = openat(parent, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd); unlinkat(parent, stage, 0) }
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { throw CocoaError(.fileWriteUnknown) }
                var offset = 0
                while offset < raw.count {
                    try context.cancellation.throwIfCancelled()
                    let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += count
                }
            }
            try context.cancellation.throwIfCancelled()
            guard fsync(fd) == 0, linkat(parent, stage, parent, pin.name, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        return .init(id: id, relativePath: name, mimeType: mime, byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes))
    }
}
