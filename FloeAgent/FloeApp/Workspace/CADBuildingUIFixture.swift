// SPDX-License-Identifier: MPL-2.0
#if DEBUG && canImport(UIKit)
import SwiftUI
import FloeCAD

@MainActor
enum CADBuildingUIFixture {
    static let argument="--ui-test-cad-building"
    struct Prepared { let document:FloeCADDocument;let plan:CADSketchTransferEnvelope? }
    static func prepare(reopen:Bool,reset:Bool) async throws -> Prepared {
        let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("FloeCADBuildingFixture",isDirectory:true)
        if reset,FileManager.default.fileExists(atPath:root.path) { try FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("Building.floecad")
        let document: FloeCADDocument
        if FileManager.default.fileExists(atPath:url.path) { document=try await FloeCADDocument.open(at:url) }
        else { document=try await FloeCADDocument.create(at:url,name:"Building fixture") }
        CADDrawingModelBridge.configure(document)
        if reopen { return Prepared(document:document,plan:nil) }
        let points=[[0.0,0],[6000,0],[6000,4000],[0,4000]]
        var dxf="0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        for i in 0..<4 {
            let a=points[i],b=points[(i+1)%4]
            dxf+="0\nLINE\n5\n\(String(i+10,radix:16).uppercased())\n8\nWALLS\n10\n\(a[0])\n20\n\(a[1])\n30\n0\n11\n\(b[0])\n21\n\(b[1])\n31\n0\n"
        }
        dxf+="0\nENDSEC\n0\nEOF\n"
        let source=try await CADDrawingModelBridge.decode(data:Data(dxf.utf8),name:"Building-plan.dxf",purpose:.buildingFloorplan)
        return Prepared(document:document,plan:source)
    }
}

struct CADBuildingFixtureSurface:View {
    let document:FloeCADDocument
    let plan:CADSketchTransferEnvelope?
    var body:some View {
        ZStack(alignment:.bottomLeading) {
            CADBuildingWorkspaceView(document:document,incomingPlan:plan)
            let summary=document.summary()
            Text("bodies=\(summary.bodyCount); pages=\(summary.drawingPageCount); sources=\((try? document.building()?.sources.count) ?? 0)")
                .font(.caption2).padding(4).background(.bar)
                .accessibilityIdentifier("building.fixture.status")
                .allowsHitTesting(false)
        }
    }
}
#endif
