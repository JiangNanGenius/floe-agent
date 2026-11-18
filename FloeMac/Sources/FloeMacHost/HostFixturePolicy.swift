// SPDX-License-Identifier: MPL-2.0
// Isolated hosts must not start either toolbox services or a UI session.

enum HostFixturePolicy {
    static let isolatedEnvironmentKeys = [
        "XCTestConfigurationFilePath", "XCTestBundlePath",
        "CFFIXED_USER_HOME", "FLOE_M00_REAL_HOME_DIR",
        "FLOE_MAC_MODE_ROOT", "FLOE_MAC_BRIDGE_CONTROL_ROOT",
        "FLOE_MAC_BRIDGE_SERVICE_PATH", "FLOE_MAC_AGENT_UI_PATH"
    ]

    static func isIsolatedEnvironment(_ environment: [String: String]) -> Bool {
        isolatedEnvironmentKeys.contains { !(environment[$0] ?? "").isEmpty }
    }
}
