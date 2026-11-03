// SPDX-License-Identifier: MPL-2.0
//
// C04B focused deterministic tests for the ACTUAL native `.floecad` package
// contract. AUTHORED, NOT EXECUTED by this source-only lane. The real
// directory read, WebView render and App entry remain Main's unified
// qualification.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class C04FloecadPackageTests: XCTestCase {
    private let bodyID = "B61A7FB4-2F24-4334-811F-7C0CE642C305"
    private let meshSHA = String(repeating: "6", count: 64)
    private let brepSHA = String(repeating: "e", count: 64)

    private func transformData(translation: [Double] = [0, 0, 0]) -> String {
        let object: [String: Any] = [
            "translation": translation,
            "rotation": [0, 0, 0, 1],
            "scale": 1,
        ]
        return (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
    }

    private func documentData() -> Data {
        let object: [String: Any] = [
            "bodies": [[
                "bodyID": bodyID,
                "name": "Body",
                "transform": transformData(translation: [10, 20, 30]),
                "meshBlob": "blobs/\(bodyID).mesh",
                "meshSHA256": meshSHA,
                "brepBlob": "blobs/\(bodyID).brep",
                "brepSHA256": brepSHA,
                "isHidden": false,
            ]],
            "images": [],
            "sketches": [],
            "planes": [],
            "axes": [],
            "symbols": [],
            "features": [],
            "variables": [],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func manifestData(document: Data) -> Data {
        let content = try! C04FloecadPackage.contentSHA256(
            documentBytes: document,
            blobs: [
                (path: "blobs/\(bodyID).mesh", sha256: meshSHA),
                (path: "blobs/\(bodyID).brep", sha256: brepSHA),
            ],
            thumbnailSHA256: nil)
        let object: [String: Any] = [
            "schemaVersion": 3,
            "revision": 6,
            "name": "Hole form",
            "contentSHA256": content,
            "modelSHA256": String(repeating: "a", count: 64),
            "appBuild": "FloeCAD/test",
            "unit": "mm",
            "tolerance": 0.001,
            "counts": ["bodies": 1, "images": 0],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func meshData(version: UInt32 = 1, vertices: Int = 3,
                          indices: [UInt32] = [0, 1, 2],
                          uvs: Bool = false) -> Data {
        var data = Data()
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendFloat(_ value: Float) {
            var little = value.bitPattern.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendUInt32(0x4F533344)
        appendUInt32(version)
        appendUInt32(UInt32(vertices))
        appendUInt32(UInt32(indices.count))
        for index in 0..<vertices {
            appendFloat(Float(index))
            appendFloat(0)
            appendFloat(0)
        }
        for _ in 0..<vertices {
            appendFloat(0)
            appendFloat(1)
            appendFloat(0)
        }
        for index in indices { appendUInt32(index) }
        if uvs {
            for _ in 0..<vertices {
                appendFloat(0)
                appendFloat(1)
            }
        }
        return data
    }

    func testNativeManifestDocumentAndDigestMatchTheWriterContract() throws {
        let document = documentData()
        let manifest = try C04FloecadPackage.parseManifest(manifestData(document: document))
        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(manifest.revision, 6)
        XCTAssertEqual(manifest.name, "Hole form")
        XCTAssertEqual(manifest.unit, "mm")
        let header = try C04FloecadPackage.parseDocumentHeader(document)
        XCTAssertEqual(header.bodyCount, 1)
        let recomputed = try C04FloecadPackage.contentSHA256(
            documentBytes: document,
            blobs: [
                (path: "blobs/\(bodyID).mesh", sha256: meshSHA),
                (path: "blobs/\(bodyID).brep", sha256: brepSHA),
            ],
            thumbnailSHA256: nil)
        XCTAssertEqual(recomputed, manifest.contentSHA256)
    }

    func testVersionOneMeshDoesNotConstrainDocumentPlacement() throws {
        let header = try C04FloecadPackage.parseMeshHeader(meshData(version: 1))
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.vertexCount, 3)
        XCTAssertEqual(header.indexCount, 3)
        let document = documentData()
        let documentHeader = try C04FloecadPackage.parseDocumentHeader(document)
        XCTAssertEqual(documentHeader.bodyCount, 1)
    }

    func testVersionTwoMeshCarriesTextureCoordinates() throws {
        let data = meshData(version: 2, uvs: true)
        let header = try C04FloecadPackage.parseMeshHeader(data)
        XCTAssertEqual(header.version, 2)
        XCTAssertEqual(header.byteCount, data.count)
    }

    func testTruncatedAndCorruptMeshesFailClosed() {
        XCTAssertThrowsError(try C04FloecadPackage.parseMeshHeader(Data()))
        var corrupt = meshData()
        corrupt[0] = 0
        XCTAssertThrowsError(try C04FloecadPackage.parseMeshHeader(corrupt)) { error in
            XCTAssertEqual(
                error as? C04FloecadPackage.Failure,
                C04FloecadPackage.Failure.invalid("meshMagic") as C04FloecadPackage.Failure?)
        }
        var badIndices = meshData(indices: [0, 1, 3])
        XCTAssertNoThrow(try C04FloecadPackage.parseMeshHeader(badIndices))
        badIndices.removeLast()
        XCTAssertThrowsError(try C04FloecadPackage.parseMeshHeader(badIndices))
    }

    func testDerivedPreviewUnitContractIsMillimetresToMetres() {
        XCTAssertEqual(C04FloecadPackageLimits.sourceUnit, "mm")
        XCTAssertEqual(C04FloecadPackageLimits.gltfUnit, "m")
        XCTAssertEqual(C04FloecadPackageLimits.sourceUnitScaleToMeters, 0.001, accuracy: 0)
        XCTAssertEqual(C04FloecadPackageLimits.maximumBrepConversionBytes, 10 * 1024 * 1024)
        let sourceMillimetres = 1_000.0
        XCTAssertEqual(sourceMillimetres * C04FloecadPackageLimits.sourceUnitScaleToMeters,
                       1.0, accuracy: 1e-12)
    }

    func testBlobPathsAreCanonicalAndContained() {
        XCTAssertTrue(C04FloecadPackage.validateBlobPath("blobs/\(bodyID).mesh"))
        XCTAssertTrue(C04FloecadPackage.validateBlobPath("blobs/images/\(bodyID).img"))
        for path in [
            "/blobs/a.mesh", "../blobs/a.mesh", "blobs/../a.mesh",
            "blobs/a\\b.mesh", "https://example.com/a.mesh",
            "blobs/a.txt", "previous/manifest.json", "blobs/images/x/y.img",
        ] {
            XCTAssertFalse(C04FloecadPackage.validateBlobPath(path), path)
        }
    }

    func testManifestRejectsUnknownRequiredIdentityAndAcceptsNewerFields() throws {
        var object = try JSONSerialization.jsonObject(with: manifestData(document: documentData()))
            as! [String: Any]
        object["unknownFutureField"] = ["safe": true]
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNoThrow(try C04FloecadPackage.parseManifest(data))

        object["contentSHA256"] = "not-a-digest"
        let broken = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try C04FloecadPackage.parseManifest(broken))
    }
}
