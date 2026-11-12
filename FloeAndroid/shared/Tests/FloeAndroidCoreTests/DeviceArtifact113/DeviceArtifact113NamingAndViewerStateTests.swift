// SPDX-License-Identifier: MPL-2.0
//
// post112 device-artifact source regressions:
//  * the model-visible artifact handoff text uses canonical device* recovery
//    codes and never advertises a legacy phone.* tool spelling;
//  * the mailbox keeps exact legacy `phone_*` failure codes readable while
//    exposing only canonical `device_*` codes to new model-visible errors;
//  * `viewerState` is described as a bounded foreground read that is not
//    proof of playback/import completion.
//
// AUTHORED, NOT EXECUTED. Compilation and execution stay with the primary.
import XCTest
@testable import FloeAndroidCore

final class DeviceArtifact113NamingAndViewerStateTests: XCTestCase {

    func testArtifactHandoffDescriptionUsesCanonicalDeviceCopy() {
        let text = G04ArtifactHandoffTool.toolDescription
        XCTAssertTrue(text.contains("device.observe"))
        XCTAssertTrue(text.contains("deviceArmRequired"))
        XCTAssertTrue(text.contains("viewerState"))
        XCTAssertTrue(text.contains("launchState=accepted"))
        XCTAssertFalse(text.contains("phoneArmRequired"))
        XCTAssertFalse(text.contains("Phone authorization"))
        XCTAssertFalse(text.contains("phone.observe"))
        XCTAssertFalse(text.contains("phone.act"))
        XCTAssertFalse(text.contains("phone.screenshot"))
        // The description must not upgrade an accepted start into a rendered
        // viewer or a completed save.
        XCTAssertTrue(text.contains("NOT proof"))
        XCTAssertTrue(text.contains("saved"))
        XCTAssertTrue(text.contains("completed"))
    }

    func testLegacyFailureCodeNormalizationIsClosedAndCanonical() {
        XCTAssertEqual("device_presence_required",
                       PlatformDeviceWireCode.canonical("phone_presence_required"))
        XCTAssertEqual("device_paused_by_user",
                       PlatformDeviceWireCode.canonical("phone_paused_by_user"))
        XCTAssertEqual("device_observation_required",
                       PlatformDeviceWireCode.canonical("phone_observation_required"))
        XCTAssertEqual("device_launch_target_unavailable",
                       PlatformDeviceWireCode.canonical("phone_launch_target_unavailable"))
        // Already-canonical and unrelated codes are unchanged.
        XCTAssertEqual("device_timeout", PlatformDeviceWireCode.canonical("device_timeout"))
        XCTAssertEqual("device_run_unavailable",
                       PlatformDeviceWireCode.canonical("device_run_unavailable"))
        XCTAssertEqual("workspace_owner_unavailable",
                       PlatformDeviceWireCode.canonical("workspace_owner_unavailable"))
        XCTAssertEqual("internal", PlatformDeviceWireCode.canonical("internal"))
    }

    func testPausePromptAcceptsCanonicalAndLegacySpellings() {
        for canonical in ["device_presence_required", "device_unlock_required",
                          "device_unlock_needs_user", "device_paused_by_user"] {
            XCTAssertTrue(PlatformDeviceWireCode.isPausePrompt(canonical), canonical)
        }
        for legacy in ["phone_presence_required", "phone_unlock_required",
                       "phone_unlock_needs_user", "phone_paused_by_user"] {
            XCTAssertTrue(PlatformDeviceWireCode.isPausePrompt(
                PlatformDeviceWireCode.canonical(legacy)), legacy)
        }
        XCTAssertFalse(PlatformDeviceWireCode.isPausePrompt("device_timeout"))
        XCTAssertFalse(PlatformDeviceWireCode.isPausePrompt("phone_timeout"))
    }
}
