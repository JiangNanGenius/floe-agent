// FloeExecutionTests — persistent-disk runner capability policy.
//
// These checks are pure: no VM, console, image bytes or ledger. They pin the
// boundary the registry applies to a LIVE FLOE-CAPS answer after an in-guest
// runner upgrade became necessary, including the case where a runner already
// speaks protocol 3 but predates the additive `env=1` capability an installed
// image explicitly requires.

import XCTest
@testable import FloeExecution

final class LinuxRunnerEnvironmentUpgradeTests: XCTestCase {
    /// What runner 2.1.0 answers and what a new image records as its exact
    /// contract.
    private let environmentCaps =
        "runner=2.1.0 protocol=3 maxCommands=8 maxSessions=4 env=1 net=up"

    /// A runner that already routes concurrent tokens but predates the
    /// per-process environment transport.
    private let protocolThreeWithoutEnvironment =
        "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=up"

    /// A pre-protocol-3 runner: no HELLO/CAPS answer at all in the real guest.
    private let legacyCaps = "runner=1.0.0 protocol=2"

    // MARK: - current

    func testCurrentProtocolAndRequiredCapabilityIsAccepted() {
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: environmentCaps, live: environmentCaps
            ),
            .current
        )
        XCTAssertTrue(
            LinuxGuestRunnerUpgradePolicy.satisfies(
                required: environmentCaps, live: environmentCaps
            )
        )
    }

    func testCurrentRunnerIsAcceptedWhenManifestHasNoEnvironmentMetadata() {
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: protocolThreeWithoutEnvironment,
                live: protocolThreeWithoutEnvironment
            ),
            .current
        )
    }

    // MARK: - legacy

    func testLegacyProtocolRequiresUpgrade() {
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: environmentCaps, live: legacyCaps
            ),
            .upgrade(.legacyRunner)
        )
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(required: nil, live: legacyCaps),
            .upgrade(.legacyRunner)
        )
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(required: environmentCaps, live: nil),
            .upgrade(.legacyRunner)
        )
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(required: environmentCaps, live: ""),
            .upgrade(.legacyRunner)
        )
    }

    // MARK: - required additive capability

    func testProtocolThreeWithoutExplicitlyRequiredEnvironmentRequiresUpgrade() {
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: environmentCaps,
                live: protocolThreeWithoutEnvironment
            ),
            .upgrade(.requiredCapabilityMissing("env=1"))
        )
        XCTAssertFalse(
            LinuxGuestRunnerUpgradePolicy.satisfies(
                required: environmentCaps,
                live: protocolThreeWithoutEnvironment
            )
        )
    }

    func testRequiredEnvironmentIsStillRequiredAfterAnUpgradeReboot() {
        // The post-upgrade probe is evaluated by the same policy. A runner
        // that comes back protocol-current but without the installed
        // artifact's declared capability is a failed upgrade, not a success.
        let postUpgrade =
            "runner=2.1.0 protocol=3 maxCommands=8 maxSessions=4 env=0 net=up"
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: environmentCaps, live: postUpgrade
            ),
            .upgrade(.requiredCapabilityMissing("env=1"))
        )
        XCTAssertFalse(
            LinuxGuestRunnerUpgradePolicy.satisfies(
                required: environmentCaps, live: postUpgrade
            )
        )
    }

    // MARK: - old manifests keep their previous acceptance

    func testManifestWithoutEnvironmentMetadataKeepsProtocolThreeAcceptance() {
        // No `env=` field at all in the trusted image metadata: an older
        // manifest must not force an upgrade just because the current runner
        // happens to advertise the additive capability (or not).
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4",
                live: protocolThreeWithoutEnvironment
            ),
            .current
        )
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4",
                live: environmentCaps
            ),
            .current
        )
    }

    func testManifestWithEnvironmentZeroDoesNotRequireUpgrade() {
        // Only an explicit `env=1` is an additive requirement. `env=0`
        // describes an old runner generation; it must not make every boot
        // attempt a pointless upgrade.
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 env=0",
                live: protocolThreeWithoutEnvironment
            ),
            .current
        )
    }

    // MARK: - forged / nominal version claims

    func testNominalProtocolVersionDoesNotForgeRequiredEnvironment() {
        // A high protocol number alone never satisfies an explicit `env=1`
        // requirement; the capability must be present in the live CAPS.
        let forgedVersion =
            "runner=9.9.9 protocol=99 maxCommands=8 maxSessions=4 net=up"
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: environmentCaps, live: forgedVersion
            ),
            .upgrade(.requiredCapabilityMissing("env=1"))
        )
    }

    func testEnvironmentCapabilityMustBeAnExactToken() {
        for live in [
            "runner=2.1.0 protocol=3 env=10 net=up",
            "runner=2.1.0 protocol=3 env=01 net=up",
            "runner=2.1.0 protocol=3 xenv=1 net=up",
            "runner=2.1.0 protocol=3 environment=1 net=up",
            "runner=2.1.0 protocol=3 env=1x net=up"
        ] {
            XCTAssertEqual(
                LinuxGuestRunnerUpgradePolicy.evaluate(
                    required: environmentCaps, live: live
                ),
                .upgrade(.requiredCapabilityMissing("env=1")),
                "unexpected acceptance for \(live)"
            )
        }
    }

    // MARK: - parsing

    func testHostArchiveEchoDoesNotChangeTheCapabilityDecision() {
        // The real CAPS answer carries the host's HELLO advertisement. The
        // manifest records only runner-owned fields (the registry's identity
        // comparison excludes hostArchive=), so the policy must ignore it.
        let liveWithEcho = environmentCaps + " hostArchive=none"
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: environmentCaps, live: liveWithEcho
            ),
            .current
        )
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(
                required: liveWithEcho, live: environmentCaps
            ),
            .current
        )
    }

    func testProtocolAndEnvironmentFieldsTolerateWhitespace() {
        let spaced =
            " runner=2.1.0\tprotocol=3  maxCommands=8 maxSessions=4 \tenv=1 net=up "
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(required: environmentCaps, live: spaced),
            .current
        )
        XCTAssertEqual(
            LinuxGuestRunnerUpgradePolicy.evaluate(required: spaced, live: spaced),
            .current
        )
    }
}
