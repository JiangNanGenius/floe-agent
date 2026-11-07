// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCAD
import FloeSimulationCore
import FloeSimulationUI
import FloeSimulationRuntime
import FloeSimulationPhysics
import FloeSimulationAnimation

/// One service-owned simulation per actual CAD original. Panels and Studio borrow it.
@MainActor enum CADSimulationSessions {
    @MainActor final class Entry {
        let document: FloeCADDocument
        let directory: URL
        let projectID: UUID
        var geometry: CADSimulationGeometry
        var source: SimulationSourceRef
        var model: SimulationWorkbenchModel!
        var observer: UUID?
        var refreshTask: Task<Void,Never>?
        var closing = false
        var closingTask: Task<Void,any Error>?
        var fileUse: PersonalLibraryUsageLease?
        init(document: FloeCADDocument, directory: URL, projectID: UUID, geometry: CADSimulationGeometry, source: SimulationSourceRef) {
            self.document = document; self.directory = directory; self.projectID = projectID
            self.geometry = geometry; self.source = source
        }
        func requireCurrent(_ expected: SimulationSourceRef) throws {
            guard !closing, !document.isClosed, source == expected,
                  document.exchangeChangeCount == geometry.changeCount else { throw SimulationError.staleSource }
        }
        func exportAnimation(_ request:SimulationAnimationExportRequest) async throws {
            try requireCurrent(request.graph.source)
            let captured = geometry
            try await CADSimulationAnimationExport.write(request,document:document,geometry:captured)
            try requireCurrent(request.graph.source)
        }
        func snapshot(_ expected: SimulationSourceRef) throws -> SimulationGeometrySnapshot {
            try requireCurrent(expected)
            return try CADSimulationSourceBridge.snapshot(geometry, source: expected)
        }
        func refresh() async throws {
            guard !closing, !document.isClosed else { throw SimulationError.staleSource }
            let captured = try document.simulationGeometry()
            if captured.contentSHA256 != source.contentSHA256 {
                guard source.revision < UInt64.max else { throw SimulationError.staleSource }
                let next = SimulationSourceRef(projectID:source.projectID,documentID:source.documentID,revision:source.revision+1,contentSHA256:captured.contentSHA256)
                guard await model.refreshSource(next) else { throw SimulationError.staleSource }
                source = next
            }
            geometry = captured
            setObjectNames()
            _ = await model.refreshSource(source)
        }
        func setObjectNames() {
            do { model.setSourceAnimationGraph(try CADSimulationAnimationBridge.graph(document.simulationAnimationSource(),source:source)) }
            catch { model.setSourceAnimationGraph(nil,message:error.localizedDescription) }
            model.setSourceMeshes(geometry.bodies.map {
                .init(id:$0.id.uuidString.lowercased(),positionsMeters:$0.positionsMM.map { .init($0[0]*0.001,$0[1]*0.001,$0[2]*0.001) },indices:$0.indices)
            })
            model.setSourceObjects(geometry.bodies.map { body in
                let count = Double(max(1,body.positionsMM.count))
                let center = body.positionsMM.reduce(SimulationVector3.zero) { $0+SimulationVector3($1[0]*0.001/count,$1[1]*0.001/count,$1[2]*0.001/count) }
                return SimulationSourceObject(id:body.id.uuidString.lowercased(),name:body.name,restTransform:.init(translation:center))
            })
        }
    }
    private static let registry = SimulationWorkbenchSessions()
    private static var entries: [String:Entry] = [:]
    private static var preparing: [String:Task<Entry,any Error>] = [:]
    private static var preparingDirectories: [String:URL] = [:]
    static func directory(_ document: FloeCADDocument) -> URL {
        document.url.deletingLastPathComponent().appendingPathComponent(document.url.lastPathComponent + ".simulation", isDirectory:true)
    }
    static func open(document: FloeCADDocument, directory: URL? = nil, ownerID: UUID? = nil) async throws -> Entry {
        let key = document.url.standardizedFileURL.resolvingSymlinksInPath().path
        let directory = directory ?? self.directory(document)
        if let entry = entries[key] {
            guard entry.document === document, entry.directory == directory, !entry.closing,
                  ownerID == nil || ownerID == entry.projectID else { throw SimulationError.staleSource }
            try await entry.refresh(); return entry
        }
        if let task = preparing[key] {
            let entry = try await task.value
            guard entry.document === document, entry.directory == directory,
                  ownerID == nil || ownerID == entry.projectID else { throw SimulationError.staleSource }
            return entry
        }
        let task = Task { @MainActor in
            let geometry = try document.simulationGeometry()
            let documentID = ownerID ?? stableID(key), projectID = ownerID ?? documentID
            let archive = try SimulationArchiveStore(directory:directory)
            let saved: SimulationWorkspaceDocument?
            if FileManager.default.fileExists(atPath:directory.appendingPathComponent("workspace.json").path) { saved = try await archive.readDocument() }
            else { saved = nil }
            if let saved { guard saved.source.projectID == projectID, saved.source.documentID == documentID else { throw SimulationError.staleSource } }
            let old = saved?.source
            guard old?.revision != UInt64.max || old?.contentSHA256 == geometry.contentSHA256 else { throw SimulationError.staleSource }
            let revision = old.map { $0.contentSHA256 == geometry.contentSHA256 ? $0.revision : $0.revision+1 } ?? 0
            let source = SimulationSourceRef(projectID:projectID,documentID:documentID,revision:revision,contentSHA256:geometry.contentSHA256)
            let entry = Entry(document:document,directory:directory,projectID:projectID,geometry:geometry,source:source)
            if let ownerID { entry.fileUse = try PersonalLibraryFileActions.acquireUse(id:ownerID,directory:document.url.deletingLastPathComponent()) }
            var initial = SimulationWorkspaceDocument(source:source)
            if saved == nil {
                var study = SimulationStudy(name:IDELanguageRunText.t("模型刚体", "Model rigid bodies"),kind:.rigidBody)
                try study.setConfiguration(CADSimulationSourceBridge.physics(geometry))
                initial.studies = [study]
            }
            do {
                entry.model = try await registry.open(initial:initial,directory:directory,
                    geometryProvider:{ [weak entry] source in
                        try await MainActor.run { guard let entry else { throw SimulationError.staleSource }; return try entry.snapshot(source) }
                    }, validateSource:{ [weak entry] source in
                        try await MainActor.run { guard let entry else { throw SimulationError.staleSource }; try entry.requireCurrent(source) }
                    })
                try entry.requireCurrent(source)
                entry.setObjectNames()
                entry.model.animationExportHandler = { [weak entry] request in
                    guard let entry else { throw SimulationError.staleSource }
                    try await entry.exportAnimation(request)
                }
                entry.observer = document.observeSimulationSource { [weak entry] closed in
                    guard let entry else { return }
                    entry.model.invalidateLiveSource()
                    entry.refreshTask?.cancel()
                    if closed {
                        entry.closing = true
                        Task { @MainActor in try? await close(document:entry.document) }
                    } else {
                        entry.refreshTask = Task { @MainActor in
                            do { try await Task.sleep(for:.milliseconds(100)); try Task.checkCancellation(); try await entry.refresh() }
                            catch { /* A subsequent UI/tool read retries against the actual source. */ }
                        }
                    }
                }
                entries[key] = entry; return entry
            } catch {
                try? await registry.close(directory:directory)
                entry.fileUse?.release(); throw error
            }
        }
        preparing[key] = task
        preparingDirectories[key] = directory
        defer { preparing.removeValue(forKey:key); preparingDirectories.removeValue(forKey:key) }
        return try await task.value
    }
    static func stableID(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data:Data(text.utf8)).prefix(16))
        return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func close(document: FloeCADDocument) async throws {
        let key = document.url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let entry = entries[key], entry.document === document else { return }
        if let pending = entry.closingTask { try await pending.value; return }
        entry.closing = true; entry.refreshTask?.cancel()
        let task = Task { @MainActor in
            if !document.isClosed, entry.model.hasUnsavedChanges {
                guard await entry.model.save(), !entry.model.hasUnsavedChanges else {
                    entry.closing = false
                    throw SimulationError.invalidInput(entry.model.errorDetails ?? "Save the open simulation edits before closing this CAD model.")
                }
            }
            if let observer = entry.observer { document.removeSimulationSourceObserver(observer) }
            try await registry.close(directory:entry.directory)
            entry.fileUse?.release(); entry.fileUse = nil
            if entries[key] === entry { entries.removeValue(forKey:key) }
        }
        entry.closingTask = task
        do { try await task.value } catch { entry.closingTask = nil; throw error }
    }
    static func hasSession(under url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        func overlaps(_ path: String) -> Bool { path == target || path.hasPrefix(target+"/") || target.hasPrefix(path+"/") }
        return entries.values.contains { overlaps($0.document.url.standardizedFileURL.resolvingSymlinksInPath().path) || overlaps($0.directory.standardizedFileURL.resolvingSymlinksInPath().path) }
            || preparing.keys.contains(where:overlaps)
            || preparingDirectories.values.contains { overlaps($0.standardizedFileURL.resolvingSymlinksInPath().path) }
    }
}

nonisolated enum CADSimulationSourceBridge {
    static func snapshot(_ captured: CADSimulationGeometry, source: SimulationSourceRef) throws -> SimulationGeometrySnapshot {
        guard captured.contentSHA256 == source.contentSHA256 else { throw SimulationError.staleSource }
        if captured.bodies.count == 1, let body = captured.bodies.first, let brep = body.brep {
            let region = body.id.uuidString.lowercased()
            var tags = body.faces.compactMap { face in face.nativeIndex.map { SimulationGeometryEntityTag(kind:.face,nativeIndex:$0,sourceEntityID:face.id,regionID:region) } }
            tags.append(.init(kind:.solid,nativeIndex:1,sourceEntityID:region,regionID:region))
            return .init(source:source,brep:brep,sourceLengthToMeters:0.001,entityTags:tags)
        }
        var nodes: [SimulationVector3] = [], elements: [SimulationElement] = [], boundaries: [SimulationBoundary] = []
        for body in captured.bodies {
            let region = body.id.uuidString.lowercased()
            var lookup: [SimulationVector3:Int] = [:], remap: [Int] = []
            for raw in body.positionsMM {
                guard raw.count == 3 else { throw SimulationError.invalidInput("Invalid CAD position.") }
                let p = SimulationVector3(raw[0]*0.001,raw[1]*0.001,raw[2]*0.001)
                if let index = lookup[p] { remap.append(index) }
                else { lookup[p] = nodes.count; remap.append(nodes.count); nodes.append(p) }
            }
            let offset = elements.count
            for i in stride(from:0,to:body.indices.count,by:3) {
                guard i+2 < body.indices.count, body.indices[i...i+2].allSatisfy({ Int($0) < remap.count }) else { throw SimulationError.invalidInput("Invalid CAD triangles.") }
                elements.append(.init(kind:.triangle3,nodes:body.indices[i...i+2].map { remap[Int($0)] },regionID:region))
            }
            var assigned = Set<Int>()
            for face in body.faces where !face.triangles.isEmpty {
                let triangles = face.triangles.filter { $0 >= 0 && $0 < body.indices.count/3 && !assigned.contains($0) }
                guard !triangles.isEmpty else { continue }
                assigned.formUnion(triangles)
                let facets = triangles.map { SimulationBoundaryFacet(elementIndex:offset+$0) }
                boundaries.append(.init(id:face.id,sourceEntityID:face.id,nodeIndices:Array(Set(triangles.flatMap { elements[offset+$0].nodes })).sorted(),facets:facets))
            }
            for triangle in 0..<body.indices.count/3 where !assigned.contains(triangle) {
                let id = "\(region)/snapshot/\(source.contentSHA256)/triangle/\(triangle)"
                boundaries.append(.init(id:id,sourceEntityID:id,nodeIndices:elements[offset+triangle].nodes,facets:[.init(elementIndex:offset+triangle)]))
            }
        }
        let surface = SimulationMesh(source:source,nodes:nodes,elements:elements,boundaries:boundaries)
        return .init(source:source,surface:surface)
    }
    static func physics(_ geometry: CADSimulationGeometry) throws -> PhysicsSimulationConfiguration {
        var scene = PhysicsSimulationConfiguration()
        for source in geometry.bodies {
            let positions = source.positionsMM.map { SimulationVector3($0[0]*0.001,$0[1]*0.001,$0[2]*0.001) }
            let mesh = try SimulationPhysicsMesh(vertices:positions,indices:source.indices)
            var body = try mesh.rigidBody(id:source.id,sourceObjectID:source.id.uuidString.lowercased(),motion:mesh.isClosed ? .dynamic:.fixed)
            body.sourceGeometrySHA256 = geometry.contentSHA256
            scene.bodies.append(body)
        }
        return scene
    }
}
#endif
