import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence

final class G09CreativeBridgeTests: XCTestCase {
    private var roots: [URL] = []
    private var database: DatabaseManager?

    override func tearDown() async throws {
        if let database { try? await database.close() }
        database = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private func makeService() async throws -> (G09CreativeDomainService,
                                                G09CreativeStorageContext) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-creative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        return (G09CreativeDomainService(),
                G09CreativeStorageContext(
                    root: root, database: manager,
                    workspaceStore: SQLiteWorkspaceStore(database: manager),
                    conversationStore: SQLiteConversationStore(database: manager)))
    }

    private func request(_ action: String, epoch: UInt64 = 1,
                         payload: String = "{}", id: String = "req-1") -> Data {
        Data("""
        {"version":5,"operation":"command","requestID":"\(id)","epoch":\(epoch),"action":"\(action)","payload":\(payload)}
        """.utf8)
    }

    func testHandshakeAndBounds() throws {
        let handshake = BridgeV5.handshake()
        XCTAssertEqual(handshake["ok"] as? Bool, true)
        XCTAssertEqual(handshake["version"] as? Int, 5)
        XCTAssertEqual(handshake["schema"] as? String, "floe.creative/5")
        XCTAssertTrue((handshake["actions"] as? [String])?.contains("canvas.patch") == true)
        XCTAssertEqual(handshake["requestMaxBytes"] as? Int, 65_536)
        XCTAssertEqual(handshake["responseMaxBytes"] as? Int, 16 * 1024 * 1024)
        XCTAssertEqual(handshake["modelTools"] as? Bool, false)

        let viaC = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: AndroidBridge.exchange(Data(
                    #"{"version":5,"requestID":"h","operation":"handshake"}"#.utf8)))
                as? [String: Any])
        XCTAssertEqual(viaC["version"] as? Int, 5)
        XCTAssertEqual(viaC["requestID"] as? String, "h")
        XCTAssertEqual(viaC["ok"] as? Bool, true)

        let oversized = AndroidBridge.exchange(Data(repeating: 65, count: 65_537))
        let tooLarge = try XCTUnwrap(
            JSONSerialization.jsonObject(with: oversized) as? [String: Any])
        XCTAssertEqual(tooLarge["version"] as? Int, 1)
        XCTAssertEqual(tooLarge["error"] as? String, "requestTooLarge")

        let future = BridgeV5.handle(
            requestData: Data(#"{"version":6,"operation":"handshake"}"#.utf8),
            fallbackRequestID: nil)
        XCTAssertEqual(future["error"] as? String, "unsupportedVersion")
    }


    func testKotlinMediaCommandShapeDecodesIntoSharedCommands() throws {
        let layerJSON = """
        {"type":"addImageLayer","layer":{
          "id":"55555555-5555-5555-5555-555555555555","kind":"text","name":"Title",
          "transform":{"centerX":0.5,"centerY":0.5,"scale":1,"rotationDegrees":0},
          "opacity":1,"isHidden":false,"isLocked":false,
          "adjustment":{},"text":{"text":"Hello","fontSize":48,"colorHex":"#000000"}}}
        """
        let add = try G09CreativeWire.decoder().decode(
            G09MediaCommandWire.self, from: Data(layerJSON.utf8))
        guard case .addImageLayer(let layer) = add else {
            return XCTFail("expected addImageLayer")
        }
        XCTAssertEqual(layer.text?.text, "Hello")

        let updateJSON = """
        {"type":"updateLayer","id":"55555555-5555-5555-5555-555555555555",
         "opacity":0.5,"crop":{"state":"unchanged"}}
        """
        let update = try G09CreativeWire.decoder().decode(
            G09MediaCommandWire.self, from: Data(updateJSON.utf8))
        guard case .updateLayer(let id, _, let opacity, _, _, _, _, let crop) = update else {
            return XCTFail("expected updateLayer")
        }
        XCTAssertEqual(id.uuidString.lowercased(), "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(opacity, 0.5)
        guard case .unchanged = crop else { return XCTFail("crop must be unchanged") }

        let canvasJSON = """
        {"type":"setCanvas","width":800,"height":600}
        """
        let canvas = try G09CreativeWire.decoder().decode(
            G09MediaCommandWire.self, from: Data(canvasJSON.utf8))
        guard case .setCanvas(let width, let height, nil) = canvas else {
            return XCTFail("expected setCanvas")
        }
        XCTAssertEqual(width, 800)
        XCTAssertEqual(height, 600)
    }

    func testStatusBeforeBindAndEpochFence() async throws {
        let (service, storage) = try await makeService()
        let status = BridgeV5.handle(
            requestData: Data(#"{"version":5,"operation":"status","requestID":"s"}"#.utf8),
            fallbackRequestID: "s", service: service)
        XCTAssertEqual(status["ok"] as? Bool, true)
        XCTAssertEqual(status["bound"] as? Bool, false)

        _ = try await service.bind(epoch: 1, storage: storage)
        let bound = BridgeV5.handle(
            requestData: Data(#"{"version":5,"operation":"status","requestID":"s2"}"#.utf8),
            fallbackRequestID: "s2", service: service)
        XCTAssertEqual(bound["bound"] as? Bool, true)
        XCTAssertEqual(bound["epoch"] as? Int, 1)

        let stale = BridgeV5.handle(
            requestData: request("canvas.library", epoch: 2),
            fallbackRequestID: "req-1", service: service)
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "staleGeneration")

        let unknown = BridgeV5.handle(
            requestData: request("canvas.nope"),
            fallbackRequestID: "req-1", service: service)
        XCTAssertEqual(unknown["error"] as? String, "unsupportedAction")

        let malformed = BridgeV5.handle(
            requestData: Data(#"{"version":5,"operation":"command","requestID":"x","epoch":1,"action":"canvas.create","payload":{"name":""}}"#.utf8),
            fallbackRequestID: "x", service: service)
        XCTAssertEqual(malformed["ok"] as? Bool, false)
        XCTAssertEqual(malformed["error"] as? String, "invalidPayload")
    }


    func testTokenScopedCloseDoesNotRetireReplacementEditor() async throws {
        let (service, storage) = try await makeService()
        _ = try await service.bind(epoch: 1, storage: storage)

        func perform(_ action: String, _ json: String) async throws -> [String: Any] {
            let payload = try G09CreativeWire.decoder().decode(
                G09CreativeJSON.self, from: Data(json.utf8))
            let data = try await service.perform(
                epoch: 1, requestID: UUID().uuidString,
                action: action, payload: payload)
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let created = try await perform(
            "canvas.create",
            #"{"name":"Close Board","sessionToken":"session-A"}"#)
        let project = try XCTUnwrap(created["project"] as? [String: Any])
        let canvasID = try XCTUnwrap(project["id"] as? String)
        let documentID = try XCTUnwrap(project["selectedDocumentID"] as? String)

        _ = try await perform(
            "canvas.load",
            #"{"canvasID":"\#(canvasID)","sessionToken":"session-B"}"#)
        let oldClose = await service.closeEditor(
            kind: "canvas", projectID: UUID(uuidString: canvasID)!,
            token: "session-A")
        XCTAssertFalse(oldClose.closed)
        XCTAssertTrue(oldClose.replaced)

        let patchJSON = """
        {"canvasID":"\(canvasID)","expectedRevision":1,
         "sessionToken":"session-A","opID":"late-A",
         "patch":{"canvasID":"\(canvasID)","documentID":"\(documentID)",
                  "expectedRevision":1,"operations":[]}}
        """
        do {
            _ = try await perform("canvas.patch", patchJSON)
            XCTFail("a late old-editor mutation must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "staleSession")
        }

        let currentClose = await service.closeEditor(
            kind: "canvas", projectID: UUID(uuidString: canvasID)!,
            token: "session-B")
        XCTAssertTrue(currentClose.closed)
        XCTAssertFalse(currentClose.replaced)
        do {
            _ = try await perform(
                "canvas.patch",
                patchJSON.replacingOccurrences(of: "session-A", with: "session-B"))
            XCTFail("a closed editor cannot mutate")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error.code, "sessionRequired")
        }
    }

    func testCanvasCreateAndLibraryThroughBridge() async throws {
        let (service, storage) = try await makeService()
        _ = try await service.bind(epoch: 1, storage: storage)
        let created = BridgeV5.handle(
            requestData: request("canvas.create",
                                 payload: #"{"name":"Bridge Board","sessionToken":"session-1"}"#),
            fallbackRequestID: "req-1", service: service)
        XCTAssertEqual(created["ok"] as? Bool, true)
        let project = try XCTUnwrap(created["project"] as? [String: Any])
        XCTAssertEqual(project["name"] as? String, "Bridge Board")
        XCTAssertEqual(project["schemaVersion"] as? Int, 7)

        let library = BridgeV5.handle(
            requestData: request("canvas.library"),
            fallbackRequestID: "req-1", service: service)
        XCTAssertEqual(library["ok"] as? Bool, true)
        let projects = try XCTUnwrap(library["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?["name"] as? String, "Bridge Board")
    }
}
