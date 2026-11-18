/// An app-owned camera remains retained until its own hardware stop is confirmed.
@MainActor
public protocol MacScannerCaptureOwning: AnyObject {
    func closeForWindow()
    func waitUntilStopped() async -> Bool
}

extension MacCameraController: MacScannerCaptureOwning {}
