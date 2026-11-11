import Foundation
import XCTest
@testable import FloeExecution

final class LinuxGuestImageDeviceCapabilitiesTests: XCTestCase {
    func testOlderManifestKeepsOptionalDevicesDisabled() throws {
        let original = LinuxGuestImage(id: "older", biosPath: "firmware.fd")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "deviceCapabilities")
        let decoded = try JSONDecoder().decode(LinuxGuestImage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.deviceCapabilities)
        XCTAssertFalse(decoded.deviceCapabilities?.onlineMemory == true)
        XCTAssertFalse(decoded.deviceCapabilities?.vulkanGPU == true)
        XCTAssertFalse(decoded.deviceCapabilities?.localDisplay == true)
    }

    func testCapabilitiesRemainIndependentAcrossManifestRoundTrip() throws {
        let original = LinuxGuestImage(id: "compute", biosPath: "firmware.fd",
            deviceCapabilities: .init(onlineMemory: true, vulkanGPU: true, localDisplay: false))
        let decoded = try JSONDecoder().decode(LinuxGuestImage.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.deviceCapabilities?.localDisplay, false)
        let partial = try JSONDecoder().decode(LinuxGuestImageDeviceCapabilities.self,
            from: Data(#"{"vulkanGPU":true}"#.utf8))
        XCTAssertTrue(partial.vulkanGPU == true)
        XCTAssertNil(partial.onlineMemory)
        XCTAssertNil(partial.localDisplay)
    }
}
