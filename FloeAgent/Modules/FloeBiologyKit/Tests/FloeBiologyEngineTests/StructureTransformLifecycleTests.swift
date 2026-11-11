import Foundation
import Testing
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologySamples

@Test func partialStructureTransformPreservesOtherAtomsOriginalAndUndoPayload() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("biology-transform-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=try BiologyProjectStore(root:root)
    let service=try BiologyService(store:store,authorize:{_ in})
    let project=try await service.create(title:"Transform")
    let asset=try await service.importAsset(project.id,title:"Existing structure",format:"pdb",data:BiologySamples.data(for:.ubiquitinPDB))
    guard case .proteinStructure(let original)=asset.payload else {Issue.record("Structure missing");return}
    let first=try #require(original.atoms.first)
    _=try await service.update(project.id,operation:"structure.transform",assetID:asset.id,expectedRevision:asset.revision,parameters:.object([
        "atomIDs":.array([.number(Double(first.id))]),
        "translation":.array([5,-2,1].map{.number(Double($0))}),
        "axis":.array([.number(0),.number(0),.number(1)]),"angleRadians":.number(.pi/2)]))
    let saved=try await BiologyProjectStore(root:root).load(project.id)
    let moved=try #require(saved.assets.first{$0.id==asset.id})
    guard case .proteinStructure(let structure)=moved.payload else {Issue.record("Structure missing");return}
    #expect(abs(structure.atoms[0].x-(-first.y+5))<1e-9)
    #expect(abs(structure.atoms[0].y-(first.x-2))<1e-9)
    #expect(abs(structure.atoms[0].z-(first.z+1))<1e-9)
    #expect(Array(structure.atoms.dropFirst())==Array(original.atoms.dropFirst()))
    #expect(try BiologyExport.asset(moved,format:"original")==asset.originalData)
    // The UI's existing payload undo/redo path retains complete data, not an
    // inverse numerical transform that can accumulate coordinate error.
    try await service.replacePayload(project.id,assetID:asset.id,expectedAssetRevision:moved.revision,payload:asset.payload)
    let undone=try await store.load(project.id)
    #expect(undone.assets.first{$0.id==asset.id}?.payload==asset.payload)
}

@Test func staleOrMissingTransformTargetsNeverChangeTheStructure() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("biology-transform-stale-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let store=try BiologyProjectStore(root:root)
    let service=try BiologyService(store:store,authorize:{_ in})
    let project=try await service.create(title:"Stale transform")
    let asset=try await service.importAsset(project.id,title:"Existing structure",format:"pdb",data:BiologySamples.data(for:.ubiquitinPDB))
    _=try await service.update(project.id,operation:"asset.rename",assetID:asset.id,expectedRevision:asset.revision,parameters:.object(["title":.string("Changed while editor was open")]))
    let before=try await store.load(project.id)
    await #expect(throws:(any Error).self) {
        try await service.update(project.id,operation:"structure.transform",assetID:asset.id,expectedRevision:asset.revision,parameters:.object(["translation":.array([.number(1),.number(0),.number(0)])]))
    }
    #expect(try await store.load(project.id)==before)
    let current=try #require(before.assets.first{$0.id==asset.id})
    await #expect(throws:(any Error).self) {
        try await service.update(project.id,operation:"structure.transform",assetID:asset.id,expectedRevision:current.revision,parameters:.object(["atomIDs":.array([])]))
    }
    #expect(try await store.load(project.id)==before)
}
