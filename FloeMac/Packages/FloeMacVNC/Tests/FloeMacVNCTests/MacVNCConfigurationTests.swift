// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeMacVNC

@Suite("VNC configuration validation")
struct MacVNCConfigurationTests {
    @Test func defaultsUseStandardVNCPort() {
        let config = MacVNCConfiguration(host: "192.168.1.10")
        #expect(config.port == 5900)
        #expect(config.password == nil)
    }

    @Test func emptyHostIsRejected() {
        #expect(throws: MacVNCValidationError.emptyHost) {
            _ = try MacVNCConfiguration(host: "   ").validated()
        }
    }

    @Test func urlSchemesAreRejected() {
        #expect(throws: MacVNCValidationError.self) {
            _ = try MacVNCConfiguration(host: "vnc://192.168.1.10").validated()
        }
        #expect(throws: MacVNCValidationError.self) {
            _ = try MacVNCConfiguration(host: "https://desktop.example.com").validated()
        }
    }

    @Test func whitespaceIsRejected() {
        #expect(throws: MacVNCValidationError.self) {
            _ = try MacVNCConfiguration(host: "desk top.local").validated()
        }
    }

    @Test func pathQueryFragmentAndCredentialSeparatorsAreRejected() {
        for host in ["a/b", "a?b", "a#b", "user@host"] {
            #expect(throws: MacVNCValidationError.self) {
                _ = try MacVNCConfiguration(host: host).validated()
            }
        }
    }

    @Test func outOfRangePortsAreRejected() {
        #expect(throws: MacVNCValidationError.invalidPort(0)) {
            _ = try MacVNCConfiguration(host: "host", port: 0).validated()
        }
        #expect(throws: MacVNCValidationError.invalidPort(70_000)) {
            _ = try MacVNCConfiguration(host: "host", port: 70_000).validated()
        }
    }

    @Test func validHostsAndPortsPass() throws {
        for host in ["192.168.1.10", "desktop.local", "fd00::1", "10.0.0.2"] {
            let validated = try MacVNCConfiguration(host: host, port: 5901).validated()
            #expect(validated.host == host)
            #expect(validated.port == 5901)
        }
    }

    @Test func trimmingKeepsEndpointButRemovesPadding() throws {
        let validated = try MacVNCConfiguration(host: "  10.0.0.2  ").validated()
        #expect(validated.host == "10.0.0.2")
    }

    @Test func descriptionsNeverContainThePassword() {
        let secret = "sup3r-s3cret-password"
        let config = MacVNCConfiguration(host: "10.0.0.2", password: secret)
        #expect(!config.description.contains(secret))
        #expect(!config.debugDescription.contains(secret))
        #expect(!config.redactedDescription.contains(secret))
        #expect(config.redactedDescription.contains("password=set"))
        let none = MacVNCConfiguration(host: "10.0.0.2")
        #expect(none.redactedDescription.contains("password=none"))
    }
}
