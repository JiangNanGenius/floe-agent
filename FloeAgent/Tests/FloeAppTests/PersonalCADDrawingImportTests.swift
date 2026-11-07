// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import simd
import Testing
@testable import FloeApp
@testable import FloeCAD

@Suite("Personal CAD drawing import", .serialized)
@MainActor struct PersonalCADDrawingImportTests {
    private typealias Opened = (id:UUID,directory:URL,document:FloeCADDocument)
    private func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("PersonalDrawingImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func create(_ service:PersonalContentService,kind:PersonalContentKind,title:String) async throws -> Opened {
        let record=try await service.create(kind:kind,title:title)
        let location=try await service.library().resolve(record.id)
        return (record.id,location.url,try await PersonalCADSessions.open(id:record.id,directory:location.url))
    }
    private func remove(_ values:[Opened],root:URL) {
        for value in values { value.document.close() }
        var seen=Set<UUID>()
        for value in values where seen.insert(value.id).inserted {
            try? PersonalCADSessions.prepareForLibraryMove(id:value.id,directory:value.directory)
        }
        try? FileManager.default.removeItem(at:root)
    }
    private func bounds(_ sketch:Sketch) throws -> [Double] {
        let points=sketch.entities.flatMap { entity -> [SIMD2<Double>] in
            if case let .line(_,a,b)=entity { return [a,b] };return []
        }
        try #require(points.count==8,"The native closed rectangle must import as four exact line segments")
        return [try #require(points.map(\.x).min()),try #require(points.map(\.y).min()),
                try #require(points.map(\.x).max()),try #require(points.map(\.y).max())]
    }

    @Test func space2DNativeDXFExportDecodesImportsAndSurvivesColdReopen() async throws {
        let root=try directory(),service=PersonalContentService(root:root)
        var opened:[Opened]=[];defer { remove(opened,root:root) }
        let source=try await create(service,kind:.cad2D,title:"Original 2D rectangle");opened.append(source)
        source.document.activate2DWorkspace()
        let sourceModel=source.document.viewModel(),sketch=try #require(sourceModel.activeSketch)
        let edit=source.document.execute(["op":"sketch.addEntities","args":["sketchID":sketch.id.raw.uuidString,
            "entities":[["kind":"rect","min":[0.0,0.0],"max":[3.5,3.0]]]]])
        try #require(edit.isOK)
        let exported=try #require(sourceModel.exportDXF())
        #expect(String(decoding:exported,as:UTF8.self).contains("AC1009"))
        #expect(String(decoding:exported,as:UTF8.self).contains("POLYLINE"))
        try #require((await source.document.save()).succeeded)
        let sourceHash=source.document.contentSHA256
        source.document.close()

        let target=try await create(service,kind:.cad2D,title:"DXF roundtrip target");opened.append(target)
        target.document.activate2DWorkspace()
        // No test-side configure call: Space's production session must supply
        // exactly the decoder the real file-import UI requires.
        let decode=try #require(target.document.drawingSketchDecoder)
        let transfer=try await decode(exported,"Native rectangle.dxf")
        #expect(transfer.sourceBytes==exported)
        #expect(transfer.sourceSHA256==CADSketchTransferEnvelope.digest(exported))
        #expect(transfer.snapshot.format=="dxf")
        #expect(transfer.snapshot.curves.count==4 && transfer.snapshot.curves.allSatisfy { $0.kind == .line })
        #expect(transfer.snapshot.omissions.isEmpty)
        let model=target.document.viewModel(),count=target.document.session.changeCount
        let initialSketches=target.document.summary().sketchCount
        try target.document.queueDrawingTransfer(transfer)
        #expect(model.pendingDrawingTransfer==transfer)
        #expect(target.document.session.changeCount==count,"Decoding/queueing only prepares the existing placement sheet")
        try model.importDrawingTransfer(transfer,placement:.init(target:.selected,unitScaleMM:1))
        #expect(model.pendingDrawingTransfer==nil)
        let imported=try #require(target.document.session.document.sketches.first { $0.drawingSource != nil })
        let importedID=imported.id
        #expect(try bounds(imported)==[0,0,3.5,3])
        #expect(imported.drawingSource?.sourceBytes==exported)
        #expect(target.document.summary().sketchCount==initialSketches+1)
        target.document.session.undo()
        #expect(target.document.summary().sketchCount==initialSketches)
        target.document.session.redo()
        #expect(target.document.summary().sketchCount==initialSketches+1)
        try #require((await target.document.save()).succeeded)
        target.document.close()
        let reopened=try await PersonalCADSessions.open(id:target.id,directory:target.directory)
        opened.append((target.id,target.directory,reopened))
        let stored=try #require(reopened.session.document.sketches.first { $0.id==importedID })
        #expect(try bounds(stored)==[0,0,3.5,3])
        #expect(stored.drawingSource?.sourceBytes==exported)
        #expect(stored.drawingSource?.sourceSHA256==CADSketchTransferEnvelope.digest(exported))
        #expect(stored.drawingSource?.placement?.unitScaleMM==1)
        #expect(reopened.drawingSketchDecoder != nil)
        let original=try await PersonalCADSessions.open(id:source.id,directory:source.directory)
        opened.append((source.id,source.directory,original))
        #expect(original.contentSHA256==sourceHash,"Import into a separately created work must not rewrite its source")
    }

    @Test func cached2DAnd3DOpensInstallTheSameCodecsWithoutChangingTheDocument() async throws {
        let root=try directory(),service=PersonalContentService(root:root)
        var opened:[Opened]=[];defer { remove(opened,root:root) }
        for kind in [PersonalContentKind.cad2D,.cad3D] {
            let work=try await create(service,kind:kind,title:"Cached drawing bridge");opened.append(work)
            #expect(work.document.drawingSketchDecoder != nil)
            #expect(work.document.drawingDWGEncoder != nil)
            let before=work.document.snapshotJSON(),revision=work.document.revision
            // An already-live session must not depend on a chrome .task or
            // retain a missing adapter from an earlier presentation.
            work.document.drawingSketchDecoder=nil;work.document.drawingDWGEncoder=nil
            let cached=try await PersonalCADSessions.open(id:work.id,directory:work.directory)
            #expect(cached === work.document)
            #expect(cached.drawingSketchDecoder != nil && cached.drawingDWGEncoder != nil)
            #expect(cached.revision==revision && cached.snapshotJSON()==before)
        }
    }
}
#endif
