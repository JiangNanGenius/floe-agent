// SPDX-License-Identifier: MPL-2.0
//
// C04A focused deterministic tests for the viewer contract. AUTHORED, NOT
// EXECUTED by the source-only lane. Real WebView/WASM rendering, device input
// and App entry acceptance remain Main's unified qualification.
import XCTest
import Foundation
@testable import FloeAndroidCore

private final class C04CadTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
    }
}

final class C04CadViewerTests: XCTestCase {

    private func owner() throws -> C04CadOwner {
        try C04CadOwner(
            taskID: UUID(), workspaceID: UUID(),
            nativeEpoch: 7, hostGeneration: 3)
    }

    private func facts(
        format: C04CadFormat, frame: Int = 1,
        units: C04CadUnits = .unknown
    ) throws -> C04CadSceneFacts {
        try C04CadSceneFacts(
            format: format,
            sourceUnits: units,
            displayUnits: units,
            bounds: try C04CadBounds(
                minimum: [0, 0, 0], maximum: [10, 20, 30],
                center: nil, radius: nil),
            entityCount: format.family == .vector2D ? 3 : nil,
            meshCount: format.family == .vector2D ? 0 : 1,
            triangleCount: format.family == .vector2D ? 0 : 12,
            vertexCount: format.family == .vector2D ? 0 : 8,
            missingResourceCount: 0,
            frameSequence: frame,
            limitations: "test limitation")
    }

    private func pngHeaderHex(width: Int, height: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: 33)
        bytes.replaceSubrange(0..<8, with: [UInt8](
            arrayLiteral: 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
        bytes.replaceSubrange(8..<12, with: [UInt8](arrayLiteral: 0, 0, 0, 13))
        bytes.replaceSubrange(12..<16, with: Array("IHDR".utf8))
        bytes[16] = UInt8((width >> 24) & 0xFF)
        bytes[17] = UInt8((width >> 16) & 0xFF)
        bytes[18] = UInt8((width >> 8) & 0xFF)
        bytes[19] = UInt8(width & 0xFF)
        bytes[20] = UInt8((height >> 24) & 0xFF)
        bytes[21] = UInt8((height >> 16) & 0xFF)
        bytes[22] = UInt8((height >> 8) & 0xFF)
        bytes[23] = UInt8(height & 0xFF)
        bytes[24] = 8
        bytes[25] = 6
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Routing

    func testRoutingMatchesPinnedReadersAndExcludesFloecad() {
        let expected: [String: C04CadFormat] = [
            "dxf": .dxf, "dwg": .dwg,
            "step": .step, "stp": .stp, "iges": .iges, "igs": .igs, "brep": .brep,
            "glb": .glb, "gltf": .gltf, "obj": .obj, "stl": .stl, "3mf": .threeMF,
        ]
        for (ext, format) in expected {
            XCTAssertEqual(C04CadFormat.route(relativePath: "models/part.\(ext)"), format)
        }
        XCTAssertNil(C04CadFormat.route(relativePath: "models/part.floecad"))
        XCTAssertNil(C04CadFormat.route(relativePath: "models/no-extension"))
    }

    func testPathNormalizationAndContainment() {
        XCTAssertEqual(C04CadPath.normalize("models/textures/a.png"), "models/textures/a.png")
        XCTAssertNil(C04CadPath.normalize("/etc/passwd"))
        XCTAssertNil(C04CadPath.normalize("models/../secret.bin"))
        XCTAssertNil(C04CadPath.normalize("models/a\\b.png"))
        XCTAssertTrue(C04CadPath.contained("models/textures/a.png", in: "models"))
        XCTAssertFalse(C04CadPath.contained("textures/a.png", in: "models"))
        XCTAssertFalse(C04CadPath.contained("models/../secret.bin", in: "models"))
        XCTAssertTrue(C04CadPath.contained("textures/a.png", in: ""))
    }

    // MARK: - Session lifecycle

    func testSessionRequiresRenderedFrameBeforeCapture() throws {
        let clock = C04CadTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let registry = C04CadSessionRegistry(now: { clock.read() })
        let started = try registry.begin(
            owner: try owner(), relativePath: "models/part.gltf",
            format: .gltf, sourceBytes: 128, resources: [])
        XCTAssertThrowsError(try registry.capture(
            sessionID: started.sessionID,
            pngHeaderHex: pngHeaderHex(width: 640, height: 480),
            pngSHA256: String(repeating: "a", count: 64),
            byteCount: 2_048, pixelWidth: 640, pixelHeight: 480,
            frameSequence: 1)
        ) { error in
            XCTAssertEqual(error as? C04CadError, C04CadError.notReady)
        }
        _ = try registry.readiness(
            sessionID: started.sessionID,
            facts: try facts(format: .gltf, frame: 1))
        let receipt = try registry.capture(
            sessionID: started.sessionID,
            pngHeaderHex: pngHeaderHex(width: 640, height: 480),
            pngSHA256: String(repeating: "a", count: 64),
            byteCount: 2_048, pixelWidth: 640, pixelHeight: 480,
            frameSequence: 1)
        XCTAssertEqual(receipt.format, .gltf)
        XCTAssertEqual(receipt.pixelWidth, 640)
        XCTAssertEqual(receipt.pixelHeight, 480)
        XCTAssertEqual(registry.end(sessionID: started.sessionID), 0)
        clock.advance(C04CadLimits.sessionTTL + 1)
        XCTAssertEqual(registry.sessionCount, 0)
    }

    func testSessionRejectsStaleFrameAndBadCaptureHeader() throws {
        let registry = C04CadSessionRegistry()
        let started = try registry.begin(
            owner: try owner(), relativePath: "drawings/plate.dxf",
            format: .dxf, sourceBytes: 64, resources: [])
        _ = try registry.readiness(
            sessionID: started.sessionID,
            facts: try facts(format: .dxf, frame: 4, units: .millimeters))
        XCTAssertThrowsError(try registry.capture(
            sessionID: started.sessionID,
            pngHeaderHex: pngHeaderHex(width: 640, height: 480),
            pngSHA256: String(repeating: "b", count: 64),
            byteCount: 2_048, pixelWidth: 640, pixelHeight: 480,
            frameSequence: 3)
        ) { error in
            XCTAssertEqual(error as? C04CadError, C04CadError.staleFrame)
        }
        XCTAssertThrowsError(try registry.capture(
            sessionID: started.sessionID,
            pngHeaderHex: pngHeaderHex(width: 641, height: 480),
            pngSHA256: String(repeating: "b", count: 64),
            byteCount: 2_048, pixelWidth: 640, pixelHeight: 480,
            frameSequence: 4)
        ) { error in
            XCTAssertEqual(error as? C04CadError, C04CadError.invalidCapture)
        }
    }

    func testResourcesStayInsideMainDirectory() throws {
        let registry = C04CadSessionRegistry()
        let descriptor = try C04CadResourceDescriptor(
            relativePath: "models/textures/a.png", byteCount: 10,
            sha256: String(repeating: "a", count: 64), mediaType: "image/png")
        let started = try registry.begin(
            owner: try owner(), relativePath: "models/part.obj",
            format: .obj, sourceBytes: 64, resources: [descriptor])
        XCTAssertEqual(started.grants.count, 1)
        registry.resetForTesting()
        XCTAssertThrowsError(try registry.begin(
            owner: try owner(), relativePath: "models/part.obj",
            format: .obj, sourceBytes: 64,
            resources: [try C04CadResourceDescriptor(
                relativePath: "textures/a.png", byteCount: 10,
                sha256: String(repeating: "a", count: 64), mediaType: "image/png")])
        ) { error in
            XCTAssertEqual(error as? C04CadError, C04CadError.resourceOutsideScope)
        }
    }

    // MARK: - C04B package contract

    private func packageManifest(meshVersion: Int = 2) -> [String: Any] {
        let digest = String(repeating: "a", count: 64)
        let transform: [Double] = meshVersion == 1
            ? [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
            : [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2, 3, 1]
        let meshResource: [String: Any] = [
            "id": "mesh0", "path": "mesh/part.bin", "bytes": 1_024,
            "sha256": digest,
            "mediaType": "application/vnd.floe.cad.mesh.v\(meshVersion)",
        ]
        let imageResource: [String: Any] = [
            "id": "img0", "path": "textures/a.png", "bytes": 512,
            "sha256": digest, "mediaType": "image/png",
        ]
        let mesh: [String: Any] = [
            "id": "mesh0", "resourceID": "mesh0",
            "format": "floecad-mesh-v\(meshVersion)",
            "transform": transform, "vertexCount": 100, "triangleCount": 50,
            "bounds": ["min": [0, 0, 0], "max": [1, 1, 1]],
        ]
        let image: [String: Any] = [
            "id": "img0", "resourceID": "img0", "width": 512, "height": 512,
        ]
        return [
            "schema": "floe.cad-package/1",
            "scene": [
                "meshVersion": meshVersion,
                "sourceUnits": "mm",
                "upAxis": "z",
                "meshes": [mesh],
                "images": [image],
            ],
            "resources": [meshResource, imageResource],
        ]
    }

    func testPackageValidatorAcceptsV1AndV2() throws {
        let v1 = try C04CadPackageValidator.validate(packageManifest(meshVersion: 1))
        XCTAssertEqual(v1.meshVersion, 1)
        XCTAssertEqual(v1.meshCount, 1)
        XCTAssertEqual(v1.imageCount, 1)
        XCTAssertEqual(v1.resourceCount, 2)
        XCTAssertEqual(v1.sourceUnits, .millimeters)
        let v2 = try C04CadPackageValidator.validate(packageManifest(meshVersion: 2))
        XCTAssertEqual(v2.meshVersion, 2)
        XCTAssertEqual(v2.totalBytes, 1_536)
    }

    func testPackageValidatorRejectsTraversalAndMissingReferences() throws {
        var manifest = packageManifest()
        var resources = manifest["resources"] as! [[String: Any]]
        resources[0]["path"] = "../secret.bin"
        manifest["resources"] = resources
        XCTAssertThrowsError(try C04CadPackageValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? C04CadError, C04CadError.invalidPackage)
        }

        manifest = packageManifest()
        var scene = manifest["scene"] as! [String: Any]
        var meshes = scene["meshes"] as! [[String: Any]]
        meshes[0]["resourceID"] = "missing"
        scene["meshes"] = meshes
        manifest["scene"] = scene
        XCTAssertThrowsError(try C04CadPackageValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? C04CadError, C04CadError.invalidPackage)
        }

        manifest = packageManifest(meshVersion: 1)
        scene = manifest["scene"] as! [String: Any]
        meshes = scene["meshes"] as! [[String: Any]]
        meshes[0]["transform"] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 9, 9, 9, 1]
        scene["meshes"] = meshes
        manifest["scene"] = scene
        XCTAssertThrowsError(try C04CadPackageValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? C04CadError, C04CadError.invalidPackage)
        }
    }

    // MARK: - Bridge wire

    func testBridgeHandshakeAndClosedLifecycle() throws {
        C04CadSessionRegistry.shared.resetForTesting()
        let handshake = try C04CadBridge.handle(
            requestData: try JSONSerialization.data(withJSONObject: [
                "version": 8, "operation": "handshake", "requestID": "test",
            ]),
            fallbackRequestID: nil)
        XCTAssertEqual(handshake["ok"] as? Bool, true)
        XCTAssertEqual(handshake["version"] as? Int, 8)
        XCTAssertEqual(handshake["schema"] as? String, "floe.cad/8")

        let owner = try owner()
        let begin: [String: Any] = [
            "version": 8, "operation": "c04.session.begin", "requestID": "begin",
            "owner": [
                "taskID": owner.taskID.uuidString,
                "workspaceID": owner.workspaceID.uuidString,
                "nativeEpoch": owner.nativeEpoch,
                "hostGeneration": owner.hostGeneration,
            ],
            "relativePath": "drawings/plate.dxf",
            "format": "dxf",
            "sourceBytes": 128,
            "resources": [],
        ]
        let beginResponse = try C04CadBridge.handle(
            requestData: try JSONSerialization.data(withJSONObject: begin),
            fallbackRequestID: nil)
        XCTAssertEqual(beginResponse["ok"] as? Bool, true)
        let sessionID = try XCTUnwrap(beginResponse["sessionID"] as? String)

        let readiness: [String: Any] = [
            "version": 8, "operation": "c04.session.readiness", "requestID": "ready",
            "sessionID": sessionID,
            "facts": [
                "format": "dxf", "sourceUnits": "unknown", "displayUnits": "unknown",
                "bounds": ["min": [0, 0, 0], "max": [10, 10, 0]],
                "entityCount": 3, "meshCount": 0, "triangleCount": 0,
                "vertexCount": 0, "missingResourceCount": 0,
                "frameSequence": 1, "limitations": "test",
                "rendered": true,
            ],
        ]
        let readyResponse = try C04CadBridge.handle(
            requestData: try JSONSerialization.data(withJSONObject: readiness),
            fallbackRequestID: nil)
        XCTAssertEqual(readyResponse["ok"] as? Bool, true)
        XCTAssertEqual(readyResponse["readiness"] as? String, "rendered")

        let capture: [String: Any] = [
            "version": 8, "operation": "c04.session.capture", "requestID": "capture",
            "sessionID": sessionID,
            "pngHeaderHex": pngHeaderHex(width: 640, height: 480),
            "pngSHA256": String(repeating: "c", count: 64),
            "byteCount": 2_048, "pixelWidth": 640, "pixelHeight": 480,
            "frameSequence": 1,
        ]
        let captureResponse = try C04CadBridge.handle(
            requestData: try JSONSerialization.data(withJSONObject: capture),
            fallbackRequestID: nil)
        XCTAssertEqual(captureResponse["ok"] as? Bool, true)
        let receipt = try XCTUnwrap(captureResponse["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["attested"] as? Bool, true)
        XCTAssertEqual(receipt["pixelWidth"] as? Int, 640)

        let end: [String: Any] = [
            "version": 8, "operation": "c04.session.end", "requestID": "end",
            "sessionID": sessionID,
        ]
        let endResponse = try C04CadBridge.handle(
            requestData: try JSONSerialization.data(withJSONObject: end),
            fallbackRequestID: nil)
        XCTAssertEqual(endResponse["ok"] as? Bool, true)
        C04CadSessionRegistry.shared.resetForTesting()
    }
}
