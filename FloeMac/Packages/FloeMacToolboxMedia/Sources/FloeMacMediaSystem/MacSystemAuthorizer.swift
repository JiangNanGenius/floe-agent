import Foundation
import AVFoundation
import FloeMacMediaCore

/// AVFoundation-backed authorization. No prompt is shown until
/// `requestAuthorization` is called, which the UI does only from an explicit
/// Start action. The type is stateless apart from AVFoundation's own TCC state,
/// so it is safe to share across windows.
public final class MacSystemAuthorizer: MacMediaAuthorizing, @unchecked Sendable {
    public init() {}

    public func authorization(for kind: MacMediaKind) -> MacMediaAuthorization {
        Self.map(AVCaptureDevice.authorizationStatus(for: Self.mediaType(kind)))
    }

    public func requestAuthorization(for kind: MacMediaKind) async -> MacMediaAuthorization {
        let current = authorization(for: kind)
        guard current.canRequest else { return current }
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: Self.mediaType(kind)) { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .authorized : .denied
    }

    private static func mediaType(_ kind: MacMediaKind) -> AVMediaType {
        switch kind {
        case .microphone: .audio
        case .camera: .video
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> MacMediaAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}
