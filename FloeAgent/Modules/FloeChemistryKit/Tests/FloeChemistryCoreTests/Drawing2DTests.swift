import Foundation
import Testing
@testable import FloeChemistryCore

@Test func nativeDrawingGraphAndStereoRoundTrip() throws {
    var drawing = try ChemicalDrawing2D()
    try drawing.addRing(size:6,aromatic:true,center:ChemicalPoint(0,0))
    #expect(drawing.atoms.count == 6 && drawing.bonds.count == 6)
    #expect(drawing.bonds.filter {$0.order == 2}.count == 3)
    let first = try #require(drawing.atoms.first)
    try drawing.updateAtom(first.id,label:"N",charge:1,isotope:15,point:ChemicalPoint(1,2))
    let bond = try #require(drawing.bonds.first)
    try drawing.updateBond(bond,order:1,stereo:6)
    let reopened = try ChemicalDrawing2D(drawing.encoded())
    #expect(reopened == drawing)
    #expect(reopened.atoms.first?.label == "N" && reopened.atoms.first?.charge == 1 && reopened.atoms.first?.isotope == 15)
    #expect(reopened.bonds.first?.stereo == 6)
    #expect(reopened.atoms.first?.point == ChemicalPoint(1,2))
}

@Test func nativeDrawingConnectionsRemovalAndAnnotations() throws {
    var drawing = try ChemicalDrawing2D()
    let a = try drawing.addAtom("C",at:ChemicalPoint(0,0))
    let b = try drawing.addAtom("O",at:ChemicalPoint(1.5,0))
    _ = try drawing.addBond(a,b)
    #expect(drawing.moleculeKeys.count == 1)
    let attached = try #require(drawing.atoms.first(where:{$0.label == "O"}))
    let c = try drawing.addAtom("H",at:ChemicalPoint(2.5,0),molecule:a.molecule)
    _ = try drawing.addBond(attached.id,c)
    try drawing.removeAtom(attached.id)
    #expect(drawing.atoms.count == 2 && drawing.bonds.isEmpty)
    drawing.addArrow(from:ChemicalPoint(0,-3),to:ChemicalPoint(3,-3))
    try drawing.addText("heat · Δ",at:ChemicalPoint(1.5,-2))
    let reopened = try ChemicalDrawing2D(drawing.encoded())
    #expect(reopened.annotations.count == 2)
    #expect(reopened.annotations.last?.text == "heat · Δ")
    var reaction = reopened
    reaction.addReactionPlus(at:ChemicalPoint(5,2))
    #expect(try ChemicalDrawing2D(reaction.encoded()).annotations.last?.point == ChemicalPoint(5,2))
    var pasted = reopened
    try pasted.insert(reopened)
    #expect(pasted.atoms.count == 4 && pasted.annotations.count == 4)
    #expect(Set(pasted.moleculeKeys).count == 2)
    #expect(pasted.atoms.map(\.point.x).max()! > reopened.atoms.map(\.point.x).max()!)
    #expect(throws:(any Error).self) {try ChemicalDrawing2D("{\"root\":{\"nodes\":[{\"$ref\":\"mol0\"}]},\"mol0\":{\"type\":\"molecule\",\"atoms\":[],\"bonds\":[{\"type\":1,\"atoms\":[0,1]}]}}")}
}

@Test func nativeDrawingUnknownMetadataIsPreserved() throws {
    let source = "{\"root\":{\"nodes\":[{\"$ref\":\"mol0\"}],\"floeFuture\":\"preserve\"},\"mol0\":{\"type\":\"molecule\",\"atoms\":[{\"label\":\"C\",\"location\":[0,0,0],\"custom\":{\"mapping\":9}}],\"bonds\":[],\"sgroups\":[{\"atoms\":[0]}]}}"
    var drawing = try ChemicalDrawing2D(source)
    let atom = try #require(drawing.atoms.first)
    try drawing.updateAtom(atom.id,point:ChemicalPoint(2,3))
    #expect(drawing.value["root"]?["floeFuture"]?.string == "preserve")
    #expect(drawing.value["mol0"]?["atoms"]?.array?.first?["custom"]?["mapping"]?.number == 9)
    let moved = drawing
    #expect(throws:(any Error).self) {try drawing.removeAtom(atom.id)}
    #expect(drawing == moved)
    #expect(try ChemicalDrawing2D(drawing.encoded()).value["mol0"]?["sgroups"] != nil)
}
