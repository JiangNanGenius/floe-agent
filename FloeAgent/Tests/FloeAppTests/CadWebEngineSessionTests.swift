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
import FloeWorkbench

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
/// Real transaction serialization: two distinct grants at the same revision
/// must not both edit, and the same request id in flight must replay rather
/// than double-apply. These exercise the actual CadDocumentCenter gate against
/// the real engine + file CAS, not a string helper.
@Suite("CAD document transaction serialization", .serialized)
@MainActor
struct CadDocumentCenterConcurrencyTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bundleRoot = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let sample = try? Data(contentsOf: bundleRoot.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        try sample.write(to: root.appendingPathComponent("plan.dxf"))
        return root
    }

    private func access(_ root: URL) -> CadDocumentAccess {
        CadDocumentAccess(environmentID: nil, workspacePath: root.path,
                          ownerKind: "workspace", ownerID: nil)
    }

    private let addLineOperations =
        #"[{"operation":"addLine","start":[0,0,0],"end":[5,0,0],"layer":"0"}]"#

    @Test func distinctGrantsAtSameRevisionOnlyOneEdits() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant1 = await center.issueUserGrant(for: proposal)
        let grant2 = await center.issueUserGrant(for: proposal)
        #expect(grant1 != grant2)

        let successes = await withTaskGroup(of: Bool.self) { group in
            for (grant, request) in [(grant1, "req-a"), (grant2, "req-b")] {
                group.addTask {
                    do {
                        _ = try await center.apply(proposal: proposal, grantID: grant,
                                                   requestID: request, access: access)
                        return true
                    } catch { return false }
                }
            }
            var total = 0
            for await value in group where value { total += 1 }
            return total
        }
        #expect(successes == 1, "exactly one of two same-revision grants may edit")
        let after = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(after.revision > snapshot.revision)
        #expect(after.sha256 != snapshot.sha256)
    }

    @Test func sameRequestInFlightReplaysInsteadOfDoubleApplying() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = CadDocumentCenter()
        let access = access(root)
        let snapshot = try await center.snapshot(documentID: "plan.dxf", access: access)
        let proposal = try await center.prepareProposal(
            documentID: "plan.dxf", snapshot: snapshot, summary: "add line",
            operationsJSON: addLineOperations, access: access)
        try await center.storeProposal(proposal)
        let grant = await center.issueUserGrant(for: proposal)

        let receipts = await withTaskGroup(of: CadDocumentReceipt?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await center.apply(proposal: proposal, grantID: grant,
                                            requestID: "same-request", access: access)
                }
            }
            var values: [CadDocumentReceipt] = []
            for await receipt in group { if let receipt { values.append(receipt) } }
            return values
        }
        #expect(receipts.count == 2, "both callers receive a result")
        #expect(receipts.filter { $0.replay }.count == 1, "the second call must be a replay")
        #expect(Set(receipts.map(\.revision)).count == 1)
        let after = try await center.snapshot(documentID: "plan.dxf", access: access)
        #expect(after.revision == snapshot.revision + 1, "the document advanced exactly once")
    }
}
#endif
