// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeTools
import FloeCore

private struct PushStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "push.status"
    static let toolDescription = "Read this installation's saved push preferences and actual registration, permission, install-channel and last-received/background-check status. Read-only; returns no device token, installation credential, task IDs or conversation content. Does not enable push, request permissions, register a device, send a notification or start work. A server registration receipt never proves notification delivery or scheduled-task completion."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let center: APNsCenter
    func validate(_ args: Arguments) throws {}
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard context.executionToolName == Self.name,
              context.allowedToolNames?.contains(Self.name) != false,
              context.frozenEffectiveCatalogNames?.contains(Self.name) != false else { throw FloeError.unauthorized }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(center.status())
        return .init(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: FloeDigest.sha256Hex(data), exitStatus: 0)
    }
}
@MainActor func registerAPNsAgentTools(center: APNsCenter, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(PushStatusTool.self); registry.register(PushStatusTool(center: center))
}
#endif
