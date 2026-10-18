// FloePersistenceTests — always-valid bounded child transcript payloads.
//
// These cases exercise the PRODUCTION codec used by SQLiteChildRunStore and
// SubagentRunner: CJK/emoji/JSON-escape budgets, pairing metadata retention,
// mixed typed result decoding and the bounded fallback for historical rows
// that are not valid JSON.

import Foundation
import Testing
@testable import FloePersistence

@Suite("FloePersistence.ChildRunPayload")
struct ChildRunPayloadTests {

    private func object(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test("A CJK/emoji tool payload stays valid JSON under 8 KiB and keeps callID")
    func cjkToolPayloadStaysValidAndPaired() throws {
        let arguments = String(repeating: #"{"路径":"文档/😀\".txt","值":"\\"}"#, count: 600)
        let source = try JSONSerialization.data(withJSONObject: [
            "tool": "workspace.readFile",
            "callID": "call-中文-😀-1",
            "arguments": arguments,
        ], options: [.sortedKeys])
        #expect(source.count > ChildRunPayload.maximumEntryBytes)

        let bounded = try ChildRunPayload.boundedPayload(
            String(decoding: source, as: UTF8.self),
            kind: .toolRequest
        )
        #expect(bounded.utf8.count <= ChildRunPayload.maximumEntryBytes)
        let decoded = try object(bounded)
        #expect(decoded["tool"] as? String == "workspace.readFile")
        #expect(decoded["callID"] as? String == "call-中文-😀-1")
        #expect(decoded["truncated"] as? Bool == true)
        let clippedArguments = try #require(decoded["arguments"] as? String)
        #expect(clippedArguments.utf8.count < arguments.utf8.count)
    }

    @Test("Mixed typed result fields decode for presentation instead of returning empty")
    func mixedTypedResultDecodes() throws {
        let json = try ChildRunPayload.boundedObject([
            "status": "completed",
            "iterationsUsed": 3,
            "findings": "完成：读取了三个文件 😀",
            "evidence": ["web.fetch d1", "skill.read guide revision=2"],
            "unfinished": ["未完成：第二个页面"],
            "truncated": true,
        ], requiredKeys: ["status"])
        let fields = ChildRunPayload.decodedStringFields(json)
        #expect(fields["status"] == "completed")
        #expect(fields["iterationsUsed"] == "3")
        #expect(fields["findings"] == "完成：读取了三个文件 😀")
        #expect(fields["evidence"] == "web.fetch d1\nskill.read guide revision=2")
        #expect(fields["unfinished"] == "未完成：第二个页面")
        #expect(fields["truncated"] == "true")
        // The old `[String: String]` decoder returned [:] for this object.
        let legacyDecoder = try? JSONDecoder().decode(
            [String: String].self, from: Data(json.utf8))
        #expect(legacyDecoder == nil)
    }

    @Test("A historical invalid row is readable raw text, not a fabricated status")
    func historicalInvalidRowFallsBack() throws {
        let historical = #"{"tool":"web.fetch","callID":"call-1","arguments":"{\"url\":\"https"#
        // Reading an old row is non-mutating and never invents fields.
        #expect(ChildRunPayload.decodedStringFields(historical) == [:])
        #expect(ChildRunPayload.rawFallbackText(historical) == historical)
        #expect(ChildRunPayload.requiresRawFallback(historical))

        // A NEW write of the same text is wrapped as valid JSON and keeps the
        // original bytes available as bounded raw evidence.
        let wrapped = try ChildRunPayload.boundedPayload(historical, kind: .toolRequest)
        #expect(wrapped.utf8.count <= ChildRunPayload.maximumEntryBytes)
        let decoded = try object(wrapped)
        #expect(decoded["invalidJSON"] as? Bool == true)
        #expect(decoded[ChildRunPayload.legacyRawKey] as? String == historical)
        #expect(ChildRunPayload.rawFallbackText(wrapped) == historical)
        #expect(ChildRunPayload.decodedStringFields(wrapped)["callID"] == nil)
        // The wrapper is valid JSON but still requires the raw fallback; a
        // structured tool card would otherwise hide the preserved text.
        #expect(ChildRunPayload.requiresRawFallback(wrapped))

        let normal = try ChildRunPayload.boundedObject(
            ["tool": "web.fetch", "callID": "call-1", "status": "ok"],
            requiredKeys: ["tool", "callID", "status"]
        )
        #expect(!ChildRunPayload.requiresRawFallback(normal))
    }

    @Test("Caller false/0/empty truncated markers are re-reserved as true before measuring")
    func existingMarkerValuesAreReplacedBeforeBudgeting() throws {
        // Build the exact base with the final marker spelling the codec owns.
        let baseTrue = try JSONSerialization.data(
            withJSONObject: ["text": "", "truncated": true],
            options: [.sortedKeys]).count
        let text = String(
            repeating: "a",
            count: ChildRunPayload.maximumEntryBytes - baseTrue + 4)
        for marker in [0, "", false] as [Any] {
            let source = String(decoding: try JSONSerialization.data(
                withJSONObject: ["text": text, "truncated": marker],
                options: [.sortedKeys]), as: UTF8.self)
            #expect(source.utf8.count > ChildRunPayload.maximumEntryBytes)
            // Must not throw merely because the caller's shorter marker was
            // measured before the final `true` marker was written.
            let bounded = try ChildRunPayload.boundedPayload(source, kind: .message)
            #expect(bounded.utf8.count <= ChildRunPayload.maximumEntryBytes)
            let decoded = try object(bounded)
            #expect(decoded["truncated"] as? Bool == true)
            #expect(!(decoded["text"] as? String ?? "").isEmpty)
        }
    }

    @Test("Required pairing metadata over budget throws instead of writing a false pair")
    func oversizedCallIDThrows() {
        let callID = String(repeating: "c", count: 9_000)
        #expect(throws: ChildRunPayloadError.self) {
            _ = try ChildRunPayload.boundedPayload(
                #"{"tool":"web.fetch","callID":"\#(callID)","arguments":"ok"}"#,
                kind: .toolRequest
            )
        }
    }

    @Test("The exact encoded 8 KiB boundary is preserved; one byte more is clipped safely")
    func exactBoundary() throws {
        let empty = try JSONSerialization.data(
            withJSONObject: ["text": ""], options: [.sortedKeys])
        let exactText = String(
            repeating: "a", count: ChildRunPayload.maximumEntryBytes - empty.count)
        let exactJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: ["text": exactText], options: [.sortedKeys]), as: UTF8.self)
        #expect(exactJSON.utf8.count == ChildRunPayload.maximumEntryBytes)
        let preserved = try ChildRunPayload.boundedPayload(exactJSON, kind: .message)
        #expect(preserved == exactJSON)

        let overText = exactText + "b"
        let overJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: ["text": overText], options: [.sortedKeys]), as: UTF8.self)
        let bounded = try ChildRunPayload.boundedPayload(overJSON, kind: .message)
        #expect(bounded.utf8.count <= ChildRunPayload.maximumEntryBytes)
        let decoded = try object(bounded)
        let kept = try #require(decoded["text"] as? String)
        #expect(!kept.isEmpty)
        #expect(kept.utf8.count < overText.utf8.count)
        #expect(decoded["truncated"] as? Bool == true)
    }
}
