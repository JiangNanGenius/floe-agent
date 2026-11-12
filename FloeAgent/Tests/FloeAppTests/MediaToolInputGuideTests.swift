// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeWorkbench
@testable import FloeApp

@Suite("Native media example payloads",.serialized)
@MainActor struct MediaToolInputGuideTests {
    @Test func newMediaExamplesDecodeAgainstTheActualAppToolContract() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-tool-guides-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store=MediaProjectStore(directory:root),coordinator=MediaPreparedCoordinator(store:store)
        for kind in [MediaProjectKind.image,.video] {
            var renderedImagePreview = false
            let project=MediaProject(kind:kind,name:"Guide",canvas:.init(width:64,height:48,frameRate:kind == .video ? 30:nil))
            try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
            if kind == .image {
                let asset = try imageAsset(at: root)
                _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset))], to: project.id)
                let layer=MediaPreparedLayer(name:"Source",content:.raster(.init(source:.asset(asset.id))))
                let square=MediaVectorPath(subpaths:[.init(points:[.init(point:.init(x:0.1,y:0.1)),.init(point:.init(x:0.7,y:0.1)),.init(point:.init(x:0.7,y:0.7)),.init(point:.init(x:0.1,y:0.7))],isClosed:true)],fillColorHex:"#0088FF")
                let first=MediaPreparedLayer(name:"First filled shape",content:.vectorPaths(square))
                let second=MediaPreparedLayer(name:"Second filled shape",content:.vectorPaths(square))
                let text=MediaPreparedLayer(name:"Editable text",content:.text(.init(text:"Hi",fontSize:8)))
                let path = openPathLayer()
                let group = MediaPreparedLayer(name: "Editable group", content: .group(.init(isIsolated: true)))
                _ = try await coordinator.applyUserOperations([layer,first,second,text,path,group].map{.init(action:.insertLayer(layer:$0,parentID:nil,index:nil))},to:project.id)
                let session = try await MediaV2Session.open(projectID: project.id, root: root, store: store)
                try await waitForImagePreview(session)
                renderedImagePreview = session.preview != nil
            } else {
                let image=MediaAssetReference(kind:.video,relativePath:"Assets/source.mov",originalName:"Source"),audio=MediaAssetReference(kind:.audio,relativePath:"Assets/source.wav",originalName:"Source audio")
                let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(3))
                let visual=MediaPreparedTrack(kind:.visual,name:"Visual",clips:[.init(assetID:image.id,timelineRange:range,sourceRange:range)])
                let reference=MediaPreparedTrack(kind:.visual,name:"Reference shot",clips:[.init(assetID:image.id,timelineRange:range,sourceRange:range)])
                let sound=MediaPreparedTrack(kind:.audio,name:"Audio",clips:[.init(assetID:audio.id,timelineRange:range,sourceRange:range)])
                let narration=MediaPreparedTrack(kind:.audio,name:"Narration",clips:[.init(assetID:audio.id,timelineRange:range,sourceRange:range)])
                let captions=MediaPreparedTrack(kind:.caption,name:"Caption",clips:[.init(timelineRange:range,sourceRange:range,captionText:"Hello",captionSource:.manual)])
                _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(image)),.init(action:.insertAsset(audio)),.init(action:.insertTrack(track:visual,index:nil)),.init(action:.insertTrack(track:reference,index:nil)),.init(action:.insertTrack(track:sound,index:nil)),.init(action:.insertTrack(track:narration,index:nil)),.init(action:.insertTrack(track:captions,index:nil))],to:project.id)
            }
            // The remove-asset example requires a real unreferenced asset.
            let unused = try imageAsset(at: root, filename: "unused.png")
            _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(unused))], to: project.id)
            let document=try await coordinator.loadDocument(id:project.id)
            let examples=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:MediaV2Session.localToolIDs.union(MediaV2Session.providerToolIDs),selectionFence:String(repeating:"a",count:64),hasImageRegion:true,hasRenderedImagePreview:renderedImagePreview)
            #expect(!examples.isEmpty)
            for example in examples {
                let json=try #require(example.inputJSON)
                let decoded=try StudioMediaToolContract.decode(json)
                #expect(decoded.expectedRevision == document.revision)
                if let object=decoded.objectID {
                    if example.toolID == "image.remove-asset" || example.toolID == "video.remove-asset" {
                        #expect(document.asset(object) != nil)
                        #expect(MediaPreparedAssets.references(to: object, in: document).isEmpty)
                    } else {
                        #expect(document.layer(object) != nil || document.trackGraph.clip(id:object) != nil || document.trackGraph.track(object) != nil)
                    }
                }
            }
            let missing=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:MediaV2Session.localToolIDs,selectionFence:nil)
            #expect(missing.filter(\.requiresSelectionFence).allSatisfy{$0.inputJSON == nil && $0.unavailableReason != nil})
        }
    }

    @Test func addTextCreatesANewLayerWhileApplyEditsOnlyTheSelectedLayerAndReopensUndoably() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-add-text-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let coordinator = MediaPreparedCoordinator(store: store)
        let project = MediaProject(kind: .image, name: "Text creation", canvas: .init(width: 320, height: 200))
        try await store.save(project)
        _ = try await coordinator.upgradeDocument(id: project.id)
        let session = try await MediaV2Session.open(projectID: project.id, root: root, store: store)
        defer { session.stopPlayback() }

        let firstID = try await session.createImageTextLayer()
        var edit = MediaV2ToolInput()
        edit.objectID = firstID; edit.expectedRevision = session.document.revision
        edit.text = "Keep this text"; edit.number = 20
        _ = try await session.performTool("image.text", input: edit)
        let first = try #require(session.document.layer(firstID))
        #expect(session.document.layers.count == 1)

        let secondID = try await session.createImageTextLayer()
        #expect(firstID != secondID && session.document.layers.count == 2)
        #expect(session.document.layer(firstID) == first)
        #expect(session.selectedLayerID == secondID && session.selectedLayerSet == [secondID])
        let coldStore = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let saved = try #require(try await coldStore.loadProject(id: project.id))
        #expect(saved.prepared?.layer(firstID) == first && saved.prepared?.layer(secondID) != nil)

        // Reopen the persisted journal rather than using the upgrade-only
        // coordinator, whose cached envelope predates the session's edits.
        let coldCoordinator = MediaPreparedCoordinator(store: coldStore)
        let group = try #require(saved.preparedJournal?.nextUndo)
        _ = try await coldCoordinator.undoGroup(group.id, in: project.id)
        try await session.reload()
        #expect(session.document.layer(secondID) == nil && session.document.layer(firstID) == first)
        let redo = try #require(session.project.preparedJournal?.nextRedo)
        _ = try await coldCoordinator.redoGroup(redo.id, in: project.id)
        try await session.reload()
        #expect(session.document.layer(secondID) != nil && session.document.layer(firstID) == first)
    }

    @Test func basicImageExamplesDecodeDispatchWithRealTargetsAndFilterVideoTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-basic-guides-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let coordinator = MediaPreparedCoordinator(store: store)
        let project = MediaProject(kind: .image, name: "Basic guides", canvas: .init(width: 320, height: 200))
        try await store.save(project)
        _ = try await coordinator.upgradeDocument(id: project.id)
        let ids: Set<String> = ["image.rectangle", "image.brush", "image.eraser", "image.crop", "image.text", "image.shape", "image.duplicate-layer", "image.group-layer"]
        let empty = try await coordinator.loadDocument(id: project.id)
        let missing = try MediaPreparedToolInputGuide.make(document: empty, implementedToolIDs: ids)
        #expect(missing.count == 8)
        for id in ["image.eraser", "image.crop", "image.duplicate-layer", "image.group-layer"] {
            let item = try #require(missing.first { $0.toolID == id })
            #expect(item.inputJSON == nil && item.unavailableReason?.isEmpty == false)
        }

        let asset = try imageAsset(at: root)
        let source = MediaPreparedLayer(name: "Actual PNG", content: .raster(.init(source: .asset(asset.id))))
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset)), .init(action: .insertLayer(layer: source, parentID: nil, index: nil))], to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id, root: root, store: store)
        defer { session.stopPlayback() }
        for id in ["image.brush", "image.rectangle", "image.eraser", "image.crop", "image.text", "image.shape", "image.duplicate-layer", "image.group-layer"] {
            let observed = try StudioMediaObservation.media(session)
            let examples = try MediaPreparedToolInputGuide.make(document: session.document, implementedToolIDs: ids.union(["video.scopes"]), selectionFence: observed.selectionFence, hasImageRegion: session.selection != nil)
            #expect(examples.count == 8 && examples.allSatisfy { $0.toolID.hasPrefix("image.") })
            let example = try #require(examples.first { $0.toolID == id })
            let input = try StudioMediaToolContract.decode(try #require(example.inputJSON))
            #expect(input.expectedRevision == session.document.revision)
            if let objectID = input.objectID { #expect(session.document.layer(objectID) != nil) }
            if let members = input.objectIDs { #expect(members.allSatisfy { session.document.layer($0) != nil }) }
            if id == "image.eraser" {
                #expect(input.selectionFence == observed.selectionFence)
                let before = session.document
                var stale = input; stale.selectionFence = String(repeating: "0", count: 64)
                do {
                    _ = try await session.performTool(id, input: stale, actor: .model)
                    Issue.record("A stale selection fence must not erase pixels")
                } catch { }
                #expect(session.document == before)
            }
            let receipt = try await session.performTool(id, input: input, actor: .model)
            #expect(receipt.toolID == id)
            #expect(receipt.selectionOnly == (id == "image.rectangle"))
            if id != "image.rectangle" { #expect(receipt.groupID != nil) }
        }
        let saved = try #require(try await store.loadProject(id: project.id))
        #expect(saved.prepared == session.document && saved.prepared?.layer(source.id)?.mask != nil)
        let video = MediaPreparedDocument(id: UUID(), kind: .video, name: "Video filtering")
        let videoExamples = try MediaPreparedToolInputGuide.make(document: video, implementedToolIDs: ids.union(["video.scopes"]))
        #expect(videoExamples.map(\.toolID) == ["video.scopes"])
    }

    @Test func remainingImageGuideEntriesDecodeOrStateActualPrerequisitesAndReachNativeRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-full-guide-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let coordinator = MediaPreparedCoordinator(store: store)
        let project = MediaProject(kind: .image, name: "Remaining input contracts", canvas: .init(width: 320, height: 200))
        try await store.save(project)
        _ = try await coordinator.upgradeDocument(id: project.id)
        let asset = try imageAsset(at: root)
        let source = MediaPreparedLayer(name: "PNG source", content: .raster(.init(source: .asset(asset.id))))
        let drawing = MediaPreparedLayer(name: "Drawing", content: .strokes(.init()))
        let path = openPathLayer()
        let group = MediaPreparedLayer(name: "Group", content: .group(.init(isIsolated: true)))
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset))] + [source,drawing,path,group].map { .init(action: .insertLayer(layer: $0, parentID: nil, index: nil)) }, to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id, root: root, store: store)
        defer { session.stopPlayback() }
        session.selection = .init(shapes: [.init(kind: .rectangle, points: [.init(x: 0.2, y: 0.2), .init(x: 0.6, y: 0.6)])])
        let implemented = MediaV2Session.localToolIDs.union(MediaV2Session.providerToolIDs)
        let catalogueIDs = Set(try MediaPreparedBundledCatalog.load().entries.filter { $0.kind == .image }.map(\.id))
        let observation = try StudioMediaObservation.media(session)
        let examples = try MediaPreparedToolInputGuide.make(document: session.document, implementedToolIDs: implemented, selectionFence: observation.selectionFence, hasImageRegion: true)
        #expect(Set(examples.map(\.toolID)) == catalogueIDs && examples.count == catalogueIDs.count)
        for item in examples {
            guard let json = item.inputJSON else {
                #expect(item.unavailableReason?.isEmpty == false)
                continue
            }
            let input = try StudioMediaToolContract.decode(json)
            #expect(input.expectedRevision == session.document.revision)
            if let id = input.objectID {
                #expect(session.document.layer(id) != nil || session.document.asset(id) != nil)
            }
            if let ids = input.objectIDs { #expect(ids.allSatisfy { session.document.layer($0) != nil }) }
            if item.requiresSelectionFence { #expect(input.selectionFence == observation.selectionFence) }
        }
        // Exercise representative newly described parameter, native-mask and
        // full-path inputs through the real dispatcher, without provider calls.
        for id in ["image.rotate", "image.layer-mask", "image.anchor"] {
            let state = try StudioMediaObservation.media(session)
            let guide = try MediaPreparedToolInputGuide.make(document: session.document, implementedToolIDs: implemented, selectionFence: state.selectionFence, hasImageRegion: session.selection != nil)
            let row = try #require(guide.first { $0.toolID == id })
            let input = try StudioMediaToolContract.decode(try #require(row.inputJSON))
            let receipt = try await session.performTool(id, input: input, actor: .model)
            #expect(receipt.groupID != nil && receipt.toolID == id)
        }
        #expect(session.document.layer(source.id)?.transform.rotationDegrees == 90)
        #expect(session.document.layer(source.id)?.mask?.vector != nil)
        #expect(session.document.layer(path.id)?.contentKind == .vectorPaths)

        let empty = MediaPreparedDocument(id: UUID(), kind: .image, name: "No prerequisites", canvas: .init(width: 64, height: 48))
        let missing = try MediaPreparedToolInputGuide.make(document: empty, implementedToolIDs: implemented)
        #expect(Set(missing.map(\.toolID)) == catalogueIDs)
        for id in ["image.feather", "image.inverse", "image.deselect", "image.layer-mask", "image.vector-mask", "image.clip-mask", "image.blend-mode", "image.merge-layer", "image.anchor", "image.stroke-fill", "image.eyedropper"] {
            let row = try #require(missing.first { $0.toolID == id })
            #expect(row.inputJSON == nil && row.unavailableReason?.isEmpty == false)
        }
        var oversized = empty
        oversized.canvas = .init(width: 8192, height: 8192)
        let large = try MediaPreparedToolInputGuide.make(document: oversized, implementedToolIDs: implemented)
        let outpaint = try #require(large.first { $0.toolID == "image.outpaint" })
        #expect(outpaint.inputJSON == nil && outpaint.unavailableReason?.isEmpty == false)
    }

    @Test func nativeSelectionObservationUsesEffectiveSingleAndMultipleSetsWithoutChangingFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-selection-observation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let coordinator = MediaPreparedCoordinator(store: store)
        let project = MediaProject(kind: .image, name: "Selection observation", canvas: .init(width: 64, height: 48))
        try await store.save(project)
        _ = try await coordinator.upgradeDocument(id: project.id)
        let first = MediaPreparedLayer(name: "First", content: .strokes(.init()))
        let second = MediaPreparedLayer(name: "Primary", content: .strokes(.init()))
        _ = try await coordinator.applyUserOperations([first,second].map { .init(action: .insertLayer(layer: $0, parentID: nil, index: nil)) }, to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id, root: root, store: store)
        defer { session.stopPlayback() }
        #expect(session.selectedLayerID == second.id && session.selectedLayerIDs.isEmpty)
        let initial = try StudioMediaObservation.media(session)
        #expect(initial.selectedLayerIDs == [second.id] && initial.selectedLayerCount == 1)
        let removedID = UUID()
        session.selectedLayerIDs = [first.id, removedID]
        let staleRaw = try StudioMediaObservation.media(session)
        #expect(staleRaw.selectedLayerIDs == [second.id] && staleRaw.selectionFence == initial.selectionFence)
        session.multipleLayerSelection = true
        let multiple = try StudioMediaObservation.media(session)
        #expect(multiple.selectedLayerIDs == [first.id] && multiple.selectedLayerCount == 1)
        #expect(multiple.selectedLayerID == second.id && multiple.selectionFence != initial.selectionFence)
        session.selectedLayerIDs = [first.id, second.id, removedID]
        let expanded = try StudioMediaObservation.media(session)
        #expect(Set(expanded.selectedLayerIDs) == [first.id, second.id] && expanded.selectedLayerCount == 2)
        #expect(expanded.selectedLayerID == second.id && expanded.selectionFence != multiple.selectionFence)
        session.selectedLayerIDs.remove(removedID)
        #expect(try StudioMediaObservation.media(session).selectionFence == expanded.selectionFence)
    }

    @Test func eyedropperSamplesSavedPixelsAndReadbackKeepsSelectionFenceAndLegacyDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-palette-readback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let coordinator = MediaPreparedCoordinator(store: store)
        let project = MediaProject(kind: .image, name: "Actual red PNG", canvas: .init(width: 64, height: 48))
        try await store.save(project)
        _ = try await coordinator.upgradeDocument(id: project.id)
        let asset = try imageAsset(at: root, color: .red)
        let source = MediaPreparedLayer(name: "Saved red pixels", content: .raster(.init(source: .asset(asset.id))))
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset)), .init(action: .insertLayer(layer: source, parentID: nil, index: nil))], to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id, root: root, store: store)
        defer { session.stopPlayback() }
        let before = try StudioMediaObservation.media(session)
        let unavailable = try MediaPreparedToolInputGuide.make(document: session.document, implementedToolIDs: ["image.eyedropper"], selectionFence: before.selectionFence)
        #expect(unavailable.first?.inputJSON == nil && unavailable.first?.unavailableReason != nil)
        try await waitForImagePreview(session)
        let ready = try StudioMediaObservation.media(session)
        #expect(ready.previewReady == true)
        let rows = try MediaPreparedToolInputGuide.make(document: session.document, implementedToolIDs: ["image.eyedropper"], selectionFence: ready.selectionFence, hasRenderedImagePreview: ready.previewReady == true)
        let input = try StudioMediaToolContract.decode(try #require(rows.first?.inputJSON))
        let receipt = try await session.performTool("image.eyedropper", input: input, actor: .model)
        #expect(receipt.selectionOnly && receipt.groupID == nil)
        let after = try StudioMediaObservation.media(session)
        #expect(after.paletteColorHex == "#FF0000" && after.paletteColorHex == session.colorHex)
        #expect(after.selectionFence == before.selectionFence && after.revision == before.revision)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as? [String:Any])
        legacy.removeValue(forKey: "paletteColorHex")
        legacy.removeValue(forKey: "previewReady")
        let old = try JSONDecoder().decode(StudioMediaSelectionObservation.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.paletteColorHex == nil && old.previewReady == nil && old.selectionFence == after.selectionFence)
    }

    private func openPathLayer() -> MediaPreparedLayer {
        .init(name: "Open straight path", content: .vectorPaths(.init(subpaths: [.init(points: [.init(point: .init(x: 0.1, y: 0.1)), .init(point: .init(x: 0.5, y: 0.6))])], fillColorHex: nil, strokeColorHex: "#3366FF", strokeWidth: 2)))
    }

    private func waitForImagePreview(_ session: MediaV2Session) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while session.preview == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try #require(session.preview)
    }

    private func imageAsset(at root: URL, color: UIColor = .gray, filename: String = "source.png") throws -> MediaAssetReference {
        let directory = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return .init(kind: .image, relativePath: "Assets/" + filename, originalName: filename, byteCount: Int64(data.count), metadata: .init(width: 64, height: 48))
    }

    @Test func colorMatchingWithoutADistinctReferenceHasNoRunnableExample() throws {
        let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(3))
        let asset=MediaAssetReference(kind:.video,relativePath:"Assets/source.mov",originalName:"Source")
        let track=MediaPreparedTrack(kind:.visual,name:"Only shot",clips:[.init(assetID:asset.id,timelineRange:range,sourceRange:range)])
        var document=MediaPreparedDocument(id:UUID(),kind:.video,name:"Missing reference",assets:[asset])
        document.trackGraph.tracks=[track]
        let examples=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:["video.color-match"],selectionFence:nil)
        let unavailable=try #require(examples.first{$0.toolID=="video.color-match"})
        #expect(unavailable.inputJSON==nil && unavailable.unavailableReason?.isEmpty==false)
    }

    @Test func duckingWithoutADistinctNarrationHasNoRunnableExample() throws {
        let range=try MediaTimeRange(start:.seconds(0),duration:.seconds(3))
        let asset=MediaAssetReference(kind:.audio,relativePath:"Assets/music.wav",originalName:"Music")
        let track=MediaPreparedTrack(kind:.audio,name:"Music",clips:[.init(assetID:asset.id,timelineRange:range,sourceRange:range)])
        var document=MediaPreparedDocument(id:UUID(),kind:.video,name:"Missing narration",assets:[asset])
        document.trackGraph.tracks=[track]
        let examples=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:["video.duck"],selectionFence:nil)
        let unavailable=try #require(examples.first{$0.toolID=="video.duck"})
        #expect(unavailable.inputJSON==nil && unavailable.unavailableReason?.isEmpty==false)
    }
}
#endif
