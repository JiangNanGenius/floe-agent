import Foundation
import Testing
@testable import FloeCore

@Suite("Bounded visual text recognition")
struct BoundedVisualTextRecognizerTests {
    @Test("Stalled OCR times out without queuing another worker")
    func timeoutAndBackpressure() async {
        let recognizer = BoundedVisualTextRecognizer()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let result = await recognizer.recognize(timeout: 0.05) {
            gate.wait()
            return []
        }
        #expect(result.status == .timedOut)
        let second = await recognizer.recognize { Issue.record("Must not launch another OCR worker"); return [] }
        #expect(second.status == .busy)
    }

    @Test("Recognition errors return unavailable rather than blocking screenshot delivery")
    func failure() async {
        let result = await BoundedVisualTextRecognizer().recognize {
            throw FloeError.validationFailed("Test OCR failure")
        }
        #expect(result.status == .unavailable)
        #expect(result.elements.isEmpty)
    }

    @Test("Successful OCR preserves structured text")
    func success() async {
        let region = VisualTextRegion(reference: "text-1", text: "Open", confidence: 1, x: 0, y: 0, width: 10, height: 10)
        let result = await BoundedVisualTextRecognizer().recognize { [region] }
        #expect(result.status == .available)
        #expect(result.elements == [region])
    }

    @Test("Cancellation returns even while synchronous OCR is still running")
    func cancellation() async {
        let recognizer = BoundedVisualTextRecognizer()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let work = Task {
            await recognizer.recognize {
                gate.wait()
                return []
            }
        }
        work.cancel()
        #expect(await work.value.status == .cancelled)
    }
}
