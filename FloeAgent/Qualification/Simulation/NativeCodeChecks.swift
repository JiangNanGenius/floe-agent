import Foundation
import XCTest
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationFields
import FloeSimulationRuntime

final class SimulationNativeCodeChecks: XCTestCase {
    func testOCCTBRepToTaggedNetgenToMFEMAndSavedCSV() async throws {
        let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"c",count:64))
        let bytes = try XCTUnwrap(FloeSimulationFixtureBoxBRep())
        let tags = (1...6).map { SimulationGeometryEntityTag(kind:.face,nativeIndex:$0,sourceEntityID:"fixture/face/\($0)") }
        let snapshot = SimulationGeometrySnapshot(source:source,brep:bytes,sourceLengthToMeters:0.001,entityTags:tags)
        let driver = NetgenSimulationGeometryDriver()
        XCTAssertTrue(driver.isAvailable);XCTAssertTrue(driver.supportsBRep)
        let mesh = try await NativeSimulationMesher(driver:driver).mesh(snapshot,settings:.init(maximumSizeMeters:0.01,minimumSizeMeters:0.002),budget:.init()) { _ in }
        XCTAssertEqual(Set(mesh.boundaries.map(\.sourceEntityID)),Set(tags.map(\.sourceEntityID)))
        let volume = mesh.elements.reduce(0.0) { result,element in
            let p = element.nodes.map { mesh.nodes[$0] }
            return result+(p[1]-p[0]).dot((p[2]-p[0]).cross(p[3]-p[0]))/6
        }
        XCTAssertEqual(volume,0.1*0.02*0.03,accuracy:1e-11)
        let left = try XCTUnwrap(mesh.boundaries.first { $0.nodeIndices.allSatisfy { abs(mesh.nodes[$0].x) < 1e-10 } })
        let right = try XCTUnwrap(mesh.boundaries.first { $0.nodeIndices.allSatisfy { abs(mesh.nodes[$0].x-0.1) < 1e-10 } })
        let material = SimulationMaterial(name:"Dielectric",properties:["relativePermittivity":2.4])
        var configuration = ElectromagneticSimulationConfiguration()
        configuration.boundaries = [.init(boundaryID:left.id,kind:.electricPotential),.init(boundaryID:right.id,kind:.electricPotential,value:.init(real:10))]
        var study = SimulationStudy(name:"Native chain",kind:.electrostatic,materialAssignments:["body":material.id]); study.meshID = mesh.id;try study.setConfiguration(configuration)
        let request = SimulationRequest(source:source,study:study,mesh:mesh,materials:[material])
        let result = try await MFEMSimulationDriver().solve(request) { _ in }
        let potential = try XCTUnwrap(result.frames[0].fields.first { $0.id == "potential" })
        for (index,node) in mesh.nodes.enumerated() { XCTAssertEqual(potential.values[index],100*node.x,accuracy:1e-5) }
        let directory = try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("SimulationCodeChecks-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let archive = try SimulationArchiveStore(directory:directory)
        try await archive.saveResult(result,request:request)
        let restored = try await archive.readResult(result.id)
        XCTAssertEqual(restored,result)
        let csv = try await archive.exportCSV(restored)
        XCTAssertTrue(try String(contentsOf:csv,encoding:.utf8).contains("electric_field"))
    }
}
