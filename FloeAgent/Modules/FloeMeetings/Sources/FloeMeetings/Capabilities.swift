// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Availability of a processing capability. Engines are injected; when no
/// engine is configured the state is explicitly `.unavailable` and the UI can
/// say so instead of pretending the feature works.
public enum CapabilityState: Hashable, Sendable, Codable {
    case available
    case degraded(note: String)
    case unavailable(reason: String)
}

/// Platform route for screen capture. iOS 27 exposes ScreenCaptureKit
/// (SCStream with audio output types and the system content-sharing picker);
/// iOS 26 relies on the ReplayKit broadcast-extension route. This module only
/// records the route decision — actual screen capture is owned by the host.
public enum ScreenCaptureRoute: Hashable, Sendable, Codable {
    case screenCaptureKit
    case replayKitBroadcastExtension
    case none(reason: String)
}

/// Typed capabilities advertised for a meeting. Filled by the host from the
/// engines it actually injects; never fabricated.
public struct MeetingProcessingCapabilities: Hashable, Sendable, Codable {
    public var transcription: CapabilityState
    public var speakerAttribution: CapabilityState
    /// Real-time bilingual stacked display (zh above / en below) readiness.
    public var bilingualStreaming: CapabilityState
    public var translation: CapabilityState
    public var summarization: CapabilityState
    public var screenCapture: CapabilityState
    public var screenCaptureRoute: ScreenCaptureRoute
    /// Background continuity is a system property. This core never claims it;
    /// hosts record the audited state here.
    public var backgroundContinuity: CapabilityState

    public init(
        transcription: CapabilityState = .unavailable(reason: "No transcription engine configured."),
        speakerAttribution: CapabilityState = .unavailable(reason: "No speaker engine configured."),
        bilingualStreaming: CapabilityState = .unavailable(reason: "No bilingual engine configured."),
        translation: CapabilityState = .unavailable(reason: "No translation engine configured."),
        summarization: CapabilityState = .unavailable(reason: "No summarization engine configured."),
        screenCapture: CapabilityState = .unavailable(reason: "No screen capture route configured."),
        screenCaptureRoute: ScreenCaptureRoute = .none(reason: "Not configured."),
        backgroundContinuity: CapabilityState = .unavailable(reason: "Background behavior is not claimed by this component; it requires a system-level audit.")
    ) {
        self.transcription = transcription
        self.speakerAttribution = speakerAttribution
        self.bilingualStreaming = bilingualStreaming
        self.translation = translation
        self.summarization = summarization
        self.screenCapture = screenCapture
        self.screenCaptureRoute = screenCaptureRoute
        self.backgroundContinuity = backgroundContinuity
    }

    /// All-unavailable baseline used until a host injects real engines.
    public static let unavailable = MeetingProcessingCapabilities()
}
