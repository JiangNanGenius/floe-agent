// FloeAppTests — regressions for the two production 1.2.0 crashes and
// redacted feedback request construction.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import Testing
@testable import FloeApp

@Suite("FloeApp crash and feedback regressions")
struct CrashAndFeedbackRegressionTests {
    @Test("Continued processing submits a concrete registered identifier")
    func continuedIdentifierIsConcrete() {
        let identifier = BackgroundTaskKind.continued.submissionIdentifier
        #expect(identifier.hasPrefix("org.floeagent.ios.continued."))
        #expect(!identifier.contains("*"))
        #expect(identifier != BackgroundTaskKind.continued.rawValue)
    }

    @Test("Empty audio buffers are rejected before Speech Analyzer")
    func emptyAudioBufferIsRejected() throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        #expect(empty.frameLength == 0)
        #expect(!VoiceBufferValidator.isUsable(empty))

        empty.frameLength = 1
        #expect(VoiceBufferValidator.isUsable(empty))
    }

    @Test("Feedback request includes the problem and redacts diagnostics")
    func feedbackRequestIsRedacted() throws {
        let secret = ["sk", "live1234567890abcdef"].joined(separator: "-")
        let request = try FeedbackUploadService.makeRequest(
            FeedbackSubmission(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                problem: "Voice button crashes with key \(secret)",
                diagnostics: "authorization: Bearer eyJhbGciOiJ9.payload"
            ),
            boundary: "TestBoundary"
        )

        #expect(request.url == FeedbackUploadService.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type")
            == "multipart/form-data; boundary=TestBoundary")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("name=\"manifest\""))
        #expect(body.contains("Voice button crashes"))
        #expect(body.contains("diagnostics-11111111-2222-3333-4444-555555555555-0"))
        #expect(body.contains("⟨redacted⟩"))
        #expect(!body.contains(secret))
        #expect(!body.contains("eyJhbGciOiJ9.payload"))
    }

    @Test("Feedback images are bounded multipart attachments")
    func feedbackImagesAreMultipartAttachments() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let attachment = FeedbackImageAttachment(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            filename: "screen\r\nshot.jpg",
            data: jpeg
        )
        let request = try FeedbackUploadService.makeRequest(
            FeedbackSubmission(
                problem: "The model request failed",
                diagnostics: "provider error",
                imageAttachments: [attachment]
            ),
            boundary: "ImageBoundary"
        )
        let body = try #require(request.httpBody)
        let headers = String(decoding: body, as: UTF8.self)

        #expect(headers.contains("name=\"attachments\""))
        #expect(headers.contains("filename=\"screen__shot.jpg\""))
        #expect(headers.contains("Content-Type: image/jpeg"))
        #expect(headers.contains("X-Floe-Attachment-ID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(body.range(of: jpeg) != nil)
        #expect(headers.contains("\"image_attachment_count\":\"1\""))
    }

    @Test("Feedback rejects more than three images")
    func feedbackRejectsTooManyImages() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let attachments = (0..<4).map {
            FeedbackImageAttachment(filename: "image-\($0).jpg", data: jpeg)
        }
        #expect(throws: FeedbackUploadError.tooManyImages) {
            _ = try FeedbackUploadService.makeRequest(
                FeedbackSubmission(
                    problem: "Too many screenshots",
                    diagnostics: nil,
                    imageAttachments: attachments
                ),
                boundary: "ImageBoundary"
            )
        }
    }

    @Test("Feedback requires a user-written problem")
    func feedbackRequiresProblem() {
        #expect(throws: FeedbackUploadError.emptyProblem) {
            _ = try FeedbackUploadService.makeRequest(
                FeedbackSubmission(problem: "   ", diagnostics: nil),
                boundary: "TestBoundary"
            )
        }
    }

    @Test("Feedback success requires a server-issued report ID")
    func feedbackReceiptContract() {
        #expect(FeedbackUploadService.reportID(
            from: Data(#"{"report_id":"report-123"}"#.utf8)
        ) == "report-123")
        #expect(FeedbackUploadService.reportID(
            from: Data(#"{"accepted":[]}"#.utf8)
        ) == nil)
    }
}
#endif
