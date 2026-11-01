// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 contract tests — AUTHORED, NOT RUN in the contracts09 package.
//
// These tests freeze the cross-language R2 wire surface: BridgeV6 action
// closure, exact video command names/keys mapped to the existing shared
// transaction engine, actual VideoTimeline Codable keys, generation DTOs that
// never expose a provider task ID, design action/state DTOs and the bounded
// render-ticket descriptor. Main runs them with the integrated batch.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeAndroidWorkbench

final class G09R2ContractTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        try object(G09CreativeWire.encoder().encode(value))
    }

    // MARK: - Bridge / limits

    func testBridgeV6ClosedActionListAndLimits() {
        XCTAssertEqual(BridgeV6.version, 6)
        XCTAssertEqual(BridgeV6.schema, "floe.creative/6")
        XCTAssertEqual(BridgeV6.maximumRequestBytes, 65_536)
        XCTAssertEqual(BridgeV6.maximumResponseBytes, 16 * 1024 * 1024)
        // CONTRACT FREEZE V2 (Main authorization 2026-11-01): the list grew
        // from 31 to 34 by the three additive large-import actions ONLY. All
        // previous action names and every limit below stay unchanged.
        XCTAssertEqual(BridgeV6.actions.count, 34)
        XCTAssertEqual(BridgeV6.actionSet.count, BridgeV6.actions.count)
        for required in ["media.video.load", "media.video.apply",
                         "generation.models", "generation.candidates.accept",
                         "design.canvas.snapshot", "design.owner.preview"] {
            XCTAssertTrue(BridgeV6.actionSet.contains(required), required)
        }
        for added in ["media.largeImport.submit", "media.largeImport.status",
                      "media.largeImport.cancel"] {
            XCTAssertTrue(BridgeV6.actionSet.contains(added), added)
        }
        XCTAssertEqual(
            BridgeV6.actions.filter { $0.hasPrefix("media.largeImport.") },
            ["media.largeImport.submit", "media.largeImport.status",
             "media.largeImport.cancel"])
        XCTAssertEqual(BridgeV6.version, 6)
        XCTAssertEqual(BridgeV6.schema, "floe.creative/6")
        XCTAssertEqual(G09R2CreativeLimits.requestBytes, 65_536)
        XCTAssertEqual(G09R2CreativeLimits.responseBytes, 16 * 1024 * 1024)
        XCTAssertEqual(G09R2CreativeLimits.mediaProjectBytes, 8 * 1024 * 1024)
        XCTAssertEqual(G09R2CreativeLimits.canvasProjectBytes, 15 * 1024 * 1024)
        XCTAssertEqual(G09R2CreativeLimits.renderDescriptorBytes, 65_536)
        XCTAssertEqual(G09R2CreativeLimits.renderReplyBytes, 1_048_576)
        XCTAssertEqual(G09R2CreativeLimits.maxLiveRenderTickets, 2)
        XCTAssertEqual(G09R2CreativeLimits.importImageBytes, 128 * 1024 * 1024)
        XCTAssertEqual(G09R2CreativeLimits.importAudioBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(G09R2CreativeLimits.importVideoBytes, 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(G09R2CreativeLimits.canvasGenericAssetBytes, 64 * 1024 * 1024)

        let codes = [
            G09R2WireError.generationUnavailable, .modelUnavailable, .providerRejected,
            .renderUnsupported, .designConflict, .designPublicationPending,
        ].map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertFalse(codes.contains(""))
    }

    func testLargeImportPolicyAndTypedRefusalConstants() {
        XCTAssertTrue(G09R2LargeImportPolicy.accepts(.image, byteCount: 128 * 1024 * 1024))
        XCTAssertFalse(G09R2LargeImportPolicy.accepts(.image, byteCount: 128 * 1024 * 1024 + 1))
        XCTAssertTrue(G09R2LargeImportPolicy.accepts(.audio, byteCount: 1024 * 1024 * 1024))
        XCTAssertTrue(G09R2LargeImportPolicy.accepts(.video, byteCount: 8 * 1024 * 1024 * 1024))
        XCTAssertFalse(G09R2LargeImportPolicy.accepts(.video, byteCount: 0))
        XCTAssertEqual(
            G09R2LargeImportPolicy.requiredFreeBytes(sourceBytes: 1024),
            Int64(2 * 1024 + 512 * 1024 * 1024))
        XCTAssertEqual(G09R2LargeImportPolicy.requiredFreeBytes(sourceBytes: 0), 0)
        XCTAssertEqual(G09R2WireError.unsupportedCodec.code, "unsupportedCodec")
        XCTAssertEqual(G09R2WireError.unsupportedTransition.code, "unsupportedTransition")
        XCTAssertEqual(G09R2WireError.unsupportedSourceFormat.code, "unsupportedSourceFormat")
    }

    // MARK: - Video command wire

    private let clipID = "11111111-1111-1111-1111-111111111111"
    private let assetID = "22222222-2222-2222-2222-222222222222"

    func testAppendClipDecodesActualVideoClipKeysIntoSharedCommand() throws {
        let json = """
        {"type":"appendClip","clip":{
          "id":"\(clipID)","assetID":"\(assetID)","trimStart":0.5,"trimEnd":4.0,
          "speed":1.25,"volume":0.8,"isMuted":false,"rotationDegrees":90.0,
          "crop":{"x":0.1,"y":0.2,"width":0.5,"height":0.6},
          "leadingTransition":"crossDissolve","transitionDuration":0.5}}
        """
        let command = try G09CreativeWire.decoder().decode(
            G09R2VideoCommandWire.self, from: Data(json.utf8))
        guard case .appendClip(let clip) = command.sharedCommand() else {
            return XCTFail("appendClip must map to the shared command")
        }
        XCTAssertEqual(clip.id.uuidString.lowercased(), clipID)
        XCTAssertEqual(clip.assetID.uuidString.lowercased(), assetID)
        XCTAssertEqual(clip.trimStart, 0.5)
        XCTAssertEqual(clip.trimEnd, 4.0)
        XCTAssertEqual(clip.speed, 1.25)
        XCTAssertEqual(clip.leadingTransition, .crossDissolve)
        XCTAssertEqual(clip.crop?.width, 0.5)
    }

    func testUpdateClipCropKeepsThreeWayStateAndSharedLabels() throws {
        let json = """
        {"type":"updateClip","id":"\(clipID)","speed":2.0,
         "crop":{"state":"clear"},"transitionDuration":0.25}
        """
        let command = try G09CreativeWire.decoder().decode(
            G09R2VideoCommandWire.self, from: Data(json.utf8))
        guard case .updateClip(let id, let trimStart, let trimEnd, let speed,
                               let volume, let isMuted, let rotation,
                               let crop, let transition, let duration) = command.sharedCommand() else {
            return XCTFail("updateClip must map to the shared command")
        }
        XCTAssertEqual(id.uuidString.lowercased(), clipID)
        XCTAssertNil(trimStart)
        XCTAssertNil(trimEnd)
        XCTAssertEqual(speed, 2.0)
        XCTAssertNil(volume)
        XCTAssertNil(isMuted)
        XCTAssertNil(rotation)
        guard case .clear = crop else { return XCTFail("crop must be clear") }
        XCTAssertNil(transition)
        XCTAssertEqual(duration, 0.25)
    }

    func testAllVideoCommandNamesDecodeAndMapToExistingEngine() throws {
        XCTAssertEqual(G09R2VideoCommandKind.allCases.count, 17)
        let decoder = G09CreativeWire.decoder()
        let samples: [String: String] = [
            "setCover": #"{"type":"setCover"}"#,
            "setPrimaryAudio": #"{"type":"setPrimaryAudio","volume":0.5,"muted":true}"#,
            "shiftCaptions": #"{"type":"shiftCaptions","bySeconds":1.5}"#,
            "reorderClips": #"{"type":"reorderClips","orderedIDs":[]}"#,
            "removeMusic": #"{"type":"removeMusic","id":"\#(clipID)"}"#,
            "removeCaption": #"{"type":"removeCaption","id":"\#(clipID)"}"#,
            "setCanvas": #"{"type":"setCanvas","width":1920,"height":1080,"frameRate":30}"#,
        ]
        for (name, json) in samples {
            let command = try decoder.decode(G09R2VideoCommandWire.self, from: Data(json.utf8))
            _ = command.sharedCommand()
            XCTAssertFalse(name.isEmpty)
        }
        let coverCommand = try decoder.decode(
            G09R2VideoCommandWire.self, from: Data(#"{"type":"setCover"}"#.utf8)).sharedCommand()
        guard case .setCover(nil) = coverCommand else {
            return XCTFail("setCover without time must map to nil")
        }
        let canvasCommand = try decoder.decode(
            G09R2VideoCommandWire.self,
            from: Data(#"{"type":"setCanvas","width":1920,"height":1080,"frameRate":30}"#.utf8)
        ).sharedCommand()
        guard case .setCanvas(let width, let height, let frameRate) = canvasCommand else {
            return XCTFail("setCanvas must map to the shared command")
        }
        XCTAssertEqual(width, 1920)
        XCTAssertEqual(height, 1080)
        XCTAssertEqual(frameRate, 30)
    }

    // MARK: - Actual VideoTimeline Codable keys

    func testVideoTimelineEncodingUsesActualSwiftModelKeys() throws {
        let timeline = VideoTimeline(
            clips: [VideoClip(
                id: UUID(uuidString: clipID)!, assetID: UUID(uuidString: assetID)!,
                trimStart: 0, trimEnd: 2, speed: 1, volume: 1,
                isMuted: false, rotationDegrees: 0, crop: .unit,
                leadingTransition: .crossDissolve, transitionDuration: 0.4)],
            music: [MusicClip(
                id: UUID(), assetID: UUID(), offsetSeconds: 0, trimStart: 0,
                lengthSeconds: 2, volume: 0.5, fadeInSeconds: 0.2, fadeOutSeconds: 0.3)],
            captions: [CaptionSegment(
                id: UUID(), start: 0, end: 1.5, text: "Hi", source: .manual)],
            captionStyle: CaptionStyle(
                fontSize: 36, colorHex: "#FFFFFF", backgroundHex: "#000000",
                positionY: 0.9, alignment: .center, respectsSafeArea: true),
            coverTime: 1.5, primaryVolume: 0.7, primaryMuted: false)

        let encoded = try encode(timeline)
        XCTAssertEqual(Set(encoded.keys), Set([
            "clips", "music", "captions", "captionStyle",
            "coverTime", "primaryVolume", "primaryMuted"]))
        let clip = try XCTUnwrap((encoded["clips"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(clip.keys), Set([
            "id", "assetID", "trimStart", "trimEnd", "speed", "volume", "isMuted",
            "rotationDegrees", "crop", "leadingTransition", "transitionDuration"]))
        let music = try XCTUnwrap((encoded["music"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(music.keys), Set([
            "id", "assetID", "offsetSeconds", "trimStart", "lengthSeconds",
            "volume", "fadeInSeconds", "fadeOutSeconds"]))
        let caption = try XCTUnwrap((encoded["captions"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(caption.keys), Set(["id", "start", "end", "text", "source"]))
        let style = try XCTUnwrap(encoded["captionStyle"] as? [String: Any])
        XCTAssertEqual(Set(style.keys), Set([
            "fontSize", "colorHex", "backgroundHex", "positionY",
            "alignment", "respectsSafeArea"]))
    }

    // MARK: - Generation / ownership DTOs

    func testGenerationContextIsExplicitAndJobStatusHidesProviderTaskID() throws {
        let context = G09R2ProjectContextDTO(
            projectID: UUID(), sessionToken: "session-1",
            storage: G09StorageLayerDTO(kind: .appOwned), origin: nil)
        let contextObject = try encode(context)
        XCTAssertEqual(Set(contextObject.keys), Set([
            "projectID", "sessionToken", "storage"]))
        XCTAssertEqual((contextObject["storage"] as? [String: Any])?["kind"] as? String, "appOwned")

        let job = G09R2JobStatusDTO(
            jobID: "job-1", projectID: UUID(), state: .waitingForProvider,
            updatedAt: Date(), progressHint: 0.25, resultAvailable: false,
            providerTaskReferencePresent: true, lastErrorCode: nil,
            retryable: false, canCancel: true)
        let jobObject = try encode(job)
        XCTAssertEqual(jobObject["providerTaskReferencePresent"] as? Bool, true)
        XCTAssertNil(jobObject["providerTaskID"])
        XCTAssertFalse(jobObject.keys.contains { $0.lowercased().contains("taskid") })
        XCTAssertEqual(G09R2MediaJobState.allCases.count, 9)
        XCTAssertEqual(G09R2ImageRequestState.allCases.count, 7)
        XCTAssertEqual(G09R2CandidateState.allCases.count, 4)
        XCTAssertEqual(G09R2CandidateDeliveryOutcome.allCases.count, 3)
    }

    func testImageSubmitCarriesRevisionOpIDAndStableIdempotencyKey() throws {
        let json = """
        {"context":{"projectID":"\(clipID)","sessionToken":"s",
          "storage":{"kind":"appOwned"}},
         "expectedRevision":7,"opID":"op-1",
         "request":{"prompt":"p","modelRouteID":"route-1","count":1,
           "referenceAssetIDs":[],"idempotencyKey":"idem-1"}}
        """
        let request = try G09CreativeWire.decoder().decode(
            G09R2ImageSubmitRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.expectedRevision, 7)
        XCTAssertEqual(request.opID, "op-1")
        XCTAssertEqual(request.request.idempotencyKey, "idem-1")
        XCTAssertEqual(request.context.storage.kind, .appOwned)
    }

    // MARK: - Design

    func testDesignActionVocabularyMatchesBridgeV6() {
        let designActions = G09R2DesignAction.allCases.map(\.rawValue)
        let listed = BridgeV6.actions.filter { $0.hasPrefix("design.") }
        XCTAssertEqual(designActions, listed)
        XCTAssertEqual(Set(designActions).count, designActions.count)
        XCTAssertEqual(designActions.count, 18)
        XCTAssertTrue(designActions.contains("design.canvas.adopt"))
        XCTAssertTrue(designActions.contains("design.owner.preview"))
    }

    func testDesignStateUsesSharedEnvelopeAndPreviewReceiptIsVerified() throws {
        let target = DesignTarget(
            kind: .fileDocument, ownerID: "workspace-1", documentID: "doc-1",
            sourceID: "notes.md", revision: "rev-1")
        let project = DesignProject(nodeID: target.stableKey, contentType: .notes)
        let envelope = DesignOwnerEnvelope(target: target, project: project, revision: 3)
        let state = G09R2DesignStateDTO(
            envelope: envelope, writable: true, warnings: [], availableActions: [])
        let stateObject = try encode(state)
        XCTAssertEqual(Set(stateObject.keys), Set([
            "envelope", "writable", "warnings", "availableActions"]))
        let envelopeObject = try XCTUnwrap(stateObject["envelope"] as? [String: Any])
        XCTAssertEqual((envelopeObject["revision"] as? NSNumber)?.intValue, 3)
        let projectObject = try XCTUnwrap(envelopeObject["project"] as? [String: Any])
        XCTAssertEqual(projectObject["nodeID"] as? String, target.stableKey)

        let receipt = G09R2DesignPreviewReceiptDTO(
            target: target, ownerRevision: 3, candidateID: "c-1", revisionID: "r-2",
            format: "png",
            // Native-issued trusted root: an explicit virtual fixture string.
            // No filesystem access happens in this contract test.
            rootPath: "/fixture/design-root",
            relativePath: "DesignPreviews/r-2.png",
            byteCount: 1234, sha256: String(repeating: "a", count: 64),
            width: 640, height: 480, createdAt: Date())
        let receiptObject = try encode(receipt)
        XCTAssertEqual(receiptObject["rootPath"] as? String, "/fixture/design-root")
        XCTAssertEqual(receiptObject["relativePath"] as? String, "DesignPreviews/r-2.png")
        XCTAssertEqual(receiptObject["sha256"] as? String, String(repeating: "a", count: 64))
        XCTAssertNil(receiptObject["success"])
    }

    // MARK: - Render ticket

    func testRenderTicketDescriptorCarriesSnapshotLeaseNotProjectJSON() throws {
        XCTAssertEqual(G09R2CreativeLimits.renderDescriptorBytes, 64 * 1024)
        let binding = G09R2MediaExportBindingDTO(
            context: G09R2ProjectContextDTO(
                projectID: UUID(), sessionToken: "s",
                storage: G09StorageLayerDTO(kind: .appOwned)),
            mediaRootPath: "/trusted/root", projectRevision: 4,
            timelineDigest: "digest", attemptID: "attempt-1",
            snapshot: G09R2RenderSnapshotLeaseDTO(
                leaseID: "lease-1", mediaRootPath: "/trusted/root",
                relativePath: "Snapshots/p4.json",
                sha256: String(repeating: "b", count: 64),
                byteCount: 4096, expiresAt: Date()))
        let descriptor = G09R2RenderTicketDescriptorDTO(
            ticketID: "ticket-1", descriptorVersion: 1, kind: .video,
            projectID: binding.context.projectID,
            attemptID: "attempt-1",
            mediaRootPath: "/trusted/root",
            storage: G09StorageLayerDTO(kind: .appOwned), origin: nil,
            projectRevision: 4,
            timelineDigest: "digest", leaseID: "lease-1", ownerReference: "owner-1",
            epoch: 9, snapshotRelativePath: "Snapshots/p4.json",
            snapshotSHA256: String(repeating: "b", count: 64),
            snapshotByteCount: 4096, snapshotLeaseExpiresAt: Date(),
            outputRelativePath: "Workbench/Exports/a.mp4",
            videoSettings: G09R2VideoExportSettingsDTO(
                codecMime: "video/avc", width: 1920, height: 1080,
                frameRate: 30, quality: 0.9, fileName: "a"),
            imageSettings: nil, previewWindow: nil, expiresAt: Date(),
            descriptorByteCount: 512)
        let object = try encode(descriptor)
        XCTAssertEqual(object["snapshotRelativePath"] as? String, "Snapshots/p4.json")
        XCTAssertEqual(object["mediaRootPath"] as? String, "/trusted/root")
        XCTAssertEqual(object["attemptID"] as? String, "attempt-1")
        XCTAssertEqual((object["storage"] as? [String: Any])?["kind"] as? String, "appOwned")
        XCTAssertNotNil(object["snapshotLeaseExpiresAt"])
        XCTAssertNil(object["project"])
        XCTAssertEqual(object["leaseID"] as? String, "lease-1")

        let capability = G09R2MediaProjectToolExportCapabilityDTO(
            route: .renderTicket, registered: false,
            reason: "not registered in the contract package",
            supportedActions: ["read", "propose", "apply", "export"])
        let capabilityObject = try encode(capability)
        XCTAssertEqual(capabilityObject["route"] as? String, "renderTicket")
        XCTAssertEqual(G09R2RenderTicketReplyStatus.allCases.count, 5)
        XCTAssertEqual(G09R2MediaExportRoute.unavailable.rawValue, "unavailable")
    }
}
