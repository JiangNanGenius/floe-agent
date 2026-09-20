#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Linux component update-needed state")
struct LinuxComponentUpdatePolicyTests {
    @Test func missingInstallationAndUnversionedInstalledImageDiffer() throws {
        // No image uses the download state; old installed images need protocol 3.
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: nil) == nil)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data("{}".utf8)) != nil)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data("not json".utf8)) != nil)
    }

    @Test func currentRunnerProtocolPasses() throws {
        let manifest = #"{"runner":{"version":"2026-09-21","protocol":3}}"#
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(manifest.utf8)) == nil)
    }

    @Test func capabilitiesMatchTheEngineManifestContract() throws {
        let current = #"{"runnerCapabilities":"runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4"}"#
        let old = #"{"runnerCapabilities":"runner=1.0.0 protocol=2"}"#
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(current.utf8)) == nil)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(old.utf8)) != nil)
    }

    @Test func olderRunnerProtocolReportsUpdateNeeded() throws {
        let manifest = #"{"runner":{"version":"2026-09-01","protocol":2}}"#
        let reason = LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(manifest.utf8))
        #expect(reason != nil)
    }
}
#endif
