// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeModels
import FloeSecurity

/// Reuses the exact visual evidence/action implementation with an RDP-owned
/// session provider. Register only when the RDP runtime and endpoint exist.
public struct RDPTool<Base: AgentTool>: AgentTool {
    public typealias Arguments = Base.Arguments
    public static var name: String { Base.name.replacingOccurrences(of: "vnc.", with: "rdp.") }
    public static var toolDescription: String {
        Base.toolDescription.replacingOccurrences(of: "VNC", with: "RDP")
            .replacingOccurrences(of: "vnc.", with: "rdp.")
            .replacingOccurrences(of: "RFB", with: "RDP framebuffer")
    }
    public static var parametersJSON: String { Base.parametersJSON }
    public static var riskLabels: Set<RiskLabel> { Base.riskLabels }
    public static var isSideEffecting: Bool { Base.isSideEffecting }
    public static var toolEffect: ToolEffect { Base.toolEffect }
    public static var requiresHostScope: Bool { Base.requiresHostScope }
    public static var prerequisites: [ToolPrerequisite] {
        Base.prerequisites.map {
            ToolPrerequisite(state: $0.state.replacingOccurrences(of: "vnc.", with: "rdp."),
                resolverToolName: $0.resolverToolName?.replacingOccurrences(of: "vnc.", with: "rdp."),
                mayResolveAutomatically: $0.mayResolveAutomatically)
        }
    }
    private let base: Base
    public init(_ base: Base) { self.base = base }
    public func validate(_ args: Arguments) throws {
        try VNCToolSupport.$protocolName.withValue("rdp") { try base.validate(args) }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await VNCToolSupport.$protocolName.withValue("rdp") {
            try await base.execute(args, context: context)
        }
    }
}
