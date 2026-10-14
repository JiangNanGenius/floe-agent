// FloeExecutionTests — Temporary-chat web transport privacy.
//
// The web.search/web.fetch pair is the whole temporary-chat tool ceiling, so
// these tests pin the transport facts the privacy audit relies on: the
// default sessions never touch the shared on-disk URLCache or cookie/credential
// storage, and search results (citations included) are runtime values with no
// persistence path of their own.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.TemporaryWebPrivacy")
struct TemporaryWebPrivacyTests {

    private func context(publicWebOnly: Bool) -> ToolContext {
        ToolContext(
            runID: UUID(),
            publicWebOnly: publicWebOnly,
            cancellation: CancellationToken()
        )
    }

    @Test("Temporary web.fetch refuses the LAN opt-in even for a public URL")
    func tempFetchRefusesLocalNetworkOptIn() async throws {
        let tool = WebFetchTool()
        let args = WebFetchTool.Arguments(url: "https://example.com", localNetwork: true)
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(args, context: context(publicWebOnly: true))
        }
    }

    @Test("Temporary web.fetch refuses private and localhost targets without any network access")
    func tempFetchRefusesPrivateTargets() async throws {
        let tool = WebFetchTool()
        for url in ["http://192.168.1.10/", "http://127.0.0.1:8080/", "http://localhost/"] {
            let args = WebFetchTool.Arguments(url: url)
            // Refused at the tool-entry policy check (PublicNetworkTargetPolicy
            // throws HTTPRequestError) before any transport exists.
            await #expect(throws: (any Error).self) {
                _ = try await tool.execute(args, context: context(publicWebOnly: true))
            }
        }
    }

    @Test("Ordinary authorized LAN fetch keeps the diagnostic validation path")
    func ordinaryFetchKeepsDiagnosticPath() throws {
        let tool = WebFetchTool()
        // Validation-level only (execute would touch the network): the
        // ordinary run retains the user-requested LAN diagnostic boundary.
        try tool.validate(WebFetchTool.Arguments(url: "http://192.168.1.10/", localNetwork: true))
        try tool.validate(WebFetchTool.Arguments(url: "https://example.com"))
    }

    @Test("WebSearchService default transport is a non-shared ephemeral session with no disk cache")
    func searchServiceIsEphemeral() async throws {
        let service = WebSearchService()
        let session = await service.session
        #expect(session !== URLSession.shared)
        let configuration = session.configuration
        // Ephemeral configuration: never the shared on-disk cache, no
        // persistent cookie jar or credential storage.
        #expect(configuration.urlCache == nil || configuration.urlCache?.diskCapacity == 0)
        // The shared cookie jar must not be inherited.
        if let cookies = configuration.httpCookieStorage {
            #expect(cookies !== HTTPCookieStorage.shared)
        }
    }

    @Test("HTTPRequestService nils cookie and credential storage and keeps no disk cache")
    func requestServiceIsEphemeral() {
        let service = HTTPRequestService()
        #expect(service.session !== URLSession.shared)
        let configuration = service.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil || configuration.urlCache?.diskCapacity == 0)
    }

    @Test("HTTPRequestService keeps the SSRF guard with the ephemeral transport")
    func requestServiceStillGuardsPrivateTargets() {
        // Private-network policy stays on the ephemeral transport: the
        // privacy change must not weaken the existing SSRF boundary.
        let service = HTTPRequestService()
        #expect(service.allowsPrivateNetwork == false)
    }

    @Test("Explicitly allowing private network does not restore shared storage")
    func privateNetworkVariantStaysScoped() {
        let service = HTTPRequestService(allowsPrivateNetwork: true)
        let configuration = service.session.configuration
        #expect(configuration.urlCache == nil || configuration.urlCache?.diskCapacity == 0)
    }
}
