// SPDX-License-Identifier: MPL-2.0
import XCTest
import UniformTypeIdentifiers
import FloeCAD
import FloeInteriorCore

/// Source-authored qualification for the existing assembly projection route.
/// It is deliberately separate from the lightweight workbench build and must
/// receive its own CAD/native window. No source budget is raised or bypassed.
final class NativeCabinetAssemblyChecks: XCTestCase {
    private func checked(_ reply: [String: Any]) throws -> [String: Any] {
        guard reply["ok"] as? Bool == true else { throw NativeInteriorProbeError.command(String(describing: reply)) }
        return reply
    }
    private func native(_ p: InteriorVector3) -> [Double] { [p.x, p.z, -p.y] }
    private func axes(_ view: CabinetSheetViewSpec) -> [String: Any] {
        let h=view.horizontalInBuilding, v=view.verticalInBuilding
        let normal=InteriorVector3(h.y*v.z-h.z*v.y, h.z*v.x-h.x*v.z, h.x*v.y-h.y*v.x)
        return ["viewNormal": native(normal), "viewUp": native(h)]
    }
    private func attach(_ data: Data, _ name: String, _ type: String) {
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:type)
        attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    @MainActor func testWholeCabinetAssemblyCombinationPersistsAndExportsAllNineteenPanels() async throws {
        var recipe=InteriorResearchSamples.cabinet();recipe.heightMM=2100
        let assembly=try CabinetBuilder.build(recipe)
        let root=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("InteriorAssemblyResearch-20261113",isDirectory:true)
            .appendingPathComponent(UUID().uuidString,isDirectory:true)
        let draft=try await NativeCabinetDraft.create(assembly:assembly,directory:root)
        defer{draft.document.close()}
        XCTAssertEqual(assembly.panels.count,19)
        let placement=CADAssemblyService(document:draft.document)
        var instanceIDs:Set<UUID>=[]
        for panel in assembly.panels {
            let bodyID=try XCTUnwrap(draft.bodyIDs[panel.id])
            let reply=try checked(placement.handle(action:"addInstance",args:["bodyID":bodyID,"name":panel.id]))
            instanceIDs.insert(try XCTUnwrap((reply["id"] as? String).flatMap(UUID.init(uuidString:))))
        }
        XCTAssertEqual(instanceIDs.count,19)
        // The normal body-list route remains capped at12. The existing assembly
        // route accepts up to64 visible instances and blocks incomplete output.
        let sheet=try CabinetSheetPlanner.make(assembly,paperWidthMM:594,paperHeightMM:420,maximumNativeSources:64)
        let selected=sheet.views.filter{$0.kind != .internalElevation}
        XCTAssertEqual(selected.count,5)
        let service=CADDrawingService(document:draft.document)
        let first=try XCTUnwrap(selected.first)
        var args:[String:Any]=["kind":"front","assemblyMode":true,"paper":"a2","title":"Cabinet assembly qualification",
            "showDimensions":true,"scale":1/first.scaleDenominator]
        args.merge(axes(first)){_,new in new}
        let created=try checked(service.handle(action:"addPage",args:args))
        let page=try XCTUnwrap(created["page"] as? [String:Any])
        let pageID=try XCTUnwrap((page["id"] as? String).flatMap(UUID.init(uuidString:)))
        let firstViews=try XCTUnwrap(page["views"] as? [[String:Any]])
        let firstID=try XCTUnwrap((firstViews.first?["id"] as? String).flatMap(UUID.init(uuidString:)))
        var viewIDs:[String:UUID]=[first.id:firstID]
        for view in selected.dropFirst() {
            let kind=view.kind == .isometric ? "iso":view.kind.rawValue
            var input:[String:Any]=["pageID":pageID.uuidString,"kind":kind,"name":view.kind.rawValue,
                "scale":1/view.scaleDenominator,"alignmentPlacement":"free"]
            input.merge(axes(view)){_,new in new}
            if view.kind == .section {
                let frame=try InteriorDrawingFrame(view:.sideSection,originMM:.init(recipe.widthMM/2,recipe.carcassDepthMM/2,recipe.heightMM/2))
                input["sectionOrigin"]=frame.nativeOriginMM.values;input["sectionNormal"]=frame.nativeNormal.values
            }
            let reply=try checked(service.handle(action:"addView",args:input))
            let row=try XCTUnwrap(reply["view"] as? [String:Any])
            viewIDs[view.id]=try XCTUnwrap((row["id"] as? String).flatMap(UUID.init(uuidString:)))
        }
        let initial=try checked(await service.pageGeometryAsync(pageID:pageID))
        let initialViews=try XCTUnwrap(initial["views"] as? [[String:Any]])
        for view in selected {
            let id=try XCTUnwrap(viewIDs[view.id])
            let geometry=try XCTUnwrap(initialViews.first{($0["id"] as? String)==id.uuidString})
            let bounds=try XCTUnwrap(geometry["localBounds"] as? [[Double]])
            guard bounds.count==2,bounds.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else {
                throw NativeInteriorProbeError.command("Missing finite local bounds")
            }
            _=try checked(service.handle(action:"updateView",args:["pageID":pageID.uuidString,"viewID":id.uuidString,
                "alignmentPlacement":"free","offset":[view.centreOnPaperMM.x-(bounds[0][0]+bounds[1][0])/2,
                view.centreOnPaperMM.y-(bounds[0][1]+bounds[1][1])/2]]))
        }
        let projected=try checked(await service.handleAsync(action:"project",args:["pageID":pageID.uuidString]))
        try assertComplete(projected,instanceIDs:instanceIDs)
        let values=(projected["dimensions"] as? [[String:Any]] ?? []).compactMap{$0["value"] as? Double}
        for expected in [2400.0,2100,620] {
            XCTAssertTrue(values.contains{abs($0-expected)<0.05},"Missing overall dimension " + String(expected))
        }
        let proof=try JSONSerialization.data(withJSONObject:projected,options:[.prettyPrinted,.sortedKeys])
        try proof.write(to:root.appendingPathComponent("assembly-combination-geometry.json"),options:.atomic)
        attach(proof,"assembly-combination-geometry.json",UTType.json.identifier)
        for format in ["svg","dxf","pdf"] {
            let data=try await service.exportDataAsync(pageID:pageID,format:format)
            XCTAssertFalse(data.isEmpty)
            if format=="pdf" {XCTAssertTrue(data.starts(with:Data("%PDF".utf8)))}
            if format=="svg" {XCTAssertTrue(String(decoding:data,as:UTF8.self).contains("<svg"))}
            try data.write(to:root.appendingPathComponent("assembly-combination."+format),options:.atomic)
            attach(data,"assembly-combination."+format,format=="pdf" ? UTType.pdf.identifier:format=="svg" ? UTType.svg.identifier:"com.autodesk.dxf")
        }
        try await draft.save()
        draft.document.close()
        let reopened=try await FloeCADDocument.open(at:root.appendingPathComponent("Document.floecad"))
        defer{reopened.close()}
        XCTAssertEqual(reopened.summary().bodyCount,19)
        let saved=try checked(await CADDrawingService(document:reopened).pageGeometryAsync(pageID:pageID))
        try assertComplete(saved,instanceIDs:instanceIDs)
    }
    private func assertComplete(_ payload:[String:Any],instanceIDs:Set<UUID>) throws {
        XCTAssertEqual(payload["projectionComplete"] as? Bool,true)
        XCTAssertEqual(payload["outputBlocked"] as? Bool,false)
        XCTAssertTrue((payload["missingInstanceIDs"] as? [String] ?? ["missing"]).isEmpty)
        let views=try XCTUnwrap(payload["views"] as? [[String:Any]])
        XCTAssertEqual(views.count,5)
        for view in views {XCTAssertEqual(view["instanceCount"] as? Int,19);XCTAssertEqual(view["projectionComplete"] as? Bool,true)}
        let page=try XCTUnwrap(payload["page"] as? [String:Any])
        let fingerprint=try XCTUnwrap(page["sourceFingerprint"] as? [String:Any])
        let instances=try XCTUnwrap(fingerprint["instances"] as? [[String:Any]])
        XCTAssertEqual(Set(instances.compactMap{($0["instanceID"] as? String).flatMap(UUID.init(uuidString:))}),instanceIDs)
    }
}
