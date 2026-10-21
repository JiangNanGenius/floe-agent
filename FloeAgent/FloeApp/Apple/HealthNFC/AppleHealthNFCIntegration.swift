// FloeApp — HealthKit/NDEF registration.
//
// PRIMARY INTEGRATION (single AppEnvironment call; do not add another
// registry or a second NFC session owner):
//
//     registerAppleHealthNFCTools()
//
// Both services are app-lifetime objects owned by this registration helper.
// The settings capability switch remains the existing AppleCapability gate;
// an unsupported device/runtime removes the runner from discovery through
// `isAvailable`, so the model never sees an unusable capability.

#if canImport(UIKit) && canImport(HealthKit) && canImport(CoreNFC)
import Foundation
import FloeCore
import FloeTools

/// Process-wide service owners. Re-registering the tool catalog must reuse
/// the same NDEF gate, otherwise a second service instance could start a
/// second system session while the first is still visible.
enum AppleHealthNFCServices {
    static let health: any HealthDataProviding = HealthKitService()
    static let nfc: any NDEFReading = NDEFReaderService()
}

func registerAppleHealthNFCTools(
    registry: ToolRunnerRegistry = .shared,
    healthService: any HealthDataProviding = AppleHealthNFCServices.health,
    nfcReader: any NDEFReading = AppleHealthNFCServices.nfc,
    nfcAlertMessage: String = FloeL10n.l("apple.nfc.read.alert"),
    isForeground: @escaping @Sendable () async -> Bool = {
        await AppleHealthForeground.isActive()
    }
) {
    ToolCatalog.register(AppleHealthReadTool.self)
    var healthTool = AnyAgentTool(
        AppleHealthReadTool(
            service: healthService,
            isForeground: isForeground
        )
    )
    healthTool.isAvailable = { healthService.isAvailable }
    registry.register(healthTool)

    ToolCatalog.register(AppleNDEFReadTool.self)
    var nfcTool = AnyAgentTool(
        AppleNDEFReadTool(
            service: nfcReader,
            isForeground: isForeground,
            alertMessage: nfcAlertMessage
        )
    )
    nfcTool.isAvailable = { nfcReader.isAvailable }
    registry.register(nfcTool)
}
#endif
