import Testing
@testable import FloeCore

@Suite("Local bridge platform isolation")
struct LocalBridgePlatformTests {
    @Test("A phone, iPad or simulator cannot enable the Mac backend")
    func macExecutionRequiresActualMac() {
        for platform in [LocalBridgePlatform.iOSDevice, .iOSSimulator, .unsupported] {
            #expect(!platform.supportsMacBridge)
        }
        for platform in [LocalBridgePlatform.nativeMac, .macCatalyst, .iOSAppOnMac] {
            #expect(platform.supportsMacBridge)
            #expect(!platform.supportsIOSAutomation)
        }
    }

    @Test("Companion automation belongs to a physical local iOS device")
    func automationRequiresActualIOSDevice() {
        #expect(LocalBridgePlatform.iOSDevice.supportsIOSAutomation)
        for platform in LocalBridgePlatform.allCases where platform != .iOSDevice {
            #expect(!platform.supportsIOSAutomation)
        }
    }
}
