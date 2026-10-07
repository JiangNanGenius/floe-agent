// FloeAppTests — real WKWebView → cad-host → Worker → wasm smoke test.
//
// Covers the native bridge contract end to end: open, inspect (JSON string, not
// "[object Object]"), query, edit with a JSON-string request, undo, save bytes
// and the DXF projection. These paths cannot be proven by builder or tool
// tests alone.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
import FloeCore

@Suite("CAD WKWebView worker bridge", .serialized)
@MainActor
struct CadWebEngineSessionTests {
    private func sampleDXF() throws -> Data {
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        return data
    }

    private func object(_ json: String) throws -> [String: Any] {
        guard let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw FloeError.storageCorrupted("expected a JSON object from the CAD bridge")
        }
        return parsed
    }

    private func entityCount(_ session: CadWebEngineSession) async throws -> Int {
        let info = try object(try await session.inspect(offset: 0, limit: 1))
        return info["entityCount"] as? Int ?? -1
    }

    @Test func fullWorkerBridgeRoundTrip() async throws {
        let sample = try sampleDXF()
        let session = CadWebEngineSession()
        try await session.start()
        do {
            // open
            let opened = try object(try await session.open(bytes: sample, format: "dxf"))
            let base = opened["entityCount"] as? Int ?? 0
            #expect(base > 0, "sample drawing must parse with entities")
            #expect((opened["unit"] as? String)?.isEmpty == false)

            // inspect must be a JSON string, never "[object Object]".
            let inspected = try await session.inspect(offset: 0, limit: 5)
            #expect(inspected.hasPrefix("{"))
            #expect(inspected.contains("entityCount"))

            // query (JSON string passthrough must not be double-encoded)
            let layers = try await session.query(#"{"operation":"layers"}"#)
            #expect(layers.contains("layers"))

            // edit with a JSON-string request: the worker must hand the engine
            // a command object, not a JSON string literal.
            let edit = try object(try await session.edit(
                #"{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}"#))
            let created = edit["created"] as? [String] ?? []
            #expect(created.count == 1, "addLine must report one created handle")
            #expect(try await entityCount(session) == base + 1)

            // undo restores the pre-edit revision.
            try await session.undo()
            #expect(try await entityCount(session) == base)

            // save returns verified DXF bytes for this format.
            let saved = try await session.save()
            #expect(!saved.isEmpty)
            let savedHead = String(decoding: saved.prefix(256), as: UTF8.self)
            #expect(savedHead.contains("SECTION") || savedHead.hasPrefix("  0"))

            // DXF projection is a distinct worker operation (regression).
            let dxf = try await session.displayDXF()
            let dxfText = String(decoding: dxf, as: UTF8.self)
            #expect(dxfText.contains("SECTION"))
        } catch {
            await session.shutdown()
            throw error
        }
        await session.shutdown()
    }

    @Test func queryRejectsDoubleEncodedRequest() async throws {
        let session = CadWebEngineSession()
        try await session.start()
        _ = try await session.open(bytes: try sampleDXF(), format: "dxf")
        await #expect(throws: (any Error).self) {
            _ = try await session.query("\"{\\\"operation\\\":\\\"layers\\\"}\"")
        }
        await session.shutdown()
    }
}
#endif
