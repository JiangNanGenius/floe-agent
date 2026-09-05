import Foundation
import Testing
@testable import FloeExecution

@Suite("FloeExecution.MailDeliveryJournal")
struct MailDeliveryJournalTests {
    private let digest = String(repeating: "a", count: 64)
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("floe-mail-journal-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @Test func crashRecoveryNeverAuthorizesReplay() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        #expect(try MailDeliveryJournal(directory: root).reserve(requestID: id, digest: digest) == nil)
        #expect(try MailDeliveryJournal(directory: root).reserve(requestID: id, digest: digest) == .deliveryUnknown)
    }
    @Test func completedAndNotSubmittedRemainReceipts() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = MailDeliveryJournal(directory: root)
        for state in [MailDeliveryJournal.State.acceptedByServer, .notSubmitted] {
            let id = UUID(); _ = try journal.reserve(requestID: id, digest: digest)
            try journal.finish(requestID: id, digest: digest, state: state)
            #expect(try journal.reserve(requestID: id, digest: digest) == state)
            #expect(throws: MailFailure.invalidMessage) { try journal.reserve(requestID: id, digest: String(repeating: "b", count: 64)) }
        }
    }
    @Test func corruptReceiptIsNotOverwritten() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); let file = root.appendingPathComponent(id.uuidString + ".json")
        let original = Data("partial".utf8); try original.write(to: file)
        #expect(throws: MailFailure.invalidMessage) { try MailDeliveryJournal(directory: root).reserve(requestID: id, digest: digest) }
        #expect(try Data(contentsOf: file) == original)
    }
    @Test func concurrentAdmissionHasExactlyOneFirstAttempt() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = MailDeliveryJournal(directory: root); let id = UUID()
        let firstAttempts = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { try journal.reserve(requestID: id, digest: digest) == nil } }
            var count = 0; for try await first in group { if first { count += 1 } }; return count
        }
        #expect(firstAttempts == 1)
    }
}
