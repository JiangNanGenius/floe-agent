// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeCAD
#if canImport(RealityKit) && canImport(UIKit)
import UIKit
import Darwin
import ImageIO

@MainActor
final class CADStillRenderTests: XCTestCase {
    private var root: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StillRender-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        documents.forEach { $0.close() }; documents = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func document() async throws -> FloeCADDocument {
        let d = try await FloeCADDocument.create(at: root.appendingPathComponent("model.floecad"), name: "Still render")
        documents.append(d)
        let r = d.executeJSON(Data(#"{"op":"sketch.create","args":{"name":"Slab"}}"#.utf8)); XCTAssertTrue(r.isOK)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.payload) as? [String: Any])
        let id = try XCTUnwrap(object["sketchID"] as? String)
        for command in [
            "{\"op\":\"sketch.addEntities\",\"args\":{\"sketchID\":\"\(id)\",\"entities\":[{\"kind\":\"rect\",\"min\":[-10,-10],\"max\":[10,10]}]}}",
            "{\"op\":\"feature.extrude\",\"args\":{\"sketchID\":\"\(id)\",\"seedPoint\":[0,0],\"distance\":20}}"
        ] { let reply = d.executeJSON(Data(command.utf8)); XCTAssertTrue(reply.isOK, reply.message ?? "") }
        return d
    }
    func testPreferencesPreserveOtherSceneFieldsUndoAndReopen() async throws {
        let d = try await document(); let original = d.stillRenderSettings
        let overlay = d.viewOverlayState
        let settings = CADStillRenderSettings(quality: .standard, width: 960, height: 720, exposureEV: 0.7, saturation: 0.6)
        try d.setStillRenderSettings(settings)
        XCTAssertEqual(d.stillRenderSettings, settings); XCTAssertEqual(d.viewOverlayState, overlay)
        d.session.undo()
        XCTAssertEqual(d.stillRenderSettings, original)
        try d.setStillRenderSettings(settings)
        let save = await d.save(); XCTAssertTrue(save.succeeded, save.error ?? "")
        let url = d.url; d.close()
        let reopened = try await FloeCADDocument.open(at: url); documents.append(reopened)
        XCTAssertEqual(reopened.stillRenderSettings, settings)
        let before = reopened.session.document.sceneSettingsData
        var invalid = settings; invalid.exposureEV = .nan
        XCTAssertThrowsError(try reopened.setStillRenderSettings(invalid))
        XCTAssertEqual(reopened.session.document.sceneSettingsData, before)
    }
    private func image(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 512) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: width), format: format).image { context in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill(); context.fill(CGRect(x: 0,y: 0,width: width,height: width))
        }.cgImage!
    }
    private func decoded(_ bytes: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func center(_ image: CGImage) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0,y: 0,width: 1,height: 1)); return pixel
    }
    func testLinearExposureSaturationAndSRGBOutputUseActualSourcePixels() throws {
        var settings = CADStillRenderSettings(width: 256, height: 256)
        let source = image(red: 0.5, green: 0.5, blue: 0.5)
        let base = try decoded(CADStillRenderPixels.process(image: source, settings: settings))
        XCTAssertEqual(base.width,256); XCTAssertEqual(base.height,256)
        settings.exposureEV = 1
        let bright = try center(decoded(CADStillRenderPixels.process(image: source, settings: settings)))
        // +1EV in linear light turns middle sRGB gray into ~0.686, not 1.0.
        XCTAssertEqual(Double(bright[0]), 175, accuracy: 5)
        settings.exposureEV = 0; settings.saturation = 0
        let gray = try center(decoded(CADStillRenderPixels.process(image: image(red: 0.8,green: 0.3,blue: 0.1), settings: settings)))
        XCTAssertEqual(Double(gray[0]),Double(gray[1]),accuracy: 1); XCTAssertEqual(Double(gray[1]),Double(gray[2]),accuracy: 1)
        XCTAssertEqual(gray[3],255)
        XCTAssertThrowsError(try CADStillRenderPixels.process(image: image(red: 0.5,green: 0.5,blue: 0.5,width: 256), settings: settings),
                             "Detailed export may not enlarge a one-sample-per-pixel source")
    }
    func testActualRealityKitDetailedRenderAndCancelThenRestart() async throws {
        let d = try await document()
        let settings = CADStillRenderSettings(width: 512, height: 384)
        let service = CADStillRenderService()
        let cancelled = Task { @MainActor in try await service.render(document: d, settings: settings) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled render returned output") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let baselineFootprint = footprint()
        let output = try await service.render(document: d, settings: settings)
        let completedFootprint = footprint()
        XCTAssertGreaterThanOrEqual(output.sourceWidth,1024); XCTAssertGreaterThanOrEqual(output.sourceHeight,768)
        XCTAssertEqual(output.width,512); XCTAssertEqual(output.height,384)
        XCTAssertEqual(output.sourceSHA256,d.contentSHA256)
        XCTAssertEqual(output.imageSHA256,CADMaterialTexture.digest(output.png))
        XCTAssertEqual(try decoded(output.png).width,512)
        let pixels = try center(decoded(output.png)); XCTAssertTrue(pixels.prefix(3).contains { $0 > 0 })
        let a = XCTAttachment(data: output.png, uniformTypeIdentifier: "public.png");a.name="Actual-RealityKit-Detailed-Still";a.lifetime = .keepAlways;add(a)
        let metadata = "source=\(output.sourceWidth)x\(output.sourceHeight);output=512x384;seconds=\(output.elapsedSeconds);sha=\(output.imageSHA256);footprintBefore=\(baselineFootprint);footprintAfter=\(completedFootprint);scope=actual-test-host-samples-not-peak-or-physical-device"
        let m = XCTAttachment(string: metadata);m.name="Still-Render-Actual-Metrics";m.lifetime = .keepAlways;add(m)
    }
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

}
#endif
