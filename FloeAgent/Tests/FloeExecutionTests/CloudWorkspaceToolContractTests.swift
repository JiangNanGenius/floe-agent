import Foundation
import Testing
@testable import FloeExecution
import FloeTools

@Suite("Cloud workspace discovery contract")
struct CloudWorkspaceToolContractTests {
    @Test("catalog exposes a read-only ID discovery schema")
    func catalogDescriptor() throws {
        ToolCatalog.register(CloudWorkspaceCatalogTool.self)
        let descriptor = try #require(ToolCatalog.descriptor(named: "cloudWorkspace.catalog"))
        #expect(descriptor.effect == .readOnly)
        #expect(descriptor.toolDescription.contains("workspaceID"))
        #expect(descriptor.parametersJSON.contains("hostID"))
    }

    @Test("bundled guardian implements the matching workspace endpoint")
    func bundledEndpoint() throws {
        #expect(RemoteAgentPayload.version == "1.4.2")
        let source = try RemoteAgentPayload.agentSource()
        #expect(source.contains("def list_workspaces():"))
        #expect(source.contains("/v1/workspaces"))
        #expect(source.contains("VERSION = \"1.4.2\""))
    }
}
