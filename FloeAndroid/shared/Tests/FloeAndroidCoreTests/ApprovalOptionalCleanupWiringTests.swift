// SPDX-License-Identifier: MPL-2.0
//
// n08 optional-cleanup corrective path: the narrow route fact must reach the
// ORIGINAL runtime configuration without changing the separate
// `localLinuxGuestEnvironment` deterministic-allow contract. The app-resolved
// target itself is produced by C02ExecutionTargetDomain; this fixture pins
// the builder/plumbing boundary only.
// AUTHORED, NOT EXECUTED — compilation and the unified test run stay with
// the primary coordinator.

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeAndroidCore

final class ApprovalOptionalCleanupWiringTests: XCTestCase {
    private let provider = ProviderProfile(
        kind: .openAI,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: "https://fixtures.invalid/v1")!
    )

    private var model: ModelProfile {
        ModelProfile(
            providerID: provider.id,
            remoteModelID: "optional-cleanup-wiring-fixture",
            displayName: "Optional Cleanup Wiring Fixture",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 256),
            capabilities: [.text]
        )
    }

    func testLocalLinuxShellRouteFactReachesTheRuntimeConfiguration() {
        let local = FacadeRunDomain.runtimeConfiguration(
            conversationID: UUID(),
            provider: provider,
            model: model,
            mode: .chat,
            ceiling: nil,
            toolsEnabled: true,
            temporary: false,
            environmentID: "env-local-linux",
            localLinuxShellTarget: true
        )
        XCTAssertTrue(local.localLinuxShellTarget)
        XCTAssertFalse(
            local.localLinuxGuestEnvironment,
            "the narrow corrective-path fact must not enable the separate deterministic local-guest allow carve-outs"
        )

        let remote = FacadeRunDomain.runtimeConfiguration(
            conversationID: UUID(),
            provider: provider,
            model: model,
            mode: .chat,
            ceiling: nil,
            toolsEnabled: true,
            temporary: false,
            environmentID: nil,
            localLinuxShellTarget: false
        )
        XCTAssertFalse(remote.localLinuxShellTarget)
        XCTAssertFalse(remote.localLinuxGuestEnvironment)
    }
}
