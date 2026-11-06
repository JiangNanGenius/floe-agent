import XCTest
@testable import FloeManufacturingCore

final class MeshImportTests:XCTestCase {
    func testOBJTriangleIndicesAndExplicitInchBoundary() throws {
        let data = Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3/1/1 -2/2/1 -1/3/1\n".utf8)
        let imported = try ManufacturingMeshImport.read(data,extension:"obj",scaleToMM:25.4)
        XCTAssertEqual(imported.mesh.vertices,[[0,0,0],[25.4,0,0],[0,25.4,0]])
        XCTAssertEqual(imported.mesh.triangles,[[0,1,2]])
        XCTAssertEqual(imported.contentSHA256,ManufacturingStudy.digest(data))
        for invalid in ["v 0 0 0\nf 1 2 3", "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3 1", "v nan 0 0", "v 0 0 0\nv 0 0 0\nv 1 0 0\nf 1 2 3"] {
            XCTAssertThrowsError(try ManufacturingMeshImport.read(Data(invalid.utf8),extension:"obj"))
        }
        XCTAssertThrowsError(try ManufacturingMeshImport.read(data,extension:"step"))
    }
    func testBinaryAndASCIISTLProduceSameGeometryAndRejectTruncation() throws {
        let ascii = Data("solid test\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid test\n".utf8)
        var binary = Data(repeating:0,count:80)
        var count = UInt32(1).littleEndian; withUnsafeBytes(of:&count) { binary.append(contentsOf:$0) }
        for value:Float in [0,0,1,0,0,0,1,0,0,0,1,0] {
            var bits = value.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { binary.append(contentsOf:$0) }
        }
        binary.append(contentsOf:[0,0])
        XCTAssertEqual(try ManufacturingMeshImport.read(ascii,extension:"stl").mesh,try ManufacturingMeshImport.read(binary,extension:"stl").mesh)
        XCTAssertThrowsError(try ManufacturingMeshImport.read(binary.dropLast(),extension:"stl"))
        XCTAssertThrowsError(try ManufacturingMeshImport.read(Data("solid x\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0".utf8),extension:"stl"))
    }
}
