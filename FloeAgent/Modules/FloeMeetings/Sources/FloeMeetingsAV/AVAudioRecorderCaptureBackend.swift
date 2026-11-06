// SPDX-License-Identifier: MPL-2.0
#if canImport(AVFoundation)
import AVFoundation
import FloeMeetings
import Foundation

/// AVAudioRecorder-backed capture backend. The host App owns the audio
/// session and microphone permission; this backend only writes audio to the
/// configured directory. This component never requests permission itself and
/// is not evidence of background availability.
public actor AVAudioRecorderCaptureBackend: MeetingCaptureBackend {
    private let settings: [String: Any]
    private var recorder: AVAudioRecorder?
    private var sink: (@Sendable (CaptureEvent) -> Void)?
    private var session: CaptureSessionID?

    /// 24 kHz mono PCM-ish (Apple Lossless) keeps files local and editable.
    public init(settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatAppleLossless),
        AVSampleRateKey: 24_000,
        AVNumberOfChannelsKey: 1
    ]) {
        self.settings = settings
    }

    public func begin(
        session: CaptureSessionID,
        configuration: CaptureConfiguration,
        sink: @escaping @Sendable (CaptureEvent) -> Void
    ) async throws {
        if let existing = self.session { throw MeetingError.captureAlreadyActive(existing) }
        self.sink = sink
        self.session = session
        let file = try Self.makeFileURL(configuration: configuration, session: session)
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        do {
            recorder = try AVAudioRecorder(url: file, settings: settings)
        } catch {
            self.session = nil
            self.sink = nil
            throw MeetingError.captureBackendFailed(String(describing: error))
        }
        guard recorder?.record() == true else {
            recorder = nil
            self.session = nil
            self.sink = nil
            throw MeetingError.captureBackendFailed("AVAudioRecorder did not start.")
        }
        sink(.started(session: session))
    }

    public func requestStop() async {
        guard let recorder, let session else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        do {
            let range = try Self.recordedRange(file: url)
            sink?(.chunkFinalized(session: session, file: url, range: range))
            sink?(.stopped(session: session, reason: .userStopped))
        } catch {
            sink?(.failed(session: session, message: String(describing: error)))
        }
        self.session = nil
        sink = nil
    }

    public func cancel() async {
        recorder?.stop()
        recorder = nil
        if let session {
            sink?(.cancelled(session: session))
        }
        session = nil
        sink = nil
    }

    /// The recorder's media clock, used for explicit user bookmarks.
    public func currentTime() -> Double? { recorder?.currentTime }

    /// Deterministic per-session file layout, verified without hardware.
    public static func makeFileURL(configuration: CaptureConfiguration, session: CaptureSessionID) throws -> URL {
        let prefix = configuration.filePrefix
        guard !prefix.isEmpty, !prefix.contains("/"), !prefix.contains("\\"), !prefix.contains("\0") else {
            throw MeetingError.captureBackendFailed("Invalid recording filename.")
        }
        return configuration.directory.appendingPathComponent("\(prefix)-\(session.description).m4a")
    }

    /// Measure finalized media frames rather than inventing a time span.
    public static func recordedRange(file: URL) throws -> MediaTimeRange {
        let audio = try AVAudioFile(forReading: file)
        return try MediaTimeRange(start: 0, end: Double(audio.length) / audio.processingFormat.sampleRate)
    }
}
#endif
