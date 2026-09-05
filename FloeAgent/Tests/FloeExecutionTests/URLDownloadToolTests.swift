import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.URLDownload")
struct URLDownloadToolTests {

    @Test("descriptor is side-effecting network + file write")
    func descriptorContract() {
        #expect(URLDownloadTool.name == "network.download")
        #expect(URLDownloadTool.isSideEffecting)
        #expect(URLDownloadTool.riskLabels == [.networkAccess, .writesFiles])
    }

    @Test("registration wires catalog and runner")
    func registration() {
        let registry = ToolRunnerRegistry()
        registerExecutionTools(registry: registry)
        #expect(ToolCatalog.descriptor(named: "network.download") != nil)
        #expect(registry.runner(named: "network.download") != nil)
    }

    @Test("LAN diagnostic targets validate without DNS")
    func lanValidation() throws {
        let tool = URLDownloadTool()
        try tool.validate(.init(url: "http://192.168.1.10/firmware.bin", destination: "downloads/fw.bin", localNetwork: true))
    }

    @Test("metadata endpoints and credential URLs are rejected")
    func hostileURLsRejected() {
        let tool = URLDownloadTool()
        for value in [
            "http://169.254.169.254/latest/meta-data",
            "https://169.254.169.254",
            "http://user:password@192.168.1.1/x"
        ] {
            #expect(throws: FloeError.self) {
                try tool.validate(.init(url: value, destination: "d.bin", localNetwork: true))
            }
        }
    }

    @Test("destination must be a safe workspace-relative path")
    func destinationValidation() {
        let tool = URLDownloadTool()
        for bad in ["../escape.bin", "/abs.bin", "~/home.bin", "a/../../b.bin", "  "] {
            #expect(throws: FloeError.self) {
                try tool.validate(.init(url: "http://192.168.1.10/f.bin", destination: bad, localNetwork: true))
            }
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(url: "http://192.168.1.10/f.bin", destination: "d.bin", maxBytes: 0, localNetwork: true))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(url: "http://192.168.1.10/f.bin", destination: "d.bin", timeout: -1, localNetwork: true))
        }
    }

    @Test("execution without a task workspace fails honestly")
    func noWorkspace() async throws {
        let tool = URLDownloadTool()
        let output = try await tool.execute(
            .init(url: "http://192.168.1.10/f.bin", destination: "d.bin", localNetwork: true),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("No task workspace"))
    }
}
