import XCTest
import FloeManufacturingCore

final class DisplaySurfaceTests: XCTestCase {
    func testSmoothNormalsRetainPlanarFacesWithoutChangingPositions() {
        let raw:[[Double]] = [[0,0,0],[10,0,0],[10,1,0],[0,1,0]],saved = raw
        let normals = ManufacturingDisplaySurface.normals(raw,triangles:[[0,1,2],[0,2,3]],cellSizeMM:1,smoothing:true)
        XCTAssertEqual(raw,saved)
        XCTAssertEqual(normals.count,4)
        for n in normals { XCTAssertEqual(n,[0,0,1]) }
        XCTAssertEqual(ManufacturingDisplaySurface.normals(raw,triangles:[[0,1,7]],cellSizeMM:1,smoothing:true),[])
    }
    func testDisplayPreservesEveryTrueEdgeAndVertex() {
        let raw:[[Double]] = [[0,0,0],[2,0,0],[0,2,0],[0,0,2]]
        let faces = [[0,2,1],[0,1,3],[1,2,3],[2,0,3]],saved = raw
        let display = ManufacturingDisplaySurface.mesh(raw,triangles:faces,cellSizeMM:1)
        XCTAssertEqual(raw,saved)
        XCTAssertEqual(display.refinementPasses,0)
        XCTAssertEqual(display.triangles,faces)
        XCTAssertEqual(display.vertices,raw,"Unclassified faces must not be rounded or shrunk")
        XCTAssertTrue(display.triangles.allSatisfy { $0.allSatisfy(display.vertices.indices.contains) })
        for i in raw.indices {
            let distance = sqrt(zip(raw[i],display.vertices[i]).reduce(0.0) { $0+pow($1.0-$1.1,2) })
            XCTAssertLessThanOrEqual(distance,0.35000001)
        }
        let overBudget = ManufacturingDisplaySurface.mesh(raw,triangles:Array(repeating:faces[0],count:45_001),cellSizeMM:1)
        XCTAssertEqual(overBudget.refinementPasses,0)
        XCTAssertEqual(overBudget.triangles.count,45_001)
    }
    func testDisplayFilterIsBoundedAndPreservesRawMesh() {
        let raw:[[Double]] = [[0,0,0],[1,0,0],[1,1,0],[0,1,0],[0.5,0.5,0.8]]
        let saved = raw
        let triangles = [[0,1,4],[1,2,4],[2,3,4],[3,0,4]]
        let display = ManufacturingDisplaySurface.vertices(raw,triangles:triangles,cellSizeMM:1)
        XCTAssertEqual(raw,saved)
        XCTAssertEqual(display.count,raw.count)
        XCTAssertEqual(display,raw,"A real pyramid tip must stay a real tip")
        for i in raw.indices {
            let distance = sqrt(zip(raw[i],display[i]).reduce(0) { $0+pow($1.0-$1.1,2) })
            XCTAssertLessThanOrEqual(distance,0.35000001)
        }
    }
    func testInvalidDisplayInputIsReturnedWithoutInventingGeometry() {
        let raw:[[Double]] = [[0,0,0],[1,0,0],[0,1,0]]
        XCTAssertEqual(ManufacturingDisplaySurface.vertices(raw,triangles:[[0,1,4]],cellSizeMM:1),raw)
        XCTAssertEqual(ManufacturingDisplaySurface.vertices(raw,triangles:[[0,1,2]],cellSizeMM:0),raw)
    }
    func testRightAngleCornerNormalsStaySeparate() throws {
        let raw:[[Double]] = [[0,0,0],[2,0,0],[2,2,0],[0,2,0],[0,0,2],[2,0,2]]
        let triangles = [[0,1,2],[0,2,3],[0,4,5],[0,5,1]]
        for smooth in [false,true] {
            let mesh = try XCTUnwrap(ManufacturingDisplaySurface.shadedMesh(raw,triangles:triangles,smoothing:smooth))
            XCTAssertEqual(mesh.vertices,triangles.flatMap { t in t.map { raw[$0] } })
            for i in 0..<6 { XCTAssertEqual(mesh.normals[i],[0,0,1]) }
            for i in 6..<12 { XCTAssertEqual(mesh.normals[i],[0,1,0]) }
            XCTAssertEqual(mesh.vertices[0],mesh.vertices[6])
            XCTAssertNotEqual(mesh.normals[0],mesh.normals[6],"A shared corner must not receive a rounded 45 degree normal")
        }
    }
}
