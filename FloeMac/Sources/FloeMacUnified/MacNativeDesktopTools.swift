// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import FloeAgentRuntime
import FloeCore
import FloeModels
import FloeTools

enum MacNativeDesktopTools {
    static func available(rootURL: URL) -> [any MacAgentWorkspaceExecutable] {
        let installed = MacKimiComputerUse.isInstalled()
        var tools: [any MacAgentWorkspaceExecutable] = [MacDesktopStatus(installed: installed)]
        if installed { tools.append(MacDesktopControl(root: MacAgentWorkspaceRoot(rootURL))) }
        return tools
    }
}

private struct MacDesktopStatus: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Codable, Sendable {}
    static let name = "mac.desktop.status"
    static let toolDescription = "Check whether the signed local Kimi CU companion is installed for background Mac window control."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let installed: Bool

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return .init(digesting: installed
            ? "Kimi CU is installed. Window actions use its local agent connection and macOS permissions."
            : "Install Kimi CU from Settings > Permissions to control other Mac apps in the background.")
    }
}

struct MacDesktopControl: AgentTool, MacAgentWorkspaceExecutable {
    enum Action: String, Codable, Sendable { case windows, inspect, screenshot, click, setValue }
    struct Arguments: Codable, Sendable {
        let action: Action
        let app: String
        let pid: Int32?
        let windowID: Int?
        let snapshotID: String?
        let index: Int?
        let value: String?
    }

    static let name = "mac.desktop.control"
    static let toolDescription = "Control one running Mac app by bundle ID in the background using Kimi CU. List its windows, inspect a specific window for a snapshot and node indices, then click or set a value. Re-inspect after each action and verify its effect. Captures only the selected window. Never activates an app or requests foreground fallback."
    static let parametersJSON = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["windows","inspect","screenshot","click","setValue"]},"app":{"type":"string","description":"Target application's bundle identifier"},"pid":{"type":"integer","description":"Process ID when the app has several running instances"},"windowID":{"type":"integer","description":"Window ID from windows"},"snapshotID":{"type":"string","description":"AX snapshot_id from inspect"},"index":{"type":"integer","description":"Node index from that snapshot"},"value":{"type":"string","description":"Text for setValue"}},"required":["action","app"],"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let root: MacAgentWorkspaceRoot
    let client = MacKimiComputerUse()

    func validate(_ args: Arguments) throws {
        guard !args.app.isEmpty, args.app.utf8.count <= 255, args.pid.map({ $0 > 0 }) != false,
              args.action == .windows || args.windowID.map({ $0 > 0 }) == true else { throw MacKimiError.invalidTarget }
        if args.action == .click || args.action == .setValue {
            guard let id = args.snapshotID, UUID(uuidString: id) != nil, args.index.map({ $0 >= 0 }) == true else {
                throw MacKimiError.invalidTarget
            }
        }
        if args.action == .setValue {
            guard let value = args.value, value.utf8.count <= 4096 else { throw MacKimiError.invalidTarget }
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard case .local = context.scope, context.approvalGrantID != nil else { throw MacKimiError.permission }
        switch context.approvalOrigin {
        case .humanCard, .policy("full-access"): break
        default: throw MacKimiError.permission
        }
        let pid: Int32 = try await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: args.app)
                .filter { !($0.isTerminated) && (args.pid == nil || $0.processIdentifier == args.pid) }
            guard apps.count == 1, let app = apps.first else { throw MacKimiError.invalidTarget }
            return app.processIdentifier
        }
        let reply: MacKimiComputerUse.Reply
        do {
            reply = try await client.perform(args, pid: pid, context: context)
        } catch where args.action == .click || args.action == .setValue {
            return .init(digesting: error.localizedDescription + " Inspect the target before trying again.",
                         exitStatus: 1, outcomeUnknown: true)
        }
        if let bytes = reply.image, let mime = reply.mime {
            let artifact = try save(bytes, mime: mime, context: context)
            return .init(digesting: "Window capture saved to " + artifact.relativePath, artifacts: [artifact])
        }
        return .init(digesting: reply.text, maximumSummaryCharacters: 24_000)
    }

    private func save(_ bytes: Data, mime: String, context: ToolContext) throws -> ToolArtifactReference {
        let id = UUID()
        let name = "Window-" + id.uuidString + (mime == "image/png" ? ".png" : ".jpg")
        try context.authorizeWorkspacePath(name)
        guard let physical = root.physicalPath else { throw MacKimiError.invalidTarget }
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
