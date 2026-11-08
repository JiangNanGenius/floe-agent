// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeApp

@Suite("Electronics library arc typed contract", .serialized)
@MainActor struct ElectronicsLibraryArcContractTests {
    @Test func existingNativePutUsesTheSameArcEncodingAndLayeredExport() throws {
        var p = EDAProject(title: "Typed arc record")
        let definition = EDAFootprintDefinition(name: "Arc from native.put")
        p.footprints = [definition]
        p.boards[0].footprints = [.init(definitionID: definition.id, position: .init(10,10))]
        let arc = EDAGraphic.arc(center: .init(1,2), radius: 2, start: 30, sweep: -120, width: 0.25)
        var changed = definition
        changed.graphics = [arc]; changed.graphicLayers = [.init(layerID: "F.Fab", kind: .fabrication)]
        let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changed))
        let input = try JSONSerialization.data(withJSONObject: [["op":"native.put", "kind":"footprintDefinition", "value":record]], options: [.sortedKeys])
        guard case .edits(let edits) = try StudioElectronicsContract.decode(String(decoding: input, as: UTF8.self), project: p) else {
            Issue.record("Expected the existing complete-record native.put edit"); return
        }
        var editor = try EDAEditingSession(project: p); try editor.apply(edits, expectedRevision: 0)
        #expect(editor.project.footprints[0] == changed)
        let read = try JSONDecoder().decode(EDAFootprintDefinition.self, from: JSONEncoder().encode(editor.project.footprints[0]))
        #expect(read.graphics == [arc] && read.graphicLayers == changed.graphicLayers)
        let bundle = try EDAExchange.export(editor.project, format: .gerberTechnical, gerberLayers: ["F.Fab"])
        let file = try #require(bundle.files.first { $0.name == "AssemblyOutline-Top.gbr" })
        #expect(String(decoding: file.data, as: UTF8.self).contains("G02*\n"))
        let fields = try StudioElectronicsContract.capabilities(editor.project).graphicLayerFields
        #expect(fields["arc"]?.contains("positive sweep is counterclockwise") == true)
        #expect(fields["arc"]?.contains("native.put") == true)
        #expect(p.footprints[0].graphics.isEmpty && p.revision == 0)
    }
}
#endif
