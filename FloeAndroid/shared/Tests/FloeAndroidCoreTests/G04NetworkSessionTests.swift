// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeAndroidCore

@Suite struct G04NetworkSessionTests {
    @Test func redirectsKeepExactCredentialOrigin() throws {
        let origin = try G04NetworkOrigin(URL(string: "https://dav.example/files/")!)
        #expect(origin.allows(URL(string: "https://DAV.example:443/other")))
        #expect(!origin.allows(URL(string: "http://dav.example/files/")))
        #expect(!origin.allows(URL(string: "https://other.example/files/")))
        #expect(!origin.allows(URL(string: "https://dav.example:444/files/")))
        #expect(!origin.allows(URL(string: "https://user:secret@dav.example/files/")))
        #expect(!origin.allows(URL(string: "file:///files/")))
        #expect(!origin.allows(nil))
    }

    @Test func explicitLanMountDoesNotWidenItsOrigin() throws {
        let origin = try G04NetworkOrigin(URL(string: "http://192.0.2.10:8080/dav")!)
        #expect(origin.allows(URL(string: "http://192.0.2.10:8080/dav/item")))
        #expect(!origin.allows(URL(string: "http://192.0.2.10/dav")))
        #expect(!origin.allows(URL(string: "http://192.0.2.11:8080/dav")))
        #expect(!origin.allows(URL(string: "https://192.0.2.10:8080/dav")))
    }

    // Added by the network-workspace composition lane (job-20000d7c450d4353):
    // the mount owner's injection contract. Construction facts only — no
    // device, no network, no TLS claim.

    @Test func sessionConfigurationIsScopedAndCacheFree() throws {
        let session = try G04NetworkSession(
            endpoint: URL(string: "https://dav.example.test/files")!)
        let configuration = session.session.configuration
        // The delivered scope: nothing persisted, nothing reused, nothing
        // auto-attaching. A mount record's credential is the only auth.
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(session.session.delegate != nil)
    }

    @Test func userinfoEndpointIsRefusedWithoutEchoingTheSecret() {
        // The credential path is the leased resolver ONLY; a URL that
        // smuggles userinfo never produces a session, and the thrown
        // validation detail carries no secret text.
        let endpoint = URL(string: "https://alice:Sup3rSecret@dav.example.test/files")!
        #expect(throws: (any Error).self) { _ = try G04NetworkOrigin(endpoint) }
        do {
            _ = try G04NetworkSession(endpoint: endpoint)
            Issue.record("userinfo endpoint must refuse")
        } catch {
            #expect(!String(describing: error).contains("Sup3rSecret"))
            #expect(!String(describing: error).contains("alice:"))
        }
    }

    @Test func schemeAndPortGrammarAreExact() throws {
        #expect(throws: (any Error).self) { _ = try G04NetworkOrigin(URL(string: "ftp://host/dav")!) }
        #expect(throws: (any Error).self) { _ = try G04NetworkOrigin(URL(string: "https://host:0/dav")!) }
        let lan = try G04NetworkOrigin(URL(string: "http://192.168.150.9:5005")!)
        #expect(lan.scheme == "http")
        #expect(lan.port == 5005)
        let secure = try G04NetworkOrigin(URL(string: "https://DAV.Example.test")!)
        #expect(secure.host == "dav.example.test")
        #expect(secure.port == 443)
    }
}
