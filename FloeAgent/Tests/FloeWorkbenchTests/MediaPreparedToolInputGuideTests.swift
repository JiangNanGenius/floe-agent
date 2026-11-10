// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeWorkbench

@Suite("Native media model input examples")
struct MediaPreparedToolInputGuideTests {
    @Test func examplesUseCurrentRealIDsAndNeverInventAMissingRegionOrModifyTheOriginal() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-guides-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        let store=MediaProjectStore(directory:root),project=MediaProject(kind:.image,name:"Source",canvas:.init(width:64,height:48)),coordinator=MediaPreparedCoordinator(store:store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let names: Set<String> = ["image.wand","image.inpaint","video.scopes"]
        let empty=try await coordinator.loadDocument(id:project.id)
        let initial=try MediaPreparedToolInputGuide.make(document:empty,implementedToolIDs:names)
        #expect(initial.count==2 && initial.allSatisfy{$0.inputJSON == nil && $0.unavailableReason != nil})
        let layer=MediaPreparedLayer(name:"Source",content:.raster(.init(source:.solidColor("#808080"))))
        _ = try await coordinator.applyUserOperations([.init(action:.insertLayer(layer:layer,parentID:nil,index:nil))],to:project.id)
        let document=try await coordinator.loadDocument(id:project.id)
        let noRegion=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:names,selectionFence:String(repeating:"a",count:64))
        #expect(noRegion.first{$0.toolID == "image.inpaint"}?.inputJSON == nil)
        let examples=try MediaPreparedToolInputGuide.make(document:document,implementedToolIDs:names,selectionFence:String(repeating:"b",count:64),hasImageRegion:true)
        let example=try #require(examples.first{$0.toolID == "image.inpaint"}),text=try #require(example.inputJSON)
        let object=try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any])
        #expect(object["objectID"] as? String == layer.id.uuidString && object["expectedRevision"] as? String == String(document.revision))
        #expect(object["selectionFence"] as? String == String(repeating:"b",count:64))
        #expect(example.executionTool == "studio.media.provider")
        #expect(try await coordinator.loadDocument(id:project.id) == document)
    }
}
