// SPDX-License-Identifier: MPL-2.0
//
// C03 image closure — model/UI raster consistency (source-authored, NOT RUN).
//
// These tests pin the shared contract that let the model copy path use the
// SAME post-composite order as the App UI and fixed iOS:
//
//   source layer (own mask/adjustment/transform)
//   -> whole-canvas adjustment
//   -> complete project selection mask
//
// The pixel comparison itself needs the real Android Bitmap/Canvas renderer
// and is a Main instrumented/device gate. These tests prove there is no
// pre-adjustment region-mask substitution left in the model projection and
// that capability is derived from the actual bound render-ticket consumer.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeAndroidWorkbench

final class C03ModelRasterConsistencyTests: XCTestCase {
    private let sourceID = UUID()
    private let selection = ImageSelection(shapes: [
        ImageSelectionShape(kind: .rectangle, points: [
            .init(x: 0.15, y: 0.2), .init(x: 0.7, y: 0.8),
        ]),
    ], feather: 0.05, inverted: false)

    // MARK: - Model copy projection

    func testModelCopyKeepsSourceMaskAndSelectionForPostCompositeOrder() throws {
        let source = ImageLayer(
            kind: .fill, name: "Source",
            mask: ImageLayerMask(strokes: [
                ImageMaskStroke(points: [
                    .init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.4),
                ], width: 8),
            ]),
            fillColorHex: "#3366FF")
        let project = MediaProject(
            kind: .image, name: "Copy", canvas: MediaCanvas(width: 96, height: 64),
            imageLayers: [source],
            canvasAdjustment: CanvasAdjustment(
                saturation: 1.4, blurRadius: 3, temperature: 7200),
            imageSelection: selection)
        let rendered = try G09R2MediaProjectToolHost.copySelectionProjection(
            project: project, sourceLayerID: source.id)

        XCTAssertEqual(rendered.id, project.id)
        XCTAssertEqual(rendered.revision, project.revision)
        XCTAssertEqual(rendered.imageLayers.map(\.id), [source.id])
        // The render purpose is the typed ticket field and the verified
        // project selection; it must never be materialized as an erase stroke
        // that the ordinary layer pipeline would apply BEFORE the adjustment.
        XCTAssertEqual(rendered.imageLayers[0].mask, source.mask)
        XCTAssertEqual(rendered.imageLayers[0].selectionMask, source.selectionMask)
        XCTAssertEqual(rendered.imageSelection, selection)
        XCTAssertFalse(rendered.canvasAdjustment.isIdentity)
        XCTAssertEqual(rendered.canvasAdjustment, project.canvasAdjustment)
        // The source project value is immutable.
        XCTAssertEqual(project.imageLayers[0].mask, source.mask)
        XCTAssertEqual(project.imageSelection, selection)

        let purpose = G09R2ImageCopySelectionDTO(sourceLayerID: source.id)
        let object = try G09CreativeWire.object(purpose)
        XCTAssertEqual(object["sourceLayerID"] as? String, source.id.uuidString)
    }

    func testModelCopyRefusesMissingLockedHiddenOrUnshapedInputs() throws {
        let canvas = MediaCanvas(width: 64, height: 48)
        let base = ImageLayer(kind: .fill, name: "Base", fillColorHex: "#FFFFFF")
        func project(
            layer: ImageLayer,
            selection: ImageSelection?
        ) -> MediaProject {
            MediaProject(
                kind: .image, name: "Copy", canvas: canvas,
                imageLayers: [layer], imageSelection: selection)
        }
        XCTAssertThrowsError(try G09R2MediaProjectToolHost.copySelectionProjection(
            project: project(layer: base, selection: selection),
            sourceLayerID: UUID()))

        var locked = base
        locked.isLocked = true
        XCTAssertThrowsError(try G09R2MediaProjectToolHost.copySelectionProjection(
            project: project(layer: locked, selection: selection),
            sourceLayerID: base.id))

        var hidden = base
        hidden.isHidden = true
        XCTAssertThrowsError(try G09R2MediaProjectToolHost.copySelectionProjection(
            project: project(layer: hidden, selection: selection),
            sourceLayerID: base.id))

        XCTAssertThrowsError(try G09R2MediaProjectToolHost.copySelectionProjection(
            project: project(layer: base, selection: nil),
            sourceLayerID: base.id))

        XCTAssertThrowsError(try G09R2MediaProjectToolHost.copySelectionProjection(
            project: project(
                layer: base,
                selection: ImageSelection(shapes: [], feather: 0, inverted: false)),
            sourceLayerID: base.id))
    }

    func testTicketCarriesTheCopyPurposeOnlyWhenExplicitlyRequested() throws {
        var ordinary = descriptor(copySelection: nil)
        let ordinaryData = try G09R2MediaToolExport.encodeDescriptor(&ordinary)
        let ordinaryObject = try jsonObject(ordinaryData)
        XCTAssertNil(ordinaryObject["copySelection"])

        var copy = descriptor(
            copySelection: G09R2ImageCopySelectionDTO(sourceLayerID: sourceID))
        let copyData = try G09R2MediaToolExport.encodeDescriptor(&copy)
        let copyObject = try jsonObject(copyData)
        let purpose = copyObject["copySelection"] as? [String: Any]
        XCTAssertEqual(
            purpose?["sourceLayerID"] as? String, sourceID.uuidString)
        XCTAssertEqual(copy.descriptorByteCount, copyData.count)
    }

    // MARK: - Capability reflects the real binding

    func testCapabilityIsTrueOnlyForALiveBoundRenderConsumer() {
        let mailbox = G09R2MediaRenderHostMailbox()
        let availability = G09R2MediaToolAvailability(mailbox: mailbox)
        defer {
            _ = mailbox.prepareRootStop(epoch: 42)
            availability.markUnbound(epoch: 42)
        }

        let unbound = G09R2MediaToolRegistration.capability(availability: availability)
        XCTAssertFalse(unbound.mergeLayers)
        XCTAssertFalse(unbound.copySelection)
        XCTAssertFalse(unbound.fillSelection)
        XCTAssertFalse(unbound.cutSelection)
        XCTAssertEqual(unbound.enrichmentReasons["merge_layers"], "notBound")
        XCTAssertEqual(unbound.enrichmentReasons["fill_selection"], "notBound")

        XCTAssertTrue(mailbox.bind(epoch: 42))
        availability.markBound(epoch: 42)
        let boundOnly = G09R2MediaToolRegistration.capability(availability: availability)
        XCTAssertTrue(
            boundOnly.fillSelection,
            "fill/cut only need the bound native command/CAS backend")
        XCTAssertTrue(boundOnly.cutSelection)
        XCTAssertFalse(
            boundOnly.mergeLayers,
            "bind alone is not proof that the render consumer is alive")
        XCTAssertFalse(boundOnly.copySelection)

        XCTAssertTrue(mailbox.consumerHeartbeat(epoch: 42))
        let ready = G09R2MediaToolRegistration.capability(availability: availability)
        XCTAssertTrue(ready.available)
        XCTAssertTrue(ready.consumerReady)
        XCTAssertTrue(ready.fillSelection)
        XCTAssertTrue(ready.cutSelection)
        XCTAssertTrue(ready.mergeLayers)
        XCTAssertTrue(ready.copySelection)
        XCTAssertTrue(ready.enrichmentReasons.isEmpty)

        availability.markStopping(epoch: 42)
        let stopping = G09R2MediaToolRegistration.capability(availability: availability)
        XCTAssertFalse(stopping.available)
        XCTAssertFalse(stopping.mergeLayers)
        XCTAssertFalse(stopping.copySelection)
        XCTAssertEqual(stopping.reason, "rootStopping")
    }

    // MARK: - Fixtures

    private func descriptor(
        copySelection: G09R2ImageCopySelectionDTO?
    ) -> G09R2RenderTicketDescriptorDTO {
        G09R2RenderTicketDescriptorDTO(
            ticketID: "ticket-c03-copy",
            descriptorVersion: 1,
            kind: .image,
            projectID: UUID(),
            attemptID: "c03-copy-test",
            mediaRootPath: "/trusted/root",
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: nil,
            projectRevision: 3,
            timelineDigest: "digest",
            leaseID: "lease-c03-copy",
            ownerReference: "owner",
            epoch: 42,
            snapshotRelativePath: "Workbench/Snapshots/lease-c03-copy.json",
            snapshotSHA256: String(repeating: "a", count: 64),
            snapshotByteCount: 128,
            snapshotLeaseExpiresAt: Date().addingTimeInterval(600),
            outputRelativePath: "Workbench/Exports/c03-copy-test.png",
            videoSettings: nil,
            imageSettings: G09R2ImageExportSettingsDTO(
                format: "png", width: 96, height: 64, quality: 1,
                preserveTransparency: true, stripMetadata: true,
                fileName: "c03-copy-test"),
            previewWindow: nil,
            expiresAt: Date().addingTimeInterval(600),
            descriptorByteCount: 0,
            copySelection: copySelection)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
