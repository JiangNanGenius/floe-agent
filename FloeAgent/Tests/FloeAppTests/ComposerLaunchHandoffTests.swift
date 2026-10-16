#if canImport(UIKit)
import Foundation
import Combine
import Testing
import FloeModels
@testable import FloeApp

@MainActor private final class ControlledLaunchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitingObserver: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            waitingObserver?.resume(); waitingObserver = nil
        }
    }
    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { waitingObserver = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Composer launch handoff")
@MainActor struct ComposerLaunchHandoffTests {
    private func store() -> (ComposerDraftStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID()).json")
        return (ComposerDraftStore(fileURL: url), url)
    }

    @Test("A suspended launch hides sent text from rebuilt editors while disk recovery stays intact")
    func suspendedLaunch() async {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID(), gate = ControlledLaunchGate()
        let sent = "待启动的长问题"
        store.save(text: sent, conversationID: id)
        let commit = ComposerSendCommit(draft: sent, attachments: [], editorGeneration: 1, conversationID: id, store: store)
        let launch = Task { @MainActor in
            commit.beginLaunch(store: store)
            await gate.wait()
            commit.acceptLaunch(store: store)
        }
        await gate.waitUntilSuspended()
        #expect(store.entry(for: id)?.text == "")
        #expect(store.text(for: id).isEmpty)
        #expect(store.flushAndWait())
        let afterProcessDeath = ComposerDraftStore(fileURL: url)
        #expect(afterProcessDeath.text(for: id) == sent)
        gate.open(); await launch.value
        #expect(store.text(for: id).isEmpty)
        #expect(store.flushAndWait())
        #expect(ComposerDraftStore(fileURL: url).text(for: id).isEmpty)
    }

    @Test("Failed launch restores only the unedited generation and notifies the rebuilt editor")
    func failedLaunchRecovery() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        store.save(text: "original", conversationID: id)
        let commit = ComposerSendCommit(draft: "original", attachments: [], editorGeneration: 1, conversationID: id, store: store)
        commit.beginLaunch(store: store)
        var rebuilt = store.text(for: id)
        let subscription = store.$sendHandoffUpdate.dropFirst().sink { update in
            guard let update, update.conversationID == id else { return }
            rebuilt = update.entry?.text ?? ""
        }
        #expect(rebuilt.isEmpty)
        #expect(commit.failLaunch(allowTextRecovery: true, store: store))
        #expect(rebuilt == "original")
        #expect(store.text(for: id) == "original")
        withExtendedLifetime(subscription) {}
    }

    @Test("New A→B→A, exact retyped sent text, and typing then clearing all beat stale launch outcomes")
    func editedGenerationWins() {
        for edits in [["original"], ["A", "B", "A"], ["new", ""]] {
            for accepted in [true, false] {
                let (store, url) = store()
                defer { try? FileManager.default.removeItem(at: url) }
                let id = UUID()
                store.save(text: "original", conversationID: id)
                let commit = ComposerSendCommit(draft: "original", attachments: [], editorGeneration: 1, conversationID: id, store: store)
                commit.beginLaunch(store: store)
                for text in edits { store.save(text: text, conversationID: id) }
                if accepted { commit.acceptLaunch(store: store) }
                else { #expect(!commit.failLaunch(allowTextRecovery: true, store: store)) }
                #expect(store.text(for: id) == edits.last)
            }
        }
    }

    @Test("Attachment-only edits do not restore sent chips and survive acceptance or launch failure")
    func attachmentIsolation() {
        for accepted in [true, false] {
            let (store, url) = store()
            defer { try? FileManager.default.removeItem(at: url) }
            let id = UUID()
            let sent = AttachmentRef(kind: .document, displayName: "sent", uti: "public.data")
            let added = AttachmentRef(kind: .document, displayName: "new", uti: "public.data")
            store.save(text: "original", attachments: [sent], conversationID: id)
            let commit = ComposerSendCommit(draft: "original", attachments: [sent], editorGeneration: 1, conversationID: id, store: store)
            commit.beginLaunch(store: store)
            store.save(text: "", attachments: [added], conversationID: id)
            #expect(store.attachments(for: id).map(\.id) == [added.id])
            if accepted { commit.acceptLaunch(store: store) }
            else { #expect(commit.failLaunch(allowTextRecovery: true, store: store)) }
            #expect(store.attachments(for: id).contains { $0.id == added.id })
            #expect(store.attachments(for: id).contains { $0.id == sent.id } == !accepted)
        }
    }

    @Test("Destroying a temporary session fences every late launch callback")
    func destroyedTemporary() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        store.setTemporaryDraftExcluded(id, true)
        store.save(text: "private", conversationID: id)
        let commit = ComposerSendCommit(draft: "private", attachments: [], editorGeneration: 1, conversationID: id, store: store)
        commit.beginLaunch(store: store)
        store.setTemporaryDraftExcluded(id, false); store.clear(conversationID: id)
        #expect(!commit.failLaunch(allowTextRecovery: true, store: store))
        commit.acceptLaunch(store: store)
        #expect(store.entry(for: id) == nil)
        #expect(store.sendHandoffUpdate == nil)
        #expect(store.flushAndWait())
        #expect(ComposerDraftStore(fileURL: url).entry(for: id) == nil)
    }
}
#endif
