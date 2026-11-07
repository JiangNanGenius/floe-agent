// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloePrintCore
import Testing
@testable import FloeApp

@Suite("Native printing runtime", .serialized)
@MainActor
struct NativePrintingIntegrationTests {
    @Test(.timeLimit(.minutes(2)))
    func visibleDefaultsReachRealGCodeAndRepeatedSlicesPublishNewCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("print-defaults-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PrintProjectDisk(root: root), id = UUID()
        let vertices: [[Float]] = [[0,0,0],[20,0,0],[20,20,0],[0,20,0],
                                   [0,0,20],[20,0,20],[20,20,20],[0,20,20]]
        let faces = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
                     [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        let asset = try await disk.storeMesh(PrintMesh(positions: faces.flatMap { $0.flatMap { vertices[$0] } }))
        var original = PrintProjectDocument(projectID: id)
        original.meshAsset = asset; original.meshName = "20 mm cube"
        // Existing documents omitted processSettings; the displayed defaults
        // must now reach the engine rather than its different fallback values.
        try await disk.create(original)
        let session = try await PrintProjectSession.open(id: id, directory: root)
        #expect(!session.hasUnsavedSettings)
        for _ in 0..<2 {
            let previousCompletion = session.completedSliceRevision
            let file = try await session.sliceAndWait()
            let bytes = try Data(contentsOf: file), text = String(decoding: bytes, as: UTF8.self)
            #expect(text.contains("; sliceFillSparse = 0.15"))
            #expect(text.contains("; sliceTopLayers = 4"))
            #expect(text.contains("; sliceBottomLayers = 4"))
            #expect(try GCodeInspector.inspect(bytes).layerCount == 100)
            #expect(session.completedSliceRevision != previousCompletion)
            #expect(session.completedSliceRevision == session.document.revision)
            #expect(session.resultIsCurrent)
            let saved = try await disk.load()
            #expect(saved.processSettings?["sliceFillSparse"] == 0.15)
            #expect(saved.processSettings?["sliceTopLayers"] == 4)
            #expect(saved.processSettings?["sliceBottomLayers"] == 4)
        }
        let beforeRejected = try await disk.load()
        await #expect(throws: PrintError.invalidSetting("unknownSetting")) {
            try await session.apply([.init(action: .settings, processSettings: ["unknownSetting": 3])], expectedRevision: session.document.revision)
        }
        #expect(try await disk.load().revision == beforeRejected.revision)
        // Reproduce the actual QA spelling with a valid centred cube. Those
        // accepted settings must reach both the saved original and G-code.
        try await session.apply([.init(action: .settings, processSettings: ["infillPercent": 35, "topLayers": 5, "bottomLayers": 5])], expectedRevision: session.document.revision)
        let migrated = try await disk.load()
        #expect(migrated.processSettings?["sliceFillSparse"] == 0.35)
        #expect(migrated.processSettings?["infillPercent"] == nil)
        let output = String(decoding: try Data(contentsOf: await session.sliceAndWait()), as: UTF8.self)
        #expect(output.contains("; sliceFillSparse = 0.35"))
        #expect(output.contains("; sliceTopLayers = 5"))
        #expect(output.contains("; sliceBottomLayers = 5"))
        let historicalDisk = PrintProjectDisk(root: root.appendingPathComponent("historical-result"))
        let historicalID = UUID()
        var historical = PrintProjectDocument(projectID: historicalID)
        historical.meshAsset = try await historicalDisk.storeMesh(PrintMesh(positions: faces.flatMap { $0.flatMap { vertices[$0] } }))
        historical.resultFingerprint = String(repeating: "0", count: 64)
        historical.resultLayerCount = 100
        try await historicalDisk.create(historical)
        _ = try await historicalDisk.commit(historical, expectedRevision: 0, asset: Data(output.utf8), fileExtension: "gcode")
        let restored = try await PrintProjectSession.open(id: historicalID, directory: root.appendingPathComponent("historical-result"))
        #expect(restored.result != nil)
        #expect(!restored.resultIsCurrent, "An older adapter/settings fingerprint cannot certify a current result.")
        _ = try await restored.sliceAndWait()
        #expect(restored.resultIsCurrent)
        // A real saved legacy project lets the UI verify compatibility and
        // automatic Preview without restoring a removed standalone New menu.
        let fixtureID = UUID(uuidString: "B9827A3B-1D6A-496D-9591-DF33605FA9B7")!
        let library = try await PersonalContentService.shared.library()
        _ = try await library.create(kind: .printing, title: "QA-Closure-Print-Preview", id: fixtureID) { directory, projectID in
            let seed = PrintProjectDisk(root: directory.appendingPathComponent("Printing"))
            var document = PrintProjectDocument(projectID: projectID)
            document.meshAsset = try await seed.storeMesh(PrintMesh(positions: faces.flatMap { $0.flatMap { vertices[$0] } }))
            document.meshName = "20 mm cube"
            try await seed.create(document)
        }
    }
    @Test(.timeLimit(.minutes(2)))
    func bundledWebKitEngineProducesValidatedFDMAndResinBytes() async throws {
        let vertices: [[Float]] = [[-2,-2,0],[2,-2,0],[2,2,0],[-2,2,0],
                                   [-2,-2,1],[2,-2,1],[2,2,1],[-2,2,1]]
        let faces = [[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
                     [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        let mesh = try PrintMesh(positions: faces.flatMap { $0.flatMap { vertices[$0] } })
        let backend = NativePrintBackend()
        let service = PrintSlicingService(backend: backend)
        for preset in [PrintPreset.genericMarlinPLA, .genericCTBV3] {
            let input = try PrintInput(mesh: mesh, preset: preset)
            let request = PrintRequest(identity: .init(projectID: UUID(), plateID: UUID(), revision: 1), input: input)
            let result = try await service.slice(request)
            #expect(result.identity == request.identity)
            #expect(result.inputFingerprint == input.fingerprint)
            #expect(!result.data.isEmpty)
            #expect(result.layerCount > 0)
            switch preset {
            case .genericMarlinPLA:
                #expect(try GCodeInspector.inspect(result.data).layerCount == result.layerCount)
            case .genericCTBV3:
                #expect(try CTBHeader.inspect(result.data).layerCount == result.layerCount)
            }
        }
    }
}
#endif
