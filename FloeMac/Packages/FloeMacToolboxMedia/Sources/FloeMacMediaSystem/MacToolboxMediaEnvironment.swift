import Foundation
import FloeMacMediaCore

/// App-wide media services. `leaseBroker` is the single arbiter shared by every
/// magnifier and scanner window, so two windows can never hold the camera at
/// once. Tests construct the pieces directly and never use this singleton.
@MainActor
public final class MacToolboxMediaEnvironment {
    public static let shared = MacToolboxMediaEnvironment()

    public let authorizer: MacSystemAuthorizer
    public let leaseBroker: MacDeviceLeaseBroker
    public let cameraRegistry: MacCameraRegistry
    public let audioProvider: MacAudioInputProvider
    public let soundOwner: MacSoundOwner
    public let scannerDraft: MacScannerDraftOwner
    public lazy var scannerCamera = MacScannerCameraOwner(environment: self)
    public let imageImporter: MacImageImportService
    public let exporter: MacExportSaver

    public init() {
        let authorizer = MacSystemAuthorizer()
        let leaseBroker = MacDeviceLeaseBroker()
        let audioProvider = MacAudioInputProvider()
        self.authorizer = authorizer
        self.leaseBroker = leaseBroker
        self.cameraRegistry = MacCameraRegistry()
        self.audioProvider = audioProvider
        self.soundOwner = MacSoundOwner(session: MacSoundSession(authorizer: authorizer, broker: leaseBroker, provider: audioProvider))
        self.scannerDraft = MacScannerDraftOwner()
        self.imageImporter = MacImageImportService()
        self.exporter = MacExportSaver()
    }

    public func makeSoundSession() -> MacSoundSession {
        soundOwner.session
    }

    public func makeCameraController() -> MacCameraController {
        let controller = MacCameraController(authorizer: authorizer, broker: leaseBroker)
        controller.attachRegistry(cameraRegistry)
        _ = cameraRegistry.register(controller)
        return controller
    }

    public func retireCamera(_ camera: MacCameraController) { cameraRegistry.retire(camera) }

    public func makeScanSession() -> MacScanSession {
        MacScanSession()
    }
}
