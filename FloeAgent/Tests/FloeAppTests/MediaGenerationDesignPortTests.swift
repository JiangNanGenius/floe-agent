// FloeAppTests — design image reservation target identity.
//
// The design workflow already owns a real replacement node. These pure checks
// ensure the generation reservation names that node instead of an empty list or
// a fabricated id.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.MediaGenerationDesignPort")
@MainActor
struct MediaGenerationDesignPortTests {
    @Test("Design reservation targets the real replacement node")
    func designReservationUsesRealNodeTarget() {
        let canvasID = UUID()
        let documentID = UUID()
        let nodeID = UUID()
        let owner = MediaGenerationDesignPort.reservationOwner(
            canvasID: canvasID,
            documentID: documentID,
            nodeID: nodeID,
            operationID: "operation-42")

        #expect(owner.canvasID == canvasID)
        #expect(owner.documentID == documentID)
        #expect(owner.configurationNodeID == nodeID)
        #expect(owner.resultNodeIDs == [nodeID])
        #expect(Set(owner.resultNodeIDs).count == 1)
        #expect(owner.generationAttemptID == "design.operation-42")
    }
}
#endif
