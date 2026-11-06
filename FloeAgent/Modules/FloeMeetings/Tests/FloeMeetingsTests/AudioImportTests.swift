// SPDX-License-Identifier: MPL-2.0
#if canImport(AVFoundation)
import AVFoundation
import FloeMeetings
import FloeMeetingsAV
import XCTest

final class AudioImportTests: XCTestCase {
    /// Write a tiny synthetic PCM file (no microphone, no permission).
    private func makeSyntheticWAV(seconds: Double = 1.0) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synthetic-\(UUID().uuidString).wav")
        let sampleRate: Double = 16_000
        let frameCount = Int(sampleRate * seconds)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        // A quiet sine keeps the file non-silent without any hardware.
        for frame in 0..<frameCount {
            buffer.floatChannelData?[0][frame] = Float(0.05 * sin(2 * .pi * 440 * Double(frame) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testProbeSyntheticAudioFile() async throws {
        let url = try makeSyntheticWAV(seconds: 1.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try await AudioFileProbe.probe(url)
        XCTAssertTrue(info.hasAudioTrack)
        XCTAssertEqual(info.duration.start, 0)
        XCTAssertGreaterThan(info.duration.end, 1.0)
        XCTAssertLessThan(abs(info.duration.end - 1.25), 0.1)
    }

    func testImportFileWithRealProbeEndToEnd() async throws {
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-meetings-tests-\(UUID().uuidString).sqlite")
        defer { TestServices.cleanup(dbURL) }
        let database = try MeetingDatabase(path: dbURL.path)
        let service = MeetingService(database: database)
        let meeting = try await service.createMeeting(title: "Imported")

        let audio = try makeSyntheticWAV(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let session = try await service.importFile(meeting: meeting, file: audio, kind: .importedAudio) { url in
            try await AudioFileProbe.durationRange(url)
        }
        let sessions = try await service.sessions(meeting: meeting)
        XCTAssertEqual(sessions.first?.id, session)
        XCTAssertEqual(sessions.first?.kind, .importedAudio)
        XCTAssertEqual(sessions.first?.durationSeconds ?? 0, 0.5, accuracy: 0.001)

        // A segment from file transcription references the imported file span.
        let range = try await AudioFileProbe.durationRange(audio)
        let segment = try await service.appendFinal(
            meeting: meeting, session: session, text: "imported transcript",
            range: MediaTimeRange(start: 0, end: min(2, range.end))
        )
        guard case .recording(let sourceSession, _) = segment.source else {
            XCTFail("expected recording source")
            return
        }
        XCTAssertEqual(sourceSession, session)
    }

    func testAVBackendFileURLIsDeterministic() throws {
        let session = CaptureSessionID()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let config = CaptureConfiguration(kind: .liveRecording, directory: directory, filePrefix: "standup")
        let url = try AVAudioRecorderCaptureBackend.makeFileURL(configuration: config, session: session)
        XCTAssertTrue(url.path.hasPrefix(directory.path))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("standup-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".m4a"))
    }

    func testFinalizedDurationUsesMediaFramesAndPrefixCannotEscapeDirectory() throws {
        let audio = try makeSyntheticWAV(seconds: 0.375)
        defer { try? FileManager.default.removeItem(at: audio) }
        let range = try AVAudioRecorderCaptureBackend.recordedRange(file: audio)
        XCTAssertEqual(range.duration, 0.375, accuracy: 0.001)
        XCTAssertThrowsError(try AVAudioRecorderCaptureBackend.makeFileURL(
            configuration: .init(directory: audio.deletingLastPathComponent(), filePrefix: "../outside"),
            session: CaptureSessionID()))
    }
}
#endif
