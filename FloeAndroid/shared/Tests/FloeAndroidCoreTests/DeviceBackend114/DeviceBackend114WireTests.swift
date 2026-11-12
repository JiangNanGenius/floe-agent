// SPDX-License-Identifier: MPL-2.0
//
// v4 ADB structured-UI backend regressions:
//  * the model-visible device failure family stays canonical and readable;
//  * an ADB-unavailable reason is a device_* code, never a phone.* surface;
//  * the one public device namespace is unchanged.
//
// AUTHORED, NOT EXECUTED. Compilation and execution stay with the primary.
import XCTest
@testable import FloeAndroidCore

final class DeviceBackend114WireTests: XCTestCase {

    func testStructuredUiFailureCodesAreCanonicalDeviceCodes() {
        XCTAssertEqual("device_structured_ui_not_ready",
                       PlatformDeviceWireCode.canonical("device_structured_ui_not_ready"))
        XCTAssertEqual("device_observation_required",
                       PlatformDeviceWireCode.canonical("phone_observation_required"))
        XCTAssertEqual("device_stale_observation",
                       PlatformDeviceWireCode.canonical("device_stale_observation"))
        XCTAssertEqual("device_window_screenshot_unsupported",
                       PlatformDeviceWireCode.canonical("phone_window_screenshot_unsupported"))
        XCTAssertFalse(PlatformDeviceWireCode.canonical("device_structured_ui_not_ready")
            .hasPrefix("phone_"))
    }

    func testLegacyStructuredUiSpellingStillMapsToTheDeviceFamily() {
        XCTAssertEqual("device_structured_ui_not_ready",
                       PlatformDeviceWireCode.canonical("phone_structured_ui_not_ready"))
        XCTAssertEqual("device_ui_automation_unavailable",
                       PlatformDeviceWireCode.canonical("phone_ui_automation_unavailable"))
    }

    func testDeviceInteractionSurfaceIsExactlyTheThreePublicNames() {
        // This is the existing public contract; the v4 backend adds no
        // competing adb.*/phone.* model surface.
        let names = ["device.observe", "device.act", "device.screenshot"]
        XCTAssertEqual(Set(names).count, 3)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("device.") })
        XCTAssertFalse(names.contains { $0.hasPrefix("adb.") || $0.hasPrefix("phone.") })
    }
}
