// SPDX-License-Identifier: MPL-2.0
import XCTest
import UniformTypeIdentifiers
import FloeCAD
import FloeInteriorCore

final class NativeCabinetChecks:XCTestCase {
    @MainActor private func root(_ name:String) throws -> URL {
        let root=try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("InteriorResearch-20261112",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root.appendingPathComponent(name+"-"+UUID().uuidString,isDirectory:true)
    }
    private func decode(_ outcome:CADCommandOutcome) throws -> [String:Any] {
        XCTAssertTrue(outcome.isOK,"\(outcome.errorCode ?? "") \(outcome.message ?? "")")
        return try XCTUnwrap(JSONSerialization.jsonObject(with:outcome.payload) as? [String:Any])
    }
    private func attachment(_ data:Data,_ name:String,_ type:String) {
        let item=XCTAttachment(data:data,uniformTypeIdentifier:type)
        item.name=name; item.lifetime = .keepAlways; add(item)
    }

    private func outlineBounds(_ geometry:[String:Any]) throws -> (min:[Double],max:[Double]) {
        let entities=try XCTUnwrap(geometry["entities"] as? [[String:Any]])
        let outlines=entities.filter { ["outline","edges","hidden","section"].contains($0["layer"] as? String ?? "") }
        let points=outlines.flatMap { row -> [[Double]] in
            if let a=row["a"] as? [Double],let b=row["b"] as? [Double] { return [a,b] }
            return row["points"] as? [[Double]] ?? []
        }
        XCTAssertFalse(points.isEmpty)
        guard points.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else {
            throw NativeInteriorProbeError.command("Invalid projected outline coordinates")
        }
        return (try [XCTUnwrap(points.map{$0[0]}.min()),XCTUnwrap(points.map{$0[1]}.min())],
                try [XCTUnwrap(points.map{$0[0]}.max()),XCTUnwrap(points.map{$0[1]}.max())])
    }

    @MainActor func testNineteenPanelsAndIndependentSTEPReadback() async throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let draft=try await NativeCabinetDraft.create(assembly:assembly,directory:root("cabinet19"))
        defer { draft.document.close() }
        XCTAssertEqual(draft.document.summary().bodyCount,19)
        for panel in assembly.panels {
            let id=try XCTUnwrap(draft.bodyIDs[panel.id])
            let measured=try decode(draft.document.measureJSON(["kind":"body","bodyID":id]))
            XCTAssertEqual(measured["analyticBRep"] as? Bool,true,"\(panel.id) is not analytic")
            XCTAssertEqual(try XCTUnwrap(measured["volumeMM3"] as? Double),panel.volumeM3*1_000_000_000,accuracy:0.01)
            let bounds=try XCTUnwrap(measured["bounds"] as? [[Double]])
            let expectedMin=[panel.originMM.x,panel.originMM.z,-panel.originMM.y-panel.sizeMM.y]
            let expectedMax=[panel.originMM.x+panel.sizeMM.x,panel.originMM.z+panel.sizeMM.z,-panel.originMM.y]
            XCTAssertEqual(bounds.count,2)
            for axis in 0..<3 {
                XCTAssertEqual(bounds[0][axis],expectedMin[axis],accuracy:0.01)
                XCTAssertEqual(bounds[1][axis],expectedMax[axis],accuracy:0.01)
            }
        }
        let identity=draft.document.savedIdentity
        draft.document.close()
        let reopened=try await FloeCADDocument.open(at:draft.directory.appendingPathComponent("Document.floecad"))
        defer { reopened.close() }
        XCTAssertEqual(reopened.summary().bodyCount,19)
        XCTAssertEqual(reopened.contentSHA256,identity.contentSHA256)
        try await verifySTEPReadback(assembly:assembly,source:reopened,directory:draft.directory)
        attachment(try Data(contentsOf:draft.directory.appendingPathComponent("native-bindings.json")),"cabinet19-receipt.json",UTType.json.identifier)
    }

    @MainActor private func verifySTEPReadback(assembly:CabinetAssembly,source:FloeCADDocument,directory:URL) async throws {
        let sourceIdentity=source.savedIdentity
        let sourceChanges=source.exchangeChangeCount
        let selection=CADExchangeSelection(scope:.part,expectedRevision:source.revision,
            expectedChangeCount:sourceChanges,expectedContentSHA256:source.contentSHA256)
        let output=source.nativeExchangeExport(format:"step",pageID:nil,selection:selection,dryRun:false)
        guard case let .success(data,_,coverage)=output else {
            throw NativeInteriorProbeError.command("STEP export did not produce complete geometry: \(output)")
        }
        XCTAssertEqual(coverage.includedCount,19)
        XCTAssertEqual(coverage.excludedCount,0)
        XCTAssertTrue(coverage.complete)
        XCTAssertFalse(coverage.acceptedPartial)
        XCTAssertEqual(coverage.unit,"mm")
        let text=String(decoding:data,as:UTF8.self).filter{!$0.isWhitespace}
        XCTAssertTrue(text.contains("ISO-10303-21;"))
        XCTAssertTrue(text.contains("SI_UNIT(.MILLI.,.METRE.)"))
        try data.write(to:directory.appendingPathComponent("cabinet19.step"),options:.atomic)
        let receipt=try JSONSerialization.data(withJSONObject:coverage.jsonObject(),options:[.sortedKeys,.prettyPrinted])
        try receipt.write(to:directory.appendingPathComponent("step-coverage.json"),options:.atomic)
        attachment(receipt,"step-coverage.json",UTType.json.identifier)

        let cancellation=MeshImportCancellation()
        let plan=try await CADExactImportService.parseOffMain(data:data,format:"step",fileName:"cabinet19.step",
            uniqueBodyNames:true,cancellation:cancellation)
        XCTAssertTrue(plan.parsedOffMain)
        XCTAssertEqual(plan.solidCount,19)
        XCTAssertEqual(plan.surfaceCount,0)
        let copy=try await FloeCADDocument.create(at:directory.appendingPathComponent("STEPReadback.floecad"),name:"Independent STEP copy")
        defer { copy.close() }
        let imported=try CADExactImportService.apply(plan,to:copy,cancellation:cancellation)
        XCTAssertTrue(imported.outcome.isOK)
        XCTAssertEqual(imported.importedBodyIDs.count,19)
        XCTAssertEqual(copy.summary().bodyCount,19)
        var unmatched:[(bounds:[Double],volume:Double)]=[]
        for id in imported.importedBodyIDs {
            let measured=try decode(copy.measureJSON(["kind":"body","bodyID":id.uuidString]))
            XCTAssertEqual(measured["analyticBRep"] as? Bool,true)
            let bounds=try XCTUnwrap(measured["bounds"] as? [[Double]]).flatMap{$0}
            XCTAssertEqual(bounds.count,6)
            unmatched.append((bounds,try XCTUnwrap(measured["volumeMM3"] as? Double)))
        }
        // Match the multiset of actual solids, not their regenerated import IDs.
        for panel in assembly.panels {
            let expected=[panel.originMM.x,panel.originMM.z,-panel.originMM.y-panel.sizeMM.y,
                          panel.originMM.x+panel.sizeMM.x,panel.originMM.z+panel.sizeMM.z,-panel.originMM.y]
            let match=unmatched.firstIndex { item in
                item.bounds.count==6 && zip(item.bounds,expected).allSatisfy{abs($0-$1)<0.01}
                && abs(item.volume-panel.volumeM3*1_000_000_000)<0.1
            }
            unmatched.remove(at:try XCTUnwrap(match,"STEP geometry mismatch for \(panel.id)"))
        }
        XCTAssertTrue(unmatched.isEmpty)
        let saved=await copy.save()
        XCTAssertTrue(saved.succeeded)
        let copyBefore=copy.contentSHA256
        let first=try XCTUnwrap(imported.importedBodyIDs.first)
        let beforeMove=try decode(copy.measureJSON(["kind":"body","bodyID":first.uuidString]))
        let moved=await copy.executeAsync(["op":"feature.transform","args":["bodyID":first.uuidString,"translation":[10,0,0]]])
        try moved.payload.write(to:directory.appendingPathComponent("step-copy-transform-response.json"),options:.atomic)
        attachment(moved.payload,"step-copy-transform-response.json",UTType.json.identifier)
        XCTAssertTrue(moved.isOK,"\(moved.errorCode ?? "") \(moved.message ?? "")")
        let afterMove=try decode(copy.measureJSON(["kind":"body","bodyID":first.uuidString]))
        let beforeBounds=try XCTUnwrap(beforeMove["bounds"] as? [[Double]])
        let afterBounds=try XCTUnwrap(afterMove["bounds"] as? [[Double]])
        for end in 0..<2 {
            XCTAssertEqual(afterBounds[end][0],beforeBounds[end][0]+10,accuracy:0.01)
            XCTAssertEqual(afterBounds[end][1],beforeBounds[end][1],accuracy:0.01)
            XCTAssertEqual(afterBounds[end][2],beforeBounds[end][2],accuracy:0.01)
        }
        XCTAssertEqual(copy.summary().bodyCount,19)
        let editedSave=await copy.save()
        XCTAssertTrue(editedSave.succeeded)
        XCTAssertNotEqual(copy.contentSHA256,copyBefore)
        XCTAssertEqual(source.exchangeChangeCount,sourceChanges)
        XCTAssertEqual(source.contentSHA256,sourceIdentity.contentSHA256)
        let independence:[String:Any]=["sourceUnchanged":source.contentSHA256==sourceIdentity.contentSHA256,
            "copyEdited":copy.contentSHA256 != copyBefore,"solidCount":19,"unit":"mm",
            "scope":"Exact geometry only; history, part names, assembly hierarchy and manufacturing semantics are not preserved by this STEP writer"]
        let proof=try JSONSerialization.data(withJSONObject:independence,options:[.sortedKeys,.prettyPrinted])
        try proof.write(to:directory.appendingPathComponent("step-independence.json"),options:.atomic)
        attachment(proof,"step-independence.json",UTType.json.identifier)
    }

    @MainActor func testNativeSmallCabinetViewsAndPartDrawingExport() async throws {
        var recipe=InteriorResearchSamples.cabinet(bayCount:1,shelvesPerBay:2,includeFronts:false)
        recipe.heightMM=2100 // Unequal width/height also exposes swapped in-plane axes.
        let assembly=try CabinetBuilder.build(recipe)
        let draft=try await NativeCabinetDraft.create(assembly:assembly,directory:root("drawings7"))
        defer { draft.document.close() }
        let service=CADDrawingService(document:draft.document)
        let sources=assembly.panels.compactMap{draft.bodyIDs[$0.id]}
        var requests:[[String:Any]]=[
            ["kind":"front","title":"Cabinet internal elevation - research","bodyIDs":sources],
            ["kind":"section","title":"Cabinet section - research","bodyIDs":sources],
            ["kind":"top","title":"Top panel outline - research",
             "bodyIDs":[try XCTUnwrap(draft.bodyIDs[assembly.panels.first{$0.role == .top}!.id])]]
        ]
        let frames=try [
            InteriorDrawingFrame(view:.frontElevation),
            InteriorDrawingFrame(view:.sideSection,originMM:.init(1200,300,1050)),
            InteriorDrawingFrame(view:.horizontalPlan)
        ]
        let expectedExtentMM:[[Double]]=[[2400,2100],[600,2100],[2364,600]]
        for index in requests.indices {
            requests[index].merge(NativeCabinetDraft.drawingArguments(frame:frames[index])) { _,new in new }
            requests[index]["scale"]=0.05
            requests[index]["paper"]="a4"
            let reply=service.handle(action:"addPage",args:requests[index])
            XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
            let page=try XCTUnwrap(reply["page"] as? [String:Any])
            let pageID=try XCTUnwrap((page["id"] as? String).flatMap(UUID.init(uuidString:)))
            let geometry=await service.pageGeometryAsync(pageID:pageID)
            XCTAssertEqual(geometry["ok"] as? Bool,true,"\(geometry)")
            XCTAssertEqual(geometry["projectionComplete"] as? Bool,true)
            XCTAssertEqual(geometry["outputBlocked"] as? Bool,false)
            XCTAssertFalse((geometry["entities"] as? [[String:Any]] ?? []).isEmpty)
            let bounds=try outlineBounds(geometry)
            for axis in 0..<2 {
                XCTAssertEqual(bounds.max[axis]-bounds.min[axis],expectedExtentMM[index][axis]*0.05,accuracy:0.01)
            }
            let placed=service.handle(action:"updateView",args:[
                "pageID":pageID.uuidString,"viewID":pageID.uuidString,
                "offset":[105-(bounds.min[0]+bounds.max[0])/2,160-(bounds.min[1]+bounds.max[1])/2]])
            XCTAssertEqual(placed["ok"] as? Bool,true,"\(placed)")
            let placedGeometry=await service.pageGeometryAsync(pageID:pageID)
            let placedBounds=try outlineBounds(placedGeometry)
            for axis in 0..<2 {
                XCTAssertEqual(placedBounds.max[axis]-placedBounds.min[axis],expectedExtentMM[index][axis]*0.05,accuracy:0.01)
                XCTAssertEqual((placedBounds.min[axis]+placedBounds.max[axis])/2,[105.0,160.0][axis],accuracy:0.01)
            }
            let receipt=try JSONSerialization.data(withJSONObject:placedGeometry,options:[.sortedKeys,.prettyPrinted])
            try receipt.write(to:draft.directory.appendingPathComponent("view-\(index)-geometry.json"))
            attachment(receipt,"view-\(index)-geometry.json",UTType.json.identifier)
            for (format,type) in [("svg",UTType.svg.identifier),("dxf","com.autodesk.dxf"),("pdf",UTType.pdf.identifier)] {
                let data=try await service.exportDataAsync(pageID:pageID,format:format)
                XCTAssertFalse(data.isEmpty)
                if format=="pdf" { XCTAssertTrue(data.starts(with:Data("%PDF".utf8))) }
                if format=="svg" { XCTAssertTrue(String(decoding:data,as:UTF8.self).contains("<svg")) }
                let name="view-\(index).\(format)"
                try data.write(to:draft.directory.appendingPathComponent(name),options:.atomic)
                attachment(data,name,type)
            }
        }
        try await draft.save()
        XCTAssertEqual(draft.document.summary().drawingPageCount,3)
    }

    @MainActor func testLargeCabinetViewReportsActualNativeBudget() async throws {
        let assembly=try CabinetBuilder.build(InteriorResearchSamples.cabinet())
        let draft=try await NativeCabinetDraft.create(assembly:assembly,directory:root("budget19"))
        defer { draft.document.close() }
        let sources=assembly.panels.compactMap{draft.bodyIDs[$0.id]}
        XCTAssertEqual(sources.count,19)
        let reply=CADDrawingService(document:draft.document).handle(action:"addPage",args:["kind":"front","bodyIDs":sources])
        XCTAssertEqual(reply["ok"] as? Bool,false)
        XCTAssertEqual(reply["error"] as? String,"too_many_bodies")
        XCTAssertEqual(draft.document.summary().bodyCount,19,"Budget refusal must not drop model parts")
        XCTAssertEqual(draft.document.summary().drawingPageCount,0)
        attachment(try JSONSerialization.data(withJSONObject:reply,options:.sortedKeys),"native-source-budget.json",UTType.json.identifier)
    }
}
