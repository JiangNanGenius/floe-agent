import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

final class LegacyAdapterTests: XCTestCase {
    private let legacyJSON = """
    {
      "id": "5F7A1B2C-3D4E-4F50-A1B2-C3D4E5F60718",
      "schemaVersion": 5,
      "name": "Board",
      "revision": 12,
      "selectedDocumentID": "9E8D7C6B-5A49-4837-9F0E-1D2C3B4A5960",
      "experimentalFeature": { "big": 18446744073709551615, "pi": 3.141592653589793238462643383279, "exp": 1e400 },
      "documents": [
        {
          "id": "9E8D7C6B-5A49-4837-9F0E-1D2C3B4A5960",
          "name": "Main",
          "nodes": [
            { "id": "11111111-2222-3333-4444-555555555501",
              "kind": "text", "text": "Flat coords",
              "x": 120, "y": 240, "width": 300, "height": 160 },
            { "id": "11111111-2222-3333-4444-555555555502",
              "kind": "image", "title": "Photo",
              "position": { "x": 500, "y": 240 },
              "size": { "width": 320, "height": 260 },
              "asset": { "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEE01",
                         "contentHash": "sha256:abc", "localRelativePath": "a.heic" } },
            { "id": "11111111-2222-3333-4444-555555555503",
              "kind": "handwriting", "text": "ink",
              "position": { "x": 1, "y": 2 }, "size": { "width": 10, "height": 10 } }
          ],
          "connections": [
            { "id": "22222222-3333-4444-5555-666666666601",
              "sourceNodeID": "11111111-2222-3333-4444-555555555501",
              "destinationNodeID": "11111111-2222-3333-4444-555555555502",
              "kind": "arrow", "label": "ref" },
            { "id": "22222222-3333-4444-5555-666666666602",
              "sourceNodeID": "11111111-2222-3333-4444-555555555501",
              "destinationNodeID": "99999999-9999-9999-9999-999999999999",
              "kind": "line" }
          ]
        }
      ]
    }
    """

    func testImportMapsKnownFieldsAndRetainsRawBytes() throws {
        let bytes = Data(legacyJSON.utf8)
        let result = try LegacyCanvasAdapter.import(bytes)
        XCTAssertEqual(result.snapshot.id, UUID(uuidString: "5F7A1B2C-3D4E-4F50-A1B2-C3D4E5F60718"))
        XCTAssertEqual(result.snapshot.revision, 12)
        XCTAssertEqual(result.snapshot.pages.count, 1)
        let page = result.snapshot.pages[0]
        XCTAssertEqual(page.nodes.count, 3)

        // Flat coordinates accepted.
        let flat = page.nodes[0]
        XCTAssertEqual(flat.frame.center.x, 120)
        XCTAssertEqual(flat.frame.size.width, 300)
        XCTAssertEqual(flat.textContent, "Flat coords")

        // Asset mapping.
        let image = page.nodes[1]
        guard case .media(let asset) = image.content else {
            XCTFail("image node did not map to media content")
            return
        }
        XCTAssertEqual(asset.relativePath, "a.heic")

        // Unknown kind preserved verbatim as .unknown with payload.
        let ink = page.nodes[2]
        XCTAssertEqual(ink.kind, .unknown)
        guard case .unknown(let kind, _) = ink.content else {
            XCTFail("unknown content lost")
            return
        }
        XCTAssertEqual(kind, "handwriting")
        XCTAssertEqual(result.rawBytes, bytes)
    }

    func testImportReportsDanglingReferencesAndUnknownKinds() throws {
        let result = try LegacyCanvasAdapter.import(Data(legacyJSON.utf8))
        XCTAssertTrue(result.plan.warnings.contains {
            $0.code == .danglingReference
        })
        XCTAssertTrue(result.plan.warnings.contains {
            $0.code == .unknownNodeKind && $0.detail.contains("handwriting")
        })
        XCTAssertTrue(result.plan.preservedKeys.contains("experimentalFeature"))
        XCTAssertTrue(result.plan.plannedPatches.contains {
            $0.action == .recordUnknownNodeKinds
        })
        XCTAssertTrue(result.plan.plannedPatches.contains {
            $0.action == .markSchemaCurrent
        })
    }

    func testExportPreservesUnknownValuesExactly() throws {
        let result = try LegacyCanvasAdapter.import(Data(legacyJSON.utf8))
        let exported = try LegacyCanvasAdapter.exportPreservingLegacy(result)
        let exportedText = String(data: exported, encoding: .utf8)!
        // Exact numeric literals of unknown fields survive the round trip.
        XCTAssertTrue(exportedText.contains("18446744073709551615"))
        XCTAssertTrue(exportedText.contains("3.141592653589793238462643383279"))
        XCTAssertTrue(exportedText.contains("1e400"))
        XCTAssertTrue(exportedText.contains("experimentalFeature"))
        // Known values were overlaid.
        XCTAssertTrue(exportedText.contains("5F7A1B2C-3D4E-4F50-A1B2-C3D4E5F60718"))
    }

    func testMissingIdentityRequiresFallback() throws {
        var tree = try JSONFidelity.parse(Data(legacyJSON.utf8)).objectValue!
        tree["id"] = nil
        let bytes = try JSONFidelity.serialize(.object(tree))

        XCTAssertThrowsError(try LegacyCanvasAdapter.import(bytes)) { error in
            guard case CanvasKitError.missingEntity = error else {
                XCTFail("expected missingEntity, got \(error)")
                return
            }
        }
        let fallback = UUID()
        let result = try LegacyCanvasAdapter.import(bytes, fallbackCanvasID: fallback)
        XCTAssertEqual(result.snapshot.id, fallback)
        XCTAssertTrue(result.plan.warnings.contains { $0.code == .missingIdentity })
    }

    func testMissingNodeIdentityIsReportedNotSilent() throws {
        var tree = try JSONFidelity.parse(Data(legacyJSON.utf8)).objectValue!
        var doc = tree["documents"]!.arrayValue![0].objectValue!
        var nodes = doc["nodes"]!.arrayValue!
        var node = nodes[0].objectValue!
        node["id"] = nil
        nodes[0] = .object(node)
        doc["nodes"] = .array(nodes)
        tree["documents"] = .array([.object(doc)])
        let bytes = try JSONFidelity.serialize(.object(tree))

        let result = try LegacyCanvasAdapter.import(bytes)
        XCTAssertTrue(result.plan.warnings.contains {
            $0.code == .missingIdentity && $0.path.contains("nodes[0]")
        })
    }

    func testUnsupportedSchemaRejected() {
        var tree = try! JSONFidelity.parse(Data(legacyJSON.utf8)).objectValue!
        tree["schemaVersion"] = .number("99")
        let bytes = try! JSONFidelity.serialize(.object(tree))
        XCTAssertThrowsError(try LegacyCanvasAdapter.import(bytes)) { error in
            guard case CanvasKitError.unsupportedLegacySchema(let version) = error else {
                XCTFail("expected unsupportedLegacySchema, got \(error)")
                return
            }
            XCTAssertEqual(version, 99)
        }
    }
}
