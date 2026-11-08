// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import SwiftUI
import UIKit
import WebKit
import AVFoundation
import FloeCore
import FloeModels
import FloeTools
import FloeExecution
import FloePersistence
import FloeMarkdown
@testable import FloeApp

@Suite("Inline-content paging and native audio", .serialized)
@MainActor
struct ChatInlineContentPagingTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InlinePaging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func strings(_ value: [String: Any]) throws -> [String] {
        try #require(value["contents"] as? [[String: String]]).compactMap { $0["inlineMarkdown"] }
    }
    private func append(_ artifacts: [ToolArtifactReference], run: UUID, tool: String,
                        store: any RunStore) async throws {
        let payload = ["id": "actual-producer", "tool": tool, "status": "ok",
                       "artifactRefsJSON": String(decoding: try JSONEncoder().encode(artifacts), as: UTF8.self)]
        _ = try await store.appendEvent(runID: run, kind: .toolResult,
            payloadJSON: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
    }

    @Test func sqliteCursorReopensAcrossOldRunsAndOldAttachments() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite"), db = try DatabaseManager(path: root.appendingPathComponent("history.sqlite"))
        try await db.migrate()
        let conversations = SQLiteConversationStore(database: db), runs = SQLiteRunStore(database: db)
        let task = UUID(), foreign = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        for id in [task, foreign] { try await conversations.saveConversation(.init(id: id, title: "Paging fixture", createdAt: date, updatedAt: date)) }
        let native = PresentationArtifactTool(rootURLProvider: { root })
        var expected: Set<String> = []
        for index in 0..<26 {
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            try await runs.saveRun(.init(id: id, conversationID: task, state: "completed", goal: "native result", startedAt: date))
            if [0, 11, 25].contains(index) {
                let output = try await native.execute(.init(kind: .table, title: "Saved \(index)", columns: ["n"], rows: [["\(index)"]]),
                    context: .init(runID: id, toolCallID: "actual-producer", cancellation: CancellationToken(), conversationID: task))
                try await append(output.artifacts, run: id, tool: PresentationArtifactTool.name, store: runs)
                let artifact = try #require(output.artifacts.first)
                expected.insert(ChatContentReference(kind: .artifact, ownerID: id, contentID: artifact.id.uuidString)!.uri)
            }
        }
        let attachment = AttachmentRef(conversationID: task, kind: .document, displayName: "old.txt", uti: "public.plain-text",
            byteCount: 3, sha256: FloeDigest.sha256Hex(Data("old".utf8)), storage: .applicationSupport,
            relativePath: "Attachments/old.txt")
        try await conversations.saveAttachment(attachment)
        let foreignAttachment = AttachmentRef(conversationID: foreign, kind: .document, displayName: "foreign.txt", uti: "public.plain-text")
        try await conversations.saveAttachment(foreignAttachment)
        for index in 0..<105 {
            let id = UUID(uuidString: String(format: "11111111-0000-0000-0000-%012d", index + 1))!
            var parts: [MessagePart] = []
            if index == 0 {
                parts = (0..<12).map { .init(messageID: id, partIndex: $0, kind: .text, text: "Saved paragraph \($0)") }
                parts += [
                    .init(messageID: id, partIndex: 12, kind: .file, attachmentID: attachment.id),
                    .init(messageID: id, partIndex: 13, kind: .file, attachmentID: attachment.id),
                    .init(messageID: id, partIndex: 14, kind: .file, attachmentID: foreignAttachment.id)]
            }
            try await conversations.appendMessage(.init(id: id, conversationID: task, role: "user", content: "saved", createdAt: date, parts: parts))
            if index == 0 { expected.insert(ChatContentReference(kind: .attachment, ownerID: id, contentID: attachment.id.uuidString)!.uri) }
        }
        var cursor: String?, delivered: [String] = [], finished = false, emptyContinuationPages = 0
        for _ in 0..<150 {
            // Persist the token, reopen real SQLite services, then continue.
            if let cursor { try Data(cursor.utf8).write(to: root.appendingPathComponent("cursor")) }
            let reopened = try DatabaseManager(path: url)
            let token = cursor == nil ? nil : String(decoding: try Data(contentsOf: root.appendingPathComponent("cursor")), as: UTF8.self)
            let page = try object(try await ChatInlineContentIndex.page(taskID: task, cursor: token, limit: 2, scanLimit: 7,
                conversations: SQLiteConversationStore(database: reopened), runs: SQLiteRunStore(database: reopened)))
            let values = try strings(page)
            for value in values {
                let block = try #require(InlineContentBlockParser.parse(value).first)
                guard case .reference(_, let uri) = block.content else { throw FloeError.validationFailed("Listing returned an incomplete reference") }
                delivered.append(try #require(ChatContentReference(uri)).uri)
            }
            guard page["hasMore"] as? Bool == true else { finished = true; break }
            if values.isEmpty { emptyContinuationPages += 1 }
            let next = try #require(page["nextCursor"] as? String); #expect(next != cursor); cursor = next
        }
        #expect(finished && emptyContinuationPages > 0)
        #expect(Set(delivered) == expected && delivered.count == expected.count)
    }

    @Test func byteBudgetResumesTheUnreturnedAttachmentAndCursorsCannotAdoptAnotherTask() async throws {
        let db = try DatabaseManager.inMemory(); try await db.migrate()
        let conversations = SQLiteConversationStore(database: db), runs = SQLiteRunStore(database: db)
        let task = UUID(), other = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000), message = UUID()
        for id in [task, other] { try await conversations.saveConversation(.init(id: id, title: "Budget fixture", createdAt: date, updatedAt: date)) }
        // attachments.message_id references the saved parent. Parts are added
        // below after their referenced attachment rows have also been saved.
        try await conversations.appendMessage(.init(id: message, conversationID: task, role: "user", content: "files", createdAt: date))
        var parts: [MessagePart] = [], expected: Set<String> = []
        for index in 0..<20 {
            let attachment = AttachmentRef(conversationID: task, messageID: message, kind: .document,
                displayName: String(repeating: "文件", count: 25) + "\(index).txt", uti: "public.plain-text")
            try await conversations.saveAttachment(attachment)
            parts.append(.init(messageID: message, partIndex: index, kind: .file, attachmentID: attachment.id))
            expected.insert(ChatContentReference(kind: .attachment, ownerID: message, contentID: attachment.id.uuidString)!.markdown(title: attachment.displayName))
        }
        try await conversations.appendMessage(.init(id: message, conversationID: task, role: "user", content: "files", createdAt: date, parts: parts))
        let firstBytes = try await ChatInlineContentIndex.page(taskID: task, limit: 64, conversations: conversations, runs: runs, maximumBytes: 4_096)
        let first = try object(firstBytes), initial = try strings(first), token = try #require(first["nextCursor"] as? String)
        #expect(!initial.isEmpty && initial.count < 20 && firstBytes.count <= 4_096)
        #expect(first["truncated"] as? Bool == false)
        await #expect(throws: (any Error).self) {
            _ = try await ChatInlineContentIndex.page(taskID: other, cursor: token, conversations: conversations, runs: runs)
        }
        // A forged task field still cannot adopt the pinned foreign message.
        var b64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        var forged = try object(try #require(Data(base64Encoded: b64))); forged["task"] = other.uuidString
        let forgedToken = try JSONSerialization.data(withJSONObject: forged).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        await #expect(throws: (any Error).self) {
            _ = try await ChatInlineContentIndex.page(taskID: other, cursor: forgedToken, conversations: conversations, runs: runs)
        }
        var delivered = initial, cursor: String? = token, done = false
        for _ in 0..<30 {
            let bytes = try await ChatInlineContentIndex.page(taskID: task, cursor: cursor, limit: 64,
                conversations: conversations, runs: runs, maximumBytes: 4_096)
            #expect(bytes.count <= 4_096)
            let page = try object(bytes); delivered += try strings(page)
            guard page["hasMore"] as? Bool == true else { done = true; break }
            cursor = try #require(page["nextCursor"] as? String)
        }
        #expect(done && Set(delivered) == expected && delivered.count == expected.count)
    }

    @Test func selectedRunFreezesTheEventUpperBound() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let db = try DatabaseManager.inMemory(); try await db.migrate()
        let conversations = SQLiteConversationStore(database: db), runs = SQLiteRunStore(database: db)
        let task = UUID(), run = UUID()
        try await conversations.saveConversation(.init(id: task, title: "Upper bound", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: run, conversationID: task, state: "running", goal: "list", startedAt: Date()))
        let native = PresentationArtifactTool(rootURLProvider: { root })
        let output = try await native.execute(.init(kind: .table, columns: ["n"], rows: [["1"]]),
            context: .init(runID: run, toolCallID: "actual-producer", cancellation: CancellationToken(), conversationID: task))
        try await append(output.artifacts, run: run, tool: PresentationArtifactTool.name, store: runs)
        let first = try object(try await ChatInlineContentIndex.page(taskID: task, runID: run, limit: 1,
            conversations: conversations, runs: runs))
        let token = try #require(first["nextCursor"] as? String)
        // Simulates the tool's own result arriving after the first read.
        try await append(output.artifacts, run: run, tool: PresentationArtifactTool.name, store: runs)
        let second = try object(try await ChatInlineContentIndex.page(taskID: task, cursor: token, conversations: conversations, runs: runs))
        #expect(try strings(second).isEmpty && second["hasMore"] as? Bool == false)
        #expect((second["pages"] as? [[String: String]])?.first?["nextAfterSequence"] == "1")
    }

    static let audioFixtureTaskID = UUID(uuidString: "78D3612A-52F7-4A3B-BBA3-12E43B3F1E23")!
    @Test func registeredListRecoversRealAudioFactoryAndWebKitLoadsWithoutAutoplay() async throws {
        let app = try await appQualificationEnvironment(); try await app.ensureDurableAutomationReady()
        let task = Self.audioFixtureTaskID, title = "正文插入验收 · 音频与分页"
        if let stored = try await app.conversationStore.conversation(id: task) {
            #expect(stored.title == title && stored.purpose == .ordinary)
            guard stored.title == title && stored.purpose == .ordinary else { throw FloeError.unauthorized }
        } else { try await app.conversationStore.saveConversation(.init(id: task, title: title, createdAt: Date(), updatedAt: Date())) }
        let producer = UUID(), caller = UUID()
        for id in [producer, caller] { try await app.runStore.saveRun(.init(id: id, conversationID: task, state: "completed", goal: "native audio fixture", startedAt: Date())) }
        var pcm = Data()
        for frame in 0..<1_600 {
            var value = Int16(sin(2 * .pi * 440 * Double(frame) / 16_000) * 4_000).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        // Real bounded producer bytes; no cloud TTS or user recording.
        let artifact = try #require(try AssistantAudioInlinePlayer.makeReference(pcm: pcm, sampleRate: 16_000, runID: producer, title: "100 ms synthetic tone"))
        try await append([artifact], run: producer, tool: "audio.synthesize", store: app.runStore)
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: "chat.content.list"))
        let context = ToolContext(runID: caller, toolCallID: "actual-index", allowedToolNames: [runner.descriptor.name],
            cancellation: CancellationToken(), conversationID: task, frozenEffectiveCatalogNames: [runner.descriptor.name])
        let output = try await runner.execute(argumentsJSON: Data("{}".utf8), context: context)
        let page = try object(Data(output.summary.utf8)), values = try strings(page)
        let reference = ChatContentReference(kind: .artifact, ownerID: producer, contentID: artifact.id.uuidString)!
        #expect(values.contains { $0.contains(reference.uri) })
        let markdown = reference.markdown(title: "Audio preview")
        try await app.conversationStore.appendMessage(.init(id: UUID(), conversationID: task, role: "assistant",
            content: "真实工厂生成的 100 ms 合成音预览。\n\n" + markdown + "\n\n点击播放；没有自动播放。", createdAt: Date(), runID: producer))
        #expect(try await ChatInlineContentResolver.resolve(reference, scope: .init(conversationID: task, isTemporary: false),
            conversations: SQLiteConversationStore(database: app.database), runs: SQLiteRunStore(database: app.database)) == .artifact(artifact, runID: producer, tool: "audio.synthesize"))
        let verified = try VerifiedChatInlineArtifact.load(artifact, runID: producer, tool: "audio.synthesize", root: FloeArtifactStore.root())
        let html = String(decoding: verified.data, as: UTF8.self)
        #expect(html.contains("media-src data:") && html.contains("<audio controls preload=\"metadata\""))
        #expect(!html.contains("autoplay"))
        let decodingRoot = try scratch(); defer { try? FileManager.default.removeItem(at: decodingRoot) }
        let source = try Self.decodeEmbeddedWAV(in: html, to: decodingRoot.appendingPathComponent("actual-factory.wav"))
        let host = UIHostingController(rootView: RichArtifactView(artifact: artifact, preverified: verified, compactAudio: true))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        let previous = scene?.windows.first { $0.isKeyWindow }
        let window: UIWindow
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 500)) }
        window.frame = CGRect(x: 0, y: 0, width: 640, height: 500); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var web: WKWebView?, facts: AudioFacts?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            web = Self.webView(in: host.view)
            if let web { facts = try? await Self.facts(in: web) }
            if let facts, facts.ready >= 1, facts.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let player = try #require(web), observed = try #require(facts)
        #expect(abs(player.bounds.height - 120) < 1)
        #expect(player.configuration.allowsInlineMediaPlayback)
        #expect(player.configuration.mediaTypesRequiringUserActionForPlayback == .all)
        #expect(observed.documentReady == "complete" && observed.hasAudio && observed.controls)
        #expect(observed.preload == "metadata" && observed.source == source)
        #expect(observed.errorCode == 0)
        #expect(observed.paused && !observed.autoplay && observed.currentTime == 0 && observed.playedRanges == 0)
        // preload is a hint, not a promise to load before a user gesture.
        // This case verifies the real DOM and decoded source without calling
        // play/load or changing WK's user-action policy. Root verifies the
        // actual Play control separately; ready==0 is not playback evidence.
        // https://html.spec.whatwg.org/multipage/media.html#attr-media-preload
        if observed.ready >= 1 { #expect(abs(observed.duration - 0.1) < 0.025) }
        print("Inline audio before user action: ready=\(observed.ready), network=\(observed.network), duration=\(observed.duration), error=\(observed.errorCode), paused=\(observed.paused), playedRanges=\(observed.playedRanges). Playback requires a separate UI action.")
    }
    private static func decodeEmbeddedWAV(in html: String, to url: URL) throws -> String {
        let prefix = "src=\"data:audio/wav;base64,"
        let start = try #require(html.range(of: prefix)?.upperBound)
        let end = try #require(html[start...].firstIndex(of: "\""))
        let base64 = String(html[start..<end])
        let wav = try #require(Data(base64Encoded: base64))
        try wav.write(to: url, options: .atomic)
        // Decode the exact embedded producer bytes with the native audio
        // reader. This is independent of WebKit's pre-play loading policy.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
        #expect(file.length == 1_600)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 0.1) < 0.000_001)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600))
        try file.read(into: buffer)
        #expect(buffer.frameLength == 1_600)
        let samples = try #require(buffer.floatChannelData)[0]
        #expect(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)).contains { abs($0) > 0.1 })
        return "data:audio/wav;base64," + base64
    }
    private nonisolated struct AudioFacts: Codable, Sendable {
        let documentReady: String
        let hasAudio: Bool
        let controls: Bool
        let preload: String
        let source: String
        let errorCode: Int
        let network: Int
        let currentTime: Double
        let playedRanges: Int
        let ready: Int
        let duration: Double
        let paused: Bool
        let autoplay: Bool
    }
    private static func facts(in web: WKWebView) async throws -> AudioFacts {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("JSON.stringify((()=>{const a=document.querySelector('audio');return {documentReady:document.readyState,hasAudio:!!a,controls:a?.controls??false,preload:a?.preload??'',source:a?.getAttribute('src')??'',errorCode:a?.error?.code??0,network:a?.networkState??0,currentTime:a?.currentTime??0,playedRanges:a?.played?.length??0,ready:a?.readyState??0,duration:Number.isFinite(a?.duration)?a.duration:0,paused:a?.paused??false,autoplay:a?.autoplay??true}})())") { value, error in
                if let error { continuation.resume(throwing: error); return }
                do {
                    guard let text = value as? String else { throw FloeError.validationFailed("Audio DOM not loaded") }
                    continuation.resume(returning: try JSONDecoder().decode(AudioFacts.self, from: Data(text.utf8)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap(webView(in:)).first
    }
}
#endif
