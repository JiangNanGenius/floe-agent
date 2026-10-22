#if canImport(UIKit)
import XCTest
@testable import FloeApp

@MainActor
final class ChatAutomaticReadControllerTests: XCTestCase {
    @MainActor
    private final class Sink {
        var texts: [String] = []
        var finishes = 0
        var cancels = 0
        var handle: ChatReadAloudStream {
            ChatReadAloudStream(append: { self.texts.append($0) }, finish: { self.finishes += 1 }, cancel: { self.cancels += 1 })
        }
    }

    func testInitialHistorySilentAndNewFinalAnswerReadExactlyOnce() {
        let controller = ChatAutomaticReadController(), sink = Sink()
        let oldID = UUID(), oldRun = UUID(), newID = UUID(), newRun = UUID()
        controller.establishHistoryBaseline([oldID])
        controller.observeFinalMessages([(oldID, oldRun, "old answer")], enabled: true) { _ in sink.handle }
        XCTAssertTrue(sink.texts.isEmpty)
        controller.observeFinalMessages([(newID, newRun, "final body")], enabled: true) { _ in sink.handle }
        controller.observeFinalMessages([(newID, newRun, "final body")], enabled: true) { _ in sink.handle }
        XCTAssertEqual(sink.texts, ["final body"])
        XCTAssertEqual(sink.finishes, 1)
    }

    func testNavigationStopsAudioEvenAfterAllTextWasSubmitted() {
        let controller = ChatAutomaticReadController(), sink = Sink()
        controller.establishHistoryBaseline([])
        controller.observeFinalMessages([(UUID(), UUID(), "answer")], enabled: true) { _ in sink.handle }
        XCTAssertEqual(sink.finishes, 1)
        controller.cancel()
        XCTAssertEqual(sink.cancels, 1)
    }

    func testEnablingAutoplayDoesNotReadAnAnswerCompletedWhileDisabled() {
        let controller = ChatAutomaticReadController(), sink = Sink()
        let answer = (UUID(), Optional(UUID()), "finished while off")
        controller.establishHistoryBaseline([])
        controller.observeFinalMessages([answer], enabled: false) { _ in sink.handle }
        controller.observeFinalMessages([answer], enabled: true) { _ in sink.handle }
        XCTAssertTrue(sink.texts.isEmpty)
    }
}
#endif
