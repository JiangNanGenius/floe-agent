#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("Linux component update-needed state")
struct LinuxComponentUpdatePolicyTests {
    @Test func missingInstallationIsNotAnOutdatedClaim() throws {
        // No manifest at all declares nothing: never an outdated claim.
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: nil) == nil)
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: nil) == .undeclared)
    }

    @Test func manifestWithoutRunnerMetadataIsUndeclaredNotOutdated() throws {
        // Build 238 regression: the CURRENT published SMP image ships exactly
        // this shape — no runner/runnerCapabilities fields — and was falsely
        // labelled obsolete by the old "absence means old" reading.
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: Data("{}".utf8)) == .undeclared)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data("{}".utf8)) == nil)
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: Data("not json".utf8)) == .undeclared)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data("not json".utf8)) == nil)
    }

    /// Synthetic/redacted fixture with the REAL public SMP manifest shape
    /// (floe-linux-guest-smp-20260928.1 manifest.json, values redacted): id,
    /// boot paths, qualified flag, artifacts, provenance, smp_capable and the
    /// verified template block — and NO runner fields anywhere. This image is
    // not outdated, and no protocol may be invented from its absence.
    @Test func realPublishedSMPManifestShapeIsNotOutdated() throws {
        let manifest = """
        {
          "id": "floe-debian13-riscv64-202609202607-basic-redacted-1",
          "biosPath": "bbl64.bin",
          "diskReadWrite": true,
          "qualified": true,
          "kernelPath": "kernel-riscv64.bin",
          "diskPath": "disk.img",
          "cmdline": "console=hvc0 root=/dev/vda rw loglevel=4",
          "qualificationEvidence": "redacted",
          "qualificationRun": "https://example.invalid/runs/redacted",
          "artifacts": [
            {"role": "bios", "path": "bbl64.bin", "sha512": "redacted", "bytes": 74258},
            {"role": "kernel", "path": "kernel-riscv64.bin", "sha512": "redacted", "bytes": 5121044},
            {"role": "disk", "path": "disk.img", "sha512": "redacted", "bytes": 17179869184}
          ],
          "provenance": {
            "sourceURL": "https://example.invalid/source",
            "license": "redacted",
            "distributionAllowed": true
          },
          "smp_capable": true,
          "template": {
            "id": "basic",
            "recipeSha512": "redacted",
            "recipePath": "redacted",
            "verified": true,
            "missingPackages": [],
            "belowMinimum": [],
            "pypiFailures": [],
            "packages": [],
            "checks": ["recipe:sha512", "stage1-install:present", "apt-missing:0"]
          }
        }
        """
        let data = Data(manifest.utf8)
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: data) == .undeclared)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: data) == nil,
                "the fresh published image must never be labelled obsolete")
    }

    @Test func currentRunnerProtocolPasses() throws {
        let manifest = #"{"runner":{"version":"2026-09-21","protocol":3}}"#
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: Data(manifest.utf8)) == .current)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(manifest.utf8)) == nil)
    }

    @Test func capabilitiesMatchTheEngineManifestContract() throws {
        // The legacy single-hart image declares this exact capability string.
        let current = #"{"runnerCapabilities":"runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4"}"#
        let old = #"{"runnerCapabilities":"runner=1.0.0 protocol=2"}"#
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: Data(current.utf8)) == .current)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(current.utf8)) == nil)
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: Data(old.utf8)) == .outdated)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(old.utf8)) != nil)
    }

    @Test func olderRunnerProtocolReportsUpdateNeeded() throws {
        let manifest = #"{"runner":{"version":"2026-09-01","protocol":2}}"#
        #expect(LinuxComponentUpdatePolicy.runnerState(manifestData: Data(manifest.utf8)) == .outdated)
        #expect(LinuxComponentUpdatePolicy.updateNeededReason(manifestData: Data(manifest.utf8)) != nil)
    }
}
#endif
