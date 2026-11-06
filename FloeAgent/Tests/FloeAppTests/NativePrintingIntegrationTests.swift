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
