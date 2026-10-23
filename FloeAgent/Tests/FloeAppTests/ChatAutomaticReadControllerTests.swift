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

    func testPlaybackIsOwnedByFinalMessageRatherThanRun() {
        let controller = ChatAutomaticReadController(), sink = Sink()
        let messageID = UUID(), runID = UUID()
        controller.establishHistoryBaseline([])
        var playbackOwner: UUID?
        controller.observeFinalMessages([(messageID, runID, "final body")], enabled: true) { owner in
            playbackOwner = owner
            return sink.handle
        }
        XCTAssertEqual(playbackOwner, messageID)
        XCTAssertNotEqual(playbackOwner, runID)
    }

    func testLateHistoricalEventHydrationDoesNotAutoplay() {
        let controller = ChatAutomaticReadController(), sink = Sink()
        let oldRun = UUID(), oldMessage = UUID(), lateEvent = UUID(), newRun = UUID()
        controller.establishHistoryBaseline([oldMessage], completedRunIDs: [oldRun])
        // The final event UUID was absent from the first message page.
        controller.observeFinalMessages([(lateEvent, oldRun, "historical answer")], enabled: true) { _ in sink.handle }
        XCTAssertTrue(sink.texts.isEmpty)
        // Later refreshes must not classify a newly completed run as history.
        controller.establishHistoryBaseline([UUID()], completedRunIDs: [oldRun, newRun])
        controller.observeFinalMessages([(UUID(), newRun, "new answer")], enabled: true) { _ in sink.handle }
        XCTAssertEqual(sink.texts, ["new answer"])
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
