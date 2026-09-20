#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Linux component update-needed state")
struct LinuxComponentUpdatePolicyTests {
    @Test func absentRunnerMetadataMeansNoUpdateClaim() throws {
        // The current pinned image has no runner record yet; nothing may
        // claim an update from absent data.
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: nil) == nil)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data("{}".utf8)) == nil)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data("not json".utf8)) == nil)
    }

    @Test func currentRunnerProtocolPasses() throws {
        let manifest = #"{"runner":{"version":"2026-09-21","protocol":2}}"#
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(manifest.utf8)) == nil)
    }

    @Test func olderRunnerProtocolReportsUpdateNeeded() throws {
        let manifest = #"{"runner":{"version":"2026-09-01","protocol":1}}"#
        let reason = LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(manifest.utf8))
        #expect(reason != nil)
    }
}
#endif
